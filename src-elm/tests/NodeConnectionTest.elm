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



{-| P36 chain contexts. Naming: S = session, P = plan, T = top-level
(plain) session. A three-level recursion looks like:

    T (plain, open)
     └─ plan-1 (origin T)   node sess-a bound to plan-1/t1
         └─ plan-2 (origin sess-a)   node sess-b bound to plan-2/deep/node
             └─ plan-3 (origin sess-b)   node sess-c bound to plan-3/t3
-}
singleCtx : NC.ChainCtx
singleCtx =
    { nodeSessions = Dict.fromList [ ( "sess-a", "plan-1/t1" ) ]
    , liveSessions = Dict.fromList [ ( "sess-top", () ), ( "sess-a", () ) ]
    , planOrigins = Dict.fromList [ ( "plan-1", "sess-top" ) ]
    }


deepCtx : NC.ChainCtx
deepCtx =
    { nodeSessions =
        Dict.fromList
            [ ( "sess-a", "plan-1/t1" )
            , ( "sess-b", "plan-2/deep/node" )
            , ( "sess-c", "plan-3/t3" )
            ]
    , liveSessions =
        Dict.fromList
            [ ( "sess-top", () )
            , ( "sess-a", () )
            , ( "sess-b", () )
            , ( "sess-c", () )
            ]
    , planOrigins =
        Dict.fromList
            [ ( "plan-1", "sess-top" )
            , ( "plan-2", "sess-a" )
            , ( "plan-3", "sess-b" )
            ]
    }


suite : Test
suite =
    describe "App.NodeConnection"
        [ describe "nodeLabelFor"
            [ test "direct binding label" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions "sess-a"
                        |> Expect.equal (Just "plan-1/t1")

            , test "unbound session → Nothing (C5: no resume mapping)" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions "live-c"
                        |> Expect.equal Nothing

            , test "unknown session → Nothing" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions "nope"
                        |> Expect.equal Nothing

            , test "unknown id → Nothing" <|
                \_ ->
                    NC.nodeLabelFor nodeSessions "live-unknown"
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
            [ test "builds connection with the session id" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions "sess-a"
                        |> Expect.equal
                            (Just { sessionId = "sess-a", planId = "plan-1", nodeId = "t1" })

            , test "node id containing a slash survives the round trip" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions "sess-b"
                        |> Expect.equal
                            (Just { sessionId = "sess-b", planId = "plan-2", nodeId = "deep/node" })

            , test "unbound session → Nothing" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions "plain-chat"
                        |> Expect.equal Nothing

            , test "unknown session → Nothing" <|
                \_ ->
                    NC.nodeConnectionFor nodeSessions "ghost"
                        |> Expect.equal Nothing
            ]
        , describe "liveSessionForOrigin"
            [ test "open live window → its own id (C5: no resume mapping)" <|
                \_ ->
                    NC.liveSessionForOrigin
                        (Dict.fromList [ ( "sess-a", () ) ])
                        "sess-a"
                        |> Expect.equal (Just "sess-a")

            , test "origin closed → Nothing" <|
                \_ ->
                    NC.liveSessionForOrigin
                        Dict.empty
                        "sess-b"
                        |> Expect.equal Nothing

            , test "unknown origin → Nothing" <|
                \_ ->
                    NC.liveSessionForOrigin
                        (Dict.fromList [ ( "sess-a", () ) ])
                        "ghost"
                        |> Expect.equal Nothing
            ]
        , describe "chainForSession (P36: whole ancestor path to the top)"
            [ test "plain session → no chain" <|
                \_ ->
                    NC.chainForSession singleCtx "sess-top"
                        |> Expect.equal []

            , test "unbound session → no chain" <|
                \_ ->
                    NC.chainForSession singleCtx "ghost"
                        |> Expect.equal []

            , test "single-level node session: its node segment + the plan's segment to the top session" <|
                \_ ->
                    NC.chainForSession singleCtx "sess-a"
                        |> Expect.equal
                            [ { kind = "node", sessionId = "sess-a", planId = "plan-1", nodeId = Just "t1" }
                            , { kind = "plan", sessionId = "sess-top", planId = "plan-1", nodeId = Nothing }
                            ]

            , test "deep node session: every segment up to the top-level session" <|
                \_ ->
                    NC.chainForSession deepCtx "sess-c"
                        |> Expect.equal
                            [ { kind = "node", sessionId = "sess-c", planId = "plan-3", nodeId = Just "t3" }
                            , { kind = "plan", sessionId = "sess-b", planId = "plan-3", nodeId = Nothing }
                            , { kind = "node", sessionId = "sess-b", planId = "plan-2", nodeId = Just "deep/node" }
                            , { kind = "plan", sessionId = "sess-a", planId = "plan-2", nodeId = Nothing }
                            , { kind = "node", sessionId = "sess-a", planId = "plan-1", nodeId = Just "t1" }
                            , { kind = "plan", sessionId = "sess-top", planId = "plan-1", nodeId = Nothing }
                            ]

            , test "node session bound directly (no resume mapping; C5)" <|
                \_ ->
                    NC.chainForSession
                        { nodeSessions = Dict.fromList [ ( "sess-a", "plan-1/t1" ) ]
                        , liveSessions = Dict.fromList [ ( "sess-top", () ), ( "sess-a", () ) ]
                        , planOrigins = Dict.fromList [ ( "plan-1", "sess-top" ) ]
                        }
                        "sess-a"
                        |> Expect.equal
                            [ { kind = "node", sessionId = "sess-a", planId = "plan-1", nodeId = Just "t1" }
                            , { kind = "plan", sessionId = "sess-top", planId = "plan-1", nodeId = Nothing }
                            ]

            , test "mid-chain owning session closed → chain stops at the deepest drawable segment" <|
                \_ ->
                    NC.chainForSession
                        { deepCtx | liveSessions = Dict.fromList [ ( "sess-top", () ), ( "sess-c", () ), ( "sess-b", () ) ] }
                        "sess-c"
                        |> Expect.equal
                            [ { kind = "node", sessionId = "sess-c", planId = "plan-3", nodeId = Just "t3" }
                            , { kind = "plan", sessionId = "sess-b", planId = "plan-3", nodeId = Nothing }
                            , { kind = "node", sessionId = "sess-b", planId = "plan-2", nodeId = Just "deep/node" }
                            ]

            , test "plan meta missing → chain stops at the deepest drawable segment" <|
                \_ ->
                    NC.chainForSession
                        { deepCtx | planOrigins = Dict.fromList [ ( "plan-3", "sess-b" ) ] }
                        "sess-c"
                        |> Expect.equal
                            [ { kind = "node", sessionId = "sess-c", planId = "plan-3", nodeId = Just "t3" }
                            , { kind = "plan", sessionId = "sess-b", planId = "plan-3", nodeId = Nothing }
                            , { kind = "node", sessionId = "sess-b", planId = "plan-2", nodeId = Just "deep/node" }
                            ]

            , test "origin cycle (plan meta → its own node session) terminates" <|
                \_ ->
                    NC.chainForSession
                        { nodeSessions = Dict.fromList [ ( "sess-x", "plan-x/n1" ) ]
                                            , liveSessions = Dict.fromList [ ( "sess-x", () ) ]
                        , planOrigins = Dict.fromList [ ( "plan-x", "sess-x" ) ]
                        }
                        "sess-x"
                        |> Expect.equal
                            [ { kind = "node", sessionId = "sess-x", planId = "plan-x", nodeId = Just "n1" }
                            , { kind = "plan", sessionId = "sess-x", planId = "plan-x", nodeId = Nothing }
                            ]
            ]
        , describe "chainForPlan (P36: active plan window → its whole ancestor path)"
            [ test "top-level plan → just its segment to the owning session" <|
                \_ ->
                    NC.chainForPlan singleCtx "plan-1"
                        |> Expect.equal
                            [ { kind = "plan", sessionId = "sess-top", planId = "plan-1", nodeId = Nothing }
                            ]

            , test "sub-plan → its segment + the owning session's whole ancestor chain" <|
                \_ ->
                    NC.chainForPlan deepCtx "plan-3"
                        |> Expect.equal
                            [ { kind = "plan", sessionId = "sess-b", planId = "plan-3", nodeId = Nothing }
                            , { kind = "node", sessionId = "sess-b", planId = "plan-2", nodeId = Just "deep/node" }
                            , { kind = "plan", sessionId = "sess-a", planId = "plan-2", nodeId = Nothing }
                            , { kind = "node", sessionId = "sess-a", planId = "plan-1", nodeId = Just "t1" }
                            , { kind = "plan", sessionId = "sess-top", planId = "plan-1", nodeId = Nothing }
                            ]

            , test "owning session closed → no chain" <|
                \_ ->
                    NC.chainForPlan
                        { singleCtx | liveSessions = Dict.fromList [ ( "sess-a", () ) ] }
                        "plan-1"
                        |> Expect.equal []

            , test "unknown plan → no chain" <|
                \_ ->
                    NC.chainForPlan singleCtx "plan-ghost"
                        |> Expect.equal []
            ]
        ]
