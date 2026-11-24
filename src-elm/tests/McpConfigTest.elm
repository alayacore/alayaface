module McpConfigTest exposing (suite)

{-| The `mcp.conf` codec.

The schema used to live in BOTH backends (Rust `write_mcp_conf`, Go
`writeMcpConf`) with no parity check, and they had already drifted: Go quoted
values with `json.Marshal`, which escapes `&`, `<` and `>` as
`\u0026`/`\u003c`/`\u003e`, while AlayaCore's parser only knows `\\`, `\"`,
`\n` and `\r` — a URL with a query string was corrupted on save. The same
path silently deleted `auth-scopes`, a key the core reads. These tests pin the
single codec that replaced both: every key is written, everything else rides
in `extras`, and strings use the core's escaping.
-}

import App.McpConfig as MCP
import Conf
import Dict
import Expect
import Json.Decode as D
import Session.Types as T
import Test exposing (..)


{-| A record-update base must be a plain variable, not a qualified name.
-}
blank : T.McpDraft
blank =
    T.emptyMcpDraft


{-| A file with the three shapes that matter: an HTTP server, a stdio server,
and a block disabled by comments. `custom-key` is a key this build does not
model (standing in for the next one the core adds); `auth-scopes` is the real
key the old writers dropped.
-}
sample : String
sample =
    """#server: disabled
#url: http://localhost:1
---
server: "exaWebSearch"
url: "https://mcp.exa.ai/mcp"
proto-version: "2025-11-25"
---
server: "embedded"
command: "embedded-debugger-mcp"
args: ["--allow-flash-erase", "serve"]
env: {"RUST_LOG": "info"}
auth-scopes: ["read", "write"]
custom-key: "kept"
"""


decoded : List MCP.Server
decoded =
    MCP.decode sample


httpServer : MCP.Server
httpServer =
    List.head decoded |> Maybe.withDefault T.emptyMcpDraft |> MCP.serverFromDraft


stdioServer : MCP.Server
stdioServer =
    decoded |> List.drop 1 |> List.head |> Maybe.withDefault T.emptyMcpDraft |> MCP.serverFromDraft


suite : Test
suite =
    describe "App.McpConfig"
        [ describe "decode: text -> servers"
            [ test "a block disabled with # is skipped" <|
                \_ -> Expect.equal 2 (List.length decoded)
            , test "ids are sequential, as the list needs them" <|
                \_ -> Expect.equal [ 1, 2 ] (List.map .id decoded)
            , test "url presence decides the kind (it is not a persisted key)" <|
                \_ ->
                    Expect.equal ( "http", "stdio" )
                        ( httpServer.type_, stdioServer.type_ )
            , test "ordinary values are unquoted" <|
                \_ ->
                    Expect.equal ( "exaWebSearch", "embedded" )
                        ( httpServer.server, stdioServer.server )
            , test "args and env are JSON text, normalised to compact form" <|
                \_ ->
                    Expect.equal
                        ( "[\"--allow-flash-erase\",\"serve\"]", "{\"RUST_LOG\":\"info\"}" )
                        ( stdioServer.args, stdioServer.env )
            , test "auth-scopes is decoded, not dropped" <|
                \_ -> Expect.equal "[\"read\",\"write\"]" stdioServer.authScopes
            , test "a key this build does not model is carried verbatim" <|
                \_ ->
                    Expect.equal (Just "\"kept\"") (Dict.get "custom-key" stdioServer.extras)
            , test "a block with no server line is skipped" <|
                \_ ->
                    Expect.equal 0 (List.length (MCP.decode "url: \"http://x\"\n"))
            , test "a block with an empty server line is kept, so the editor can show it" <|
                \_ ->
                    Expect.equal [ "" ] (List.map .server (MCP.decode "server: \"\"\nurl: \"http://x\"\n"))
            ]
        , describe "encode: servers -> text"
            [ test "every modelled key is written, in the core's order" <|
                \_ ->
                    Expect.equal
                        ("""server: "exaWebSearch"
url: "https://mcp.exa.ai/mcp"
proto-version: "2025-11-25"
---
server: "embedded"
command: "embedded-debugger-mcp"
args: ["--allow-flash-erase","serve"]
env: {"RUST_LOG":"info"}
auth-scopes: ["read","write"]
custom-key: "kept"
""")
                        (MCP.encode decoded)
            , test "an empty list is an empty file" <|
                \_ -> Expect.equal "" (MCP.encode [])
            , test "values use the core's escaping — &, < and > are NOT JSON-escaped" <|
                \_ ->
                    let
                        server =
                            { stdioServer | server = "a&b<c>\"d\\e" }
                    in
                    Expect.equal
                        (Just "server: \"a&b<c>\\\"d\\\\e\"")
                        (List.head (Conf.blocks (MCP.encode [ server ]))
                            |> Maybe.andThen (List.filter (\( k, _ ) -> k == "server") >> List.head)
                            |> Maybe.map (\( _, v ) -> "server: " ++ v)
                        )
            , test "a newline in a value is escaped, not written as a line break" <|
                \_ ->
                    let
                        encoded =
                            MCP.encode [ { stdioServer | server = "a\nb" } ]
                    in
                    Expect.equal ( False, True )
                        ( String.contains "a\nb" encoded, String.contains "a\\nb" encoded )
            , test "args are written raw: already compact JSON, not re-quoted" <|
                \_ ->
                    Expect.equal
                        (Just "args: [\"--foo\"]")
                        (Conf.blocks (MCP.encode [ { stdioServer | args = "[\"--foo\"]" } ])
                            |> List.head
                            |> Maybe.andThen (List.filter (\( k, _ ) -> k == "args") >> List.head)
                            |> Maybe.map (\( k, v ) -> k ++ ": " ++ v)
                        )
            ]
        , describe "round trip"
            [ test "decode -> encode -> decode is stable" <|
                \_ ->
                    Expect.equal decoded (MCP.decode (MCP.encode decoded))
            , test "encode -> decode -> encode is byte-identical" <|
                \_ ->
                    Expect.equal (MCP.encode decoded) (MCP.encode (MCP.decode (MCP.encode decoded)))
            , test "a hand-edited file with extra whitespace normalises once, then is stable" <|
                \_ ->
                    let
                        messy =
                            "server:   \"x\"\nurl:\"http://h\"\n\n# comment\n"
                    in
                    Expect.equal
                        "server: \"x\"\nurl: \"http://h\"\n"
                        (MCP.encode (MCP.decode messy))
            ]
        , describe "draft"
            [ test "server -> draft -> server keeps every field (a missing proto defaults)" <|
                \_ ->
                    Expect.equal
                        { stdioServer | protoVersion = T.latestMcpProtoVersion }
                        (stdioServer |> MCP.draftFromServer |> MCP.serverFromDraft)
            , test "a missing proto-version defaults to the latest, as the dropdown shows" <|
                \_ ->
                    Expect.equal T.latestMcpProtoVersion
                        (MCP.decode "server: \"x\"\nurl: \"http://h\"\n"
                            |> List.head
                            |> Maybe.map MCP.draftFromServer
                            |> Maybe.map .protoVersion
                            |> Maybe.withDefault ""
                        )
            , test "switching kind clears the other kind's fields" <|
                \_ ->
                    let
                        draft =
                            { blank
                                | type_ = "http"
                                , url = "http://h"
                                , authType = "static"
                                , authToken = "t"
                            }
                    in
                    let
                        switched =
                            MCP.updateDraftField "type" "stdio" draft
                    in
                    Expect.equal
                        { url = "", authType = "static", authToken = "t" }
                        { url = switched.url
                        , authType = switched.authType
                        , authToken = switched.authToken
                        }
            , test "auth-scopes has its own draft slot" <|
                \_ ->
                    Expect.equal "[\"read\"]"
                        (MCP.updateDraftField "auth-scopes" "[\"read\"]" T.emptyMcpDraft).authScopes
            , test "every modelled key edits its own draft slot" <|
                \_ ->
                    List.filter (\key -> MCP.updateDraftField key "probe" blank == blank) MCP.modeledKeys
                        |> Expect.equal []
            , test "an unknown key edits nothing" <|
                \_ -> Expect.equal T.emptyMcpDraft (MCP.updateDraftField "nope" "x" T.emptyMcpDraft)
            ]
        , describe "validation (what the backends used to refuse)"
            [ test "a server needs a name" <|
                \_ -> Expect.equal [ "server" ] (problemKeys (MCP.draftProblems { blank | url = "http://h" }))
            , test "an HTTP server needs a URL" <|
                \_ -> Expect.equal [ "url" ] (problemKeys (MCP.draftProblems { blank | server = "x" }))
            , test "authorization_code needs a client id and secret" <|
                \_ ->
                    Expect.equal [ "auth-client-id", "auth-client-secret" ]
                        (problemKeys
                            (MCP.draftProblems
                                { blank
                                    | server = "x"
                                    , url = "https://h/mcp"
                                    , authType = "authorization_code"
                                }
                            )
                        )
            , test "static auth needs a token" <|
                \_ ->
                    Expect.equal [ "auth-token" ]
                        (problemKeys
                            (MCP.draftProblems
                                { blank | server = "x", url = "https://h/mcp", authType = "static" }
                            )
                        )
            , test "a stdio server needs a command" <|
                \_ ->
                    Expect.equal [ "command" ]
                        (problemKeys (MCP.draftProblems { blank | server = "x", type_ = "stdio" }))
            , test "stdio args must be a JSON array" <|
                \_ ->
                    Expect.equal [ "args" ]
                        (problemKeys
                            (MCP.draftProblems
                                { blank | server = "x", type_ = "stdio", command = "bin", args = "not json" }
                            )
                        )
            , test "stdio env must be a JSON object" <|
                \_ ->
                    Expect.equal [ "env" ]
                        (problemKeys
                            (MCP.draftProblems
                                { blank | server = "x", type_ = "stdio", command = "bin", env = "[1]" }
                            )
                        )
            , test "auth-scopes must be a JSON array" <|
                \_ ->
                    Expect.equal [ "auth-scopes" ]
                        (problemKeys
                            (MCP.draftProblems
                                { blank | server = "x", url = "https://h/mcp", authScopes = "\"read\"" }
                            )
                        )
            , test "a complete HTTP server has no problems" <|
                \_ ->
                    Expect.equal []
                        (MCP.draftProblems
                            { blank | server = "x", url = "https://h/mcp", authType = "none" }
                        )
            , test "a complete stdio server has no problems" <|
                \_ ->
                    Expect.equal []
                        (MCP.draftProblems
                            { blank
                                | server = "x"
                                , type_ = "stdio"
                                , command = "bin"
                                , args = "[\"--foo\"]"
                                , env = "{\"K\":\"v\"}"
                            }
                        )
            , test "duplicate names are caught against the working list" <|
                \_ ->
                    Expect.equal [ "server" ]
                        (problemKeys (MCP.duplicateProblem decoded { blank | server = "embedded" }))
            , test "renaming a server to its own name is not a duplicate" <|
                \_ ->
                    Expect.equal []
                        (problemKeys
                            (MCP.duplicateProblem decoded
                                { blank | id = stdioServer.id, server = "embedded" }
                            )
                        )
            , test "the whole list is valid before a sync" <|
                \_ -> Expect.equal [] (problemKeys (MCP.syncProblems decoded))
            , test "an invalid server already in the list blocks the whole sync" <|
                \_ ->
                    Expect.equal [ "command" ]
                        (problemKeys
                            (MCP.syncProblems [ { stdioServer | command = "" } ])
                        )
            , test "a duplicate name blocks the whole sync" <|
                \_ ->
                    Expect.equal [ "server" ]
                        (problemKeys (MCP.syncProblems [ httpServer, httpServer ]))
            ]
        , describe "unparsable values are preserved, not dropped"
            [ test "Conf.rawLine keeps the text the user has" <|
                \_ -> Expect.equal (Just "args: not json") (Conf.rawLine "args" "not json")
            , test "the MCP writer keeps a hidden invalid args value" <|
                \_ ->
                    Expect.equal
                        (Just "args: not json")
                        (Conf.blocks (MCP.encode [ { stdioServer | args = "not json" } ])
                            |> List.head
                            |> Maybe.andThen (List.filter (\( k, _ ) -> k == "args") >> List.head)
                            |> Maybe.map (\( k, v ) -> k ++ ": " ++ v)
                        )
            ]
        , describe "Conf (the shared text layer)"
            [ test "the four escapes round-trip" <|
                \_ ->
                    Expect.equal "a\"b\\c\nd\re"
                        (Conf.toString (Conf.quote "a\"b\\c\nd\re"))
            , test "an unknown escape keeps both characters, as the core does" <|
                \_ -> Expect.equal "a\\qb" (Conf.toString "\"a\\qb\"")
            , test "a single-quoted value is unquoted without unescaping" <|
                \_ -> Expect.equal "a\\nb" (Conf.toString "'a\\nb'")
            , test "blocks split on the exact separator and skip comments" <|
                \_ ->
                    Expect.equal
                        [ [ ( "a", "1" ), ( "b", "\"x\"" ) ], [ ( "c", "3" ) ] ]
                        (Conf.blocks "a: 1\n# skip\nb: \"x\"\n---\nc: 3\n")
            ]
        ]


problemKeys : List ( String, String ) -> List String
problemKeys problems =
    List.map Tuple.first problems
