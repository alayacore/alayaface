module NodeConnectionTest exposing (..)

import App.NodeConnection as NC
import Dict
import Expect
import Test exposing (..)


nodeSessions : Dict.Dict String String
nodeSessions =
    Dict.fromList
        [ ( "sess-a", "plan-1/t1" )
        , ( "sess-b", "plan-2/deep/node" )
        ]


resumed : Dict.Dict String String
resumed =
    Dict.fromList [ ( "live-c", "sess-a" ) ]


suite : Test
suite =
    describe "App.NodeConnection"
        [ describe "nodeLabelFor"
            [ test "direct binding label" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions resumed "sess-a"
                        |> Expect.equal (Just "plan-1/t1")

            , test "resumed (fresh id) resolves through planResumedFrom" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions resumed "live-c"
                        |> Expect.equal (Just "plan-1/t1")

            , test "unknown session → Nothing" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions resumed "nope"
                        |> Expect.equal Nothing

            , test "unknown resumed id → Nothing" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions resumed "live-unknown"
                        |> Expect.equal Nothing
            ]
        , describe "parseNodeConnection"
            [ test "simple label" <|
                \_ ->
                    NC.parseNodeConnection "plan-1/t1"
                        |> Expect.equal (Just ( "plan-1", "t1" ))

            , test "node id containing a slash stays intact" <|
                \_ ->
                    NC.parseNodeConnection "plan-2/deep/node"
                        |> Expect.equal (Just ( "plan-2", "deep/node" ))

            , test "empty string → Nothing" <|
                \_ ->
                    NC.parseNodeConnection ""
                        |> Expect.equal Nothing
            ]
        , describe "nodeConnectionFor"
            [ test "builds connection with the live session id" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "live-c"
                        |> Expect.equal
                            (Just { sessionId = "live-c", planId = "plan-1", nodeId = "t1" })

            , test "node id containing a slash survives the round trip" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "sess-b"
                        |> Expect.equal
                            (Just { sessionId = "sess-b", planId = "plan-2", nodeId = "deep/node" })

            , test "unbound session → Nothing" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "plain-chat"
                        |> Expect.equal Nothing

            , test "unknown session → Nothing" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "ghost"
                        |> Expect.equal Nothing
            ]
        ]
