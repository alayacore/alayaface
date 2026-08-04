module McpHandlerTest exposing (tests)

import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import Session.Handlers as H
import Session.Protocol exposing (FrameEvent)
import Session.Types exposing (SessionState, emptySession)


applyFrame : FrameEvent -> SessionState -> SessionState
applyFrame ev s =
    H.handleFrameEvent s ev


mcpFrame : String -> List ( String, E.Value ) -> FrameEvent
mcpFrame status data =
    { sessionId = "s1"
    , tag = "SM"
    , rawValue = ""
    , historyId = Nothing
    , content = Nothing
    , json =
        Just
            (E.object
                [ ( "type", E.string "mcp" )
                , ( "data"
                  , E.object
                        ([ ( "status", E.string status ) ]
                            ++ data
                        )
                  )
                ]
            )
    , userContentType = Nothing
    }


authRequired : String -> String -> FrameEvent
authRequired server url =
    mcpFrame "auth_required"
        [ ( "server", E.string server )
        , ( "url", E.string url )
        ]


connecting : String -> FrameEvent
connecting server =
    mcpFrame "connecting" [ ( "server", E.string server ) ]


connected : String -> FrameEvent
connected server =
    mcpFrame "connected" [ ( "server", E.string server ) ]


failed : String -> FrameEvent
failed server =
    mcpFrame "failed" [ ( "server", E.string server ) ]


running : String -> FrameEvent
running server =
    mcpFrame "auth_running" [ ( "server", E.string server ) ]


authServers : SessionState -> List String
authServers s =
    List.map .server s.pendingMcpAuths


tests : Test
tests =
    describe "Session.Handlers MCP init (multiple servers)"
        [ describe "auth_required"
            [ test "keeps both servers when two need auth (no overwrite)" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (authRequired "gitlab" "https://gl")
                    in
                    Expect.equal [ "github", "gitlab" ] (authServers s)
            , test "stores each server's own url" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (authRequired "gitlab" "https://gl")
                    in
                    Expect.equal
                        [ "https://gh", "https://gl" ]
                        (List.map .url s.pendingMcpAuths)
            , test "re-request for the same server replaces, not duplicates" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh-old")
                                |> applyFrame (authRequired "github" "https://gh-new")
                    in
                    Expect.equal
                        ( 1, [ "https://gh-new" ] )
                        ( List.length s.pendingMcpAuths, List.map .url s.pendingMcpAuths )
            , test "new auth_required for a running server resets its running flag" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (authRequired "gitlab" "https://gl")
                    in
                    -- simulate: user started github's flow, then backend re-requests it
                    let
                        s2 =
                            { s | mcpAuthRunning = Just "github" }
                                |> applyFrame (authRequired "github" "https://gh-2")
                    in
                    Expect.equal Nothing s2.mcpAuthRunning
            ]
        , describe "resolution removes the server from pending auths"
            [ test "connected clears the server's auth entry" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (authRequired "gitlab" "https://gl")
                                |> applyFrame (connected "github")
                    in
                    Expect.equal [ "gitlab" ] (authServers s)
            , test "failed clears the server's auth entry" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (authRequired "gitlab" "https://gl")
                                |> applyFrame (failed "github")
                    in
                    Expect.equal [ "gitlab" ] (authServers s)
            , test "connected clears the running flag for that server" <|
                \_ ->
                    let
                        -- mcpAuthRunning is set by the UI (Authorize click),
                        -- so simulate it before the backend resolves.
                        s =
                            emptySession "s1"
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (connected "github")

                        withRunning =
                            { s | mcpAuthRunning = Just "github" }
                                |> applyFrame (connected "github")
                    in
                    Expect.equal Nothing withRunning.mcpAuthRunning
            , test "done clears everything" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (connecting "github")
                                |> applyFrame (authRequired "github" "https://gh")
                                |> applyFrame (running "github")
                                |> applyFrame (mcpFrame "done" [])
                    in
                    Expect.all
                        [ \x -> Expect.equal Nothing x.mcpStatus
                        , \x -> Expect.equal [] x.mcpServers
                        , \x -> Expect.equal [] x.pendingMcpAuths
                        , \x -> Expect.equal Nothing x.mcpAuthRunning
                        ]
                        s
            ]
        ]
