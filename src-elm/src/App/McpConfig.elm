module App.McpConfig exposing
    ( Draft
    , Server
    , decode
    , draftFromServer
    , draftProblems
    , duplicateProblem
    , emptyDraft
    , encode
    , modeledKeys
    , serverFromDraft
    , serverName
    , syncProblems
    , updateDraftField
    )

{-| `mcp.conf`: the one place in AlayaFace that knows the file's keys, their
types and how they are written.

The adapter owns this file — AlayaCore only reads it, at session start — so
the editor must write every key it knows, and carry the ones it does not.
Earlier the codec lived in both backends (Rust `write_mcp_conf`, Go
`writeMcpConf`) with no parity check, and the two had already drifted: Go
quoted strings with `json.Marshal`, which escapes `&`, `<` and `>` as
`\u0026`/`\u003c`/`\u003e`, while the core's parser only knows `\\`, `\"`,
`\n` and `\r`. That is why every value now goes through `Conf`'s escaping.

The other half of that bug: `auth-scopes` is a key AlayaCore reads
(`mcp.ServerConfigFile`) that neither backend modelled, so editing any server
silently deleted it. It is modelled here, and `extras` covers the next key
AlayaCore adds — a key this build does not model is carried through as its
raw conf value instead of being dropped.

`type` (http/stdio) is a UI concept inferred from `url`; it is not persisted.

-}

import Conf
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Set
import Session.Types as T


type alias Server =
    T.McpInfo


type alias Draft =
    T.McpDraft


{-| The keys this module writes, in AlayaCore's `mcp.ServerConfigFile` order.
Anything else in the file rides in `Server.extras`.
-}
modeledKeys : List String
modeledKeys =
    [ "server"
    , "url"
    , "command"
    , "args"
    , "env"
    , "auth-type"
    , "auth-scopes"
    , "auth-token"
    , "auth-client-id"
    , "auth-client-secret"
    , "proto-version"
    ]


emptyDraft : Draft
emptyDraft =
    T.emptyMcpDraft


serverName : Server -> String
serverName server =
    server.server


-- DECODE: TEXT -> ITEMS


{-| Parse `mcp.conf` into servers.

A block without a `server` line is skipped: that drops comment-only and
disabled blocks, matching what AlayaCore's loader does. A block whose `server`
is present but empty is kept, so the editor can show the problem instead of
the entry vanishing.

Values are decoded the way the core reads them: ordinary fields unquote, and
`args` / `env` / `auth-scopes` are JSON text (normalised to compact form so a
hand-edited file re-saves the way the core would write it).
-}
decode : String -> List Server
decode text =
    Conf.blocks text
        |> List.filterMap decodeBlock
        |> List.indexedMap (\i server -> { server | id = i + 1 })


decodeBlock : Conf.Block -> Maybe Server
decodeBlock block =
    if not (List.any (\( key, _ ) -> key == "server") block) then
        Nothing

    else
        let
            raw key =
                List.filterMap
                    (\( k, value ) ->
                        if k == key then
                            Just value

                        else
                            Nothing
                    )
                    block
                    |> List.head

            string key =
                raw key |> Maybe.map Conf.toString |> Maybe.withDefault ""

            json key =
                raw key |> Maybe.map Conf.toJsonText |> Maybe.withDefault ""

            url =
                string "url"
        in
        Just
            { id = 0
            , type_ =
                if String.isEmpty (String.trim url) then
                    "stdio"

                else
                    "http"
            , server = string "server"
            , url = url
            , command = string "command"
            , args = json "args"
            , env = json "env"
            , authType = string "auth-type"
            , authScopes = json "auth-scopes"
            , authToken = string "auth-token"
            , authClientId = string "auth-client-id"
            , authClientSecret = string "auth-client-secret"
            , protoVersion = string "proto-version"
            , extras =
                block
                    |> List.filter (\( key, _ ) -> not (List.member key modeledKeys))
                    |> Dict.fromList
            }


-- ENCODE: ITEMS -> TEXT


{-| Write the whole file.

Every modelled key is written (empty strings are skipped, except `server`,
which validation requires anyway), so a save cannot delete a line by
forgetting it. `extras` are appended verbatim: they came from the file, so
re-emitting the raw value is lossless.
-}
encode : List Server -> String
encode servers =
    case servers of
        [] ->
            ""

        _ ->
            String.join "\n---\n" (List.map encodeServer servers) ++ "\n"


encodeServer : Server -> String
encodeServer server =
    String.join "\n"
        (List.filterMap identity
            [ Just (Conf.stringLine "server" server.server)
            , nonEmpty "url" server.url
            , nonEmpty "command" server.command
            , Conf.rawLine "args" server.args
            , Conf.rawLine "env" server.env
            , nonEmpty "auth-type" server.authType
            , Conf.rawLine "auth-scopes" server.authScopes
            , nonEmpty "auth-token" server.authToken
            , nonEmpty "auth-client-id" server.authClientId
            , nonEmpty "auth-client-secret" server.authClientSecret
            , nonEmpty "proto-version" server.protoVersion
            ]
            ++ List.map
                (\( key, value ) -> key ++ ": " ++ value)
                (Dict.toList server.extras)
        )


nonEmpty : String -> String -> Maybe String
nonEmpty key value =
    if String.isEmpty value then
        Nothing

    else
        Just (Conf.stringLine key value)


-- DRAFT


draftFromServer : Server -> Draft
draftFromServer server =
    { id = server.id
    , type_ = server.type_
    , server = server.server
    , url = server.url
    , command = server.command
    , args = server.args
    , env = server.env
    , authType = server.authType
    , authScopes = server.authScopes
    , authToken = server.authToken
    , authClientId = server.authClientId
    , authClientSecret = server.authClientSecret
    , protoVersion =
        -- Old configs may lack proto-version; default it to the latest so the
        -- dropdown shows the real value instead of silently selecting the
        -- first option while the draft stays empty.
        if String.isEmpty (String.trim server.protoVersion) then
            T.latestMcpProtoVersion

        else
            server.protoVersion
    , extras = server.extras
    }


serverFromDraft : Draft -> Server
serverFromDraft draft =
    { id = draft.id
    , type_ = draft.type_
    , server = String.trim draft.server
    , url = String.trim draft.url
    , command = String.trim draft.command
    , args = String.trim draft.args
    , env = String.trim draft.env
    , authType = String.trim draft.authType
    , authScopes = String.trim draft.authScopes
    , authToken = String.trim draft.authToken
    , authClientId = String.trim draft.authClientId
    , authClientSecret = String.trim draft.authClientSecret
    , protoVersion = String.trim draft.protoVersion
    , extras = draft.extras
    }


updateDraftField : String -> String -> Draft -> Draft
updateDraftField field value draft =
    case field of
        "type" ->
            -- Switching kind clears the other kind's fields to avoid residue.
            if value == "http" then
                { draft | type_ = value, command = "", args = "", env = "" }

            else
                -- Auth fields are http-only and hidden here, but kept: the old
                -- editor preserved them across a toggle, and losing a filled
                -- client secret to a mis-click is worse than writing a key the
                -- core ignores on a stdio block.
                { draft | type_ = value, url = "" }

        "server" ->
            { draft | server = value }

        "url" ->
            { draft | url = value }

        "command" ->
            { draft | command = value }

        "args" ->
            { draft | args = value }

        "env" ->
            { draft | env = value }

        "auth-type" ->
            { draft | authType = value }

        "auth-scopes" ->
            { draft | authScopes = value }

        "auth-token" ->
            { draft | authToken = value }

        "auth-client-id" ->
            { draft | authClientId = value }

        "auth-client-secret" ->
            { draft | authClientSecret = value }

        "proto-version" ->
            { draft | protoVersion = value }

        _ ->
            draft


-- VALIDATION


{-| Why this draft must not be saved, as (field key, message).

Mirrors what the two backends used to enforce before writing, plus the JSON
shape of `auth-scopes`. The same list disables Save in the editor and is
re-checked by `SelectorKit.editSave`, so the view cannot be bypassed.
-}
draftProblems : Draft -> List ( String, String )
draftProblems draft =
    let
        name =
            String.trim draft.server
    in
    (if String.isEmpty name then
        [ ( "server", "Every server needs a name" ) ]

     else
        []
    )
        ++ (if draft.type_ == "http" then
                (if String.isEmpty (String.trim draft.url) then
                    [ ( "url", "URL is required for an HTTP server" ) ]

                 else
                    []
                )
                    ++ authProblems draft

            else
                (if String.isEmpty (String.trim draft.command) then
                    [ ( "command", "Command is required for a stdio server" ) ]

                 else
                    []
                )
                    ++ jsonProblem "args" "array" draft.args
                    ++ jsonProblem "env" "object" draft.env
           )
        ++ jsonProblem "auth-scopes" "array" draft.authScopes


authProblems : Draft -> List ( String, String )
authProblems draft =
    case String.trim draft.authType of
        "authorization_code" ->
            (if String.isEmpty (String.trim draft.authClientId) then
                [ ( "auth-client-id", "Auth Client ID is required for authorization_code auth" ) ]

             else
                []
            )
                ++ (if String.isEmpty (String.trim draft.authClientSecret) then
                        [ ( "auth-client-secret", "Auth Client Secret is required for authorization_code auth" ) ]

                    else
                        []
                   )

        "static" ->
            if String.isEmpty (String.trim draft.authToken) then
                [ ( "auth-token", "Auth Token is required for static auth" ) ]

            else
                []

        _ ->
            []


jsonProblem : String -> String -> String -> List ( String, String )
jsonProblem key kind text =
    if String.isEmpty (String.trim text) then
        []

    else
        case D.decodeString D.value text of
            Err _ ->
                [ ( key, key ++ " is not valid JSON" ) ]

            Ok value ->
                let
                    ok =
                        case kind of
                            "array" ->
                                isArray value

                            _ ->
                                isObject value
                in
                if ok then
                    []

                else
                    [ ( key, key ++ " must be a JSON " ++ kind ) ]


isArray : E.Value -> Bool
isArray value =
    case D.decodeValue (D.list D.value) value of
        Ok _ ->
            True

        Err _ ->
            False


isObject : E.Value -> Bool
isObject value =
    case D.decodeValue (D.dict D.value) value of
        Ok _ ->
            True

        Err _ ->
            False


{-| Everything wrong with the WHOLE list, checked before a sync.

The old backends refused to write a payload with any invalid server, so the
file never gained an entry the core would skip. Save-time validation
(`draftProblems`) covers the server being edited; this covers the ones already
in the list (a hand-edited file can contain them) and duplicate names, which
need the list to see.
-}
syncProblems : List Server -> List ( String, String )
syncProblems servers =
    List.concatMap (\server -> draftProblems (draftFromServer server)) servers
        ++ duplicateNames servers


duplicateNames : List Server -> List ( String, String )
duplicateNames servers =
    let
        ( _, problems ) =
            List.foldl
                (\server ( seen, acc ) ->
                    let
                        name =
                            String.trim server.server
                    in
                    if String.isEmpty name then
                        ( seen, acc )

                    else if Set.member name seen then
                        ( seen, acc ++ [ ( "server", "Duplicate server name: " ++ name ) ] )

                    else
                        ( Set.insert name seen, acc )
                )
                ( Set.empty, [] )
                servers
    in
    problems


{-| The one rule that spans items: two servers with the same name. AlayaCore
skips the later duplicate at load, which would otherwise look like a server
silently disappearing. `draft.id` is 0 for a new server, so it never collides.
-}
duplicateProblem : List Server -> Draft -> List ( String, String )
duplicateProblem servers draft =
    let
        name =
            String.trim draft.server
    in
    if String.isEmpty name then
        []

    else if List.any (\server -> server.id /= draft.id && String.trim server.server == name) servers then
        [ ( "server", "Another server is already named " ++ name ) ]

    else
        []
