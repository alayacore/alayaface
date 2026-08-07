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
                            (Just { sessionId = "live-c", planId = "plan-1", nodeId = "t1", ancestors = [] })

            , test "node id containing a slash survives the round trip" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "sess-b"
                        |> Expect.equal
                            (Just { sessionId = "sess-b", planId = "plan-2", nodeId = "deep/node", ancestors = [] })

            , test "unbound session → Nothing" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "plain-chat"
                        |> Expect.equal Nothing

            , test "unknown session → Nothing" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions resumed "ghost"
                        |> Expect.equal Nothing
            ]
        , describe "ancestorEdges"
            [ test "chain A→B→C→D, focus D → all three edges" <|
                \_ ->
                    NC.ancestorEdges
                        [ ( "A", [] )
                        , ( "B", [ "A" ] )
                        , ( "C", [ "B" ] )
                        , ( "D", [ "C" ] )
                        ]
                        "D"
                        |> Expect.equal
                            [ { from = "A", to = "B" }
                            , { from = "B", to = "C" }
                            , { from = "C", to = "D" }
                            ]

            , test "chain focus B → only the edge above it" <|
                \_ ->
                    NC.ancestorEdges
                        [ ( "A", [] )
                        , ( "B", [ "A" ] )
                        , ( "C", [ "B" ] )
                        , ( "D", [ "C" ] )
                        ]
                        "B"
                        |> Expect.equal [ { from = "A", to = "B" } ]

            , test "diamond A→B,C→D, focus D → all four edges" <|
                \_ ->
                    NC.ancestorEdges
                        [ ( "A", [] )
                        , ( "B", [ "A" ] )
                        , ( "C", [ "A" ] )
                        , ( "D", [ "B", "C" ] )
                        ]
                        "D"
                        |> Expect.equal
                            [ { from = "A", to = "B" }
                            , { from = "A", to = "C" }
                            , { from = "B", to = "D" }
                            , { from = "C", to = "D" }
                            ]

            , test "focus a root node → no edges" <|
                \_ ->
                    NC.ancestorEdges
                        [ ( "A", [] )
                        , ( "B", [ "A" ] )
                        ]
                        "A"
                        |> Expect.equal []

            , test "unknown node → no edges" <|
                \_ ->
                    NC.ancestorEdges [ ( "A", [] ) ] "nope"
                        |> Expect.equal []

            , test "a cycle (malformed file) terminates instead of hanging" <|
                \_ ->
                    NC.ancestorEdges
                        [ ( "A", [ "B" ] )
                        , ( "B", [ "A" ] )
                        , ( "C", [ "B" ] )
                        ]
                        "C"
                        |> Expect.equal
                            [ { from = "B", to = "A" }
                            , { from = "A", to = "B" }
                            , { from = "B", to = "C" }
                            ]
            ]
        , describe "liveSessionForOrigin"
            [ test "origin session open → its own id" <|
                \_ ->
                    NC.liveSessionForOrigin
                        (Dict.fromList [ ( "sess-a", () ) ])
                        resumed
                        "sess-a"
                        |> Expect.equal (Just "sess-a")

            , test "origin session resumed → fresh live id" <|
                \_ ->
                    NC.liveSessionForOrigin
                        (Dict.fromList [ ( "live-c", () ) ])
                        resumed
                        "sess-a"
                        |> Expect.equal (Just "live-c")

            , test "origin closed (neither open nor resumed) → Nothing" <|
                \_ ->
                    NC.liveSessionForOrigin
                        Dict.empty
                        resumed
                        "sess-b"
                        |> Expect.equal Nothing

            , test "resumed mapping exists but fresh session closed → Nothing" <|
                \_ ->
                    NC.liveSessionForOrigin
                        Dict.empty
                        resumed
                        "sess-a"
                        |> Expect.equal Nothing

            , test "unknown origin → Nothing" <|
                \_ ->
                    NC.liveSessionForOrigin
                        (Dict.fromList [ ( "sess-a", () ) ])
                        resumed
                        "ghost"
                        |> Expect.equal Nothing
            ]
        ]
