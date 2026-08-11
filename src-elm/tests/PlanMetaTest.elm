module PlanMetaTest exposing (tests)

import Dict
import Expect
import Json.Decode as D
import Json.Encode as E
import Plan.Meta as M
import Plan.Types as PT
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Plan.Meta"
        [ test "encode then decode roundtrips" <|
            \_ ->
                let
                    meta =
                        { origin = { sessionId = "s-1", planIndex = 2 }
                        , feedbacks = [ { at = 100, status = "completed", text = "done", planId = "p-1" } ]
                        , depth = 2
                        , createdAt = 50
                        , name = "analyze machine parameters"
                        , lastStatus = "completed"
                        , parentPlanId = Just "p-0"
                        }

                    encoded =
                        E.encode 2 (M.encodeMeta meta)

                    decoded =
                        D.decodeString M.decodeMeta encoded
                in
                case decoded of
                    Ok m2 ->
                        Expect.all
                            [ \m -> Expect.equal { sessionId = "s-1", planIndex = 2 } m.origin
                            , \m -> Expect.equal 1 (List.length m.feedbacks)
                            , \m -> Expect.equal 2 m.depth
                            , \m -> Expect.equal 50 m.createdAt
                            , \m -> Expect.equal "analyze machine parameters" m.name
                            , \m -> Expect.equal "completed" m.lastStatus
                            , \m -> Expect.equal (Just "p-0") m.parentPlanId
                            ]
                            m2

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , test "strict: missing origin is rejected (every plan has one)" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "created_at": 7, "depth": 1 }""" of
                    Ok _ ->
                        Expect.fail "meta without origin must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing planIndex is rejected" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1" }, "created_at": 7, "depth": 1 }""" of
                    Ok _ ->
                        Expect.fail "origin without planIndex must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing depth is rejected (no legacy fallback)" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [], "created_at": 7 }""" of
                    Ok _ ->
                        Expect.fail "meta without depth must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing created_at is rejected" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [], "depth": 1 }""" of
                    Ok _ ->
                        Expect.fail "meta without created_at must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing name is rejected (status bar needs it)" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [], "depth": 1, "created_at": 7 }""" of
                    Ok _ ->
                        Expect.fail "meta without name must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing last_status is rejected" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [], "depth": 1, "created_at": 7, "name": "p" }""" of
                    Ok _ ->
                        Expect.fail "meta without last_status must be rejected"

                    Err _ ->
                        Expect.pass
        , test "lenient: old meta without parent_plan_id decodes to Nothing (P38)" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [], "depth": 1, "created_at": 7, "name": "p", "last_status": "completed" }""" of
                    Ok m ->
                        Expect.equal m.parentPlanId Nothing

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , test "legacy meta carrying parent_session_id still decodes (P39/B4 — the field is ignored, lineage replaces it)" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [], "depth": 1, "created_at": 7, "name": "p", "last_status": "completed", "parent_plan_id": "p-0", "parent_session_id": "s-fork" }""" of
                    Ok m ->
                        Expect.equal ( m.parentPlanId, m.origin.sessionId )
                            ( Just "p-0", "s-1" )

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , describe "plansOwnedBySession (P34 cascade close)"
            [ test "returns every plan whose origin is the session" <|
                \_ ->
                    M.plansOwnedBySession sampleMetas "sess-a"
                        |> List.sort
                        |> Expect.equal [ "p-1", "p-2" ]
            , test "other sessions are not included" <|
                \_ ->
                    M.plansOwnedBySession sampleMetas "sess-b"
                        |> Expect.equal [ "p-3" ]
            , test "unknown session → empty" <|
                \_ ->
                    M.plansOwnedBySession sampleMetas "nope"
                        |> Expect.equal []
            , test "empty index → empty" <|
                \_ ->
                    M.plansOwnedBySession Dict.empty "sess-a"
                        |> Expect.equal []
            ]
        , describe "recursion depth"
            [ test "top-level plan (no plan owns its origin session) → depth 1" <|
                \_ ->
                    M.depthForOrigin sampleMetas Dict.empty "sess-a"
                        |> Expect.equal 1
            , test "plan created by a node session of a depth-1 plan → depth 2" <|
                \_ ->
                    let
                        runStates =
                            Dict.fromList
                                [ ( "p-1", Dict.fromList [ ( "n1", nodeBoundTo "sess-a" ) ] ) ]
                    in
                    M.depthForOrigin sampleMetas runStates "sess-a"
                        |> Expect.equal 2
            , test "multi-level chain: depth-2 parent → depth 3" <|
                \_ ->
                    let
                        metas =
                            Dict.fromList
                                [ ( "p-1", metaOfDepth "sess-a" 1 )
                                , ( "p-2", metaOfDepth "sess-n1" 2 )
                                ]

                        runStates =
                            Dict.fromList
                                [ ( "p-1", Dict.fromList [ ( "n1", nodeBoundTo "sess-a" ) ] )
                                , ( "p-2", Dict.fromList [ ( "n1", nodeBoundTo "sess-n1" ) ] )
                                ]
                    in
                    M.depthForOrigin metas runStates "sess-n1"
                        |> Expect.equal 3
            , test "a closed node session still matches via lastSessionId" <|
                \_ ->
                    let
                        closedNode =
                            nodeBoundTo "sess-a"

                        closed =
                            { closedNode | conversationId = Nothing, lastSessionId = Just "sess-a" }

                        runStates =
                            Dict.fromList
                                [ ( "p-1", Dict.fromList [ ( "n1", closed ) ] ) ]
                    in
                    M.depthForOrigin sampleMetas runStates "sess-a"
                        |> Expect.equal 2
            , test "depthOf defaults to 1 for unknown plans (conservative)" <|
                \_ ->
                    M.depthOf sampleMetas "nope"
                        |> Expect.equal 1
            , test "shouldInjectPlanPrompt: at or under the limit → inject" <|
                \_ ->
                    Expect.all
                        [ \() -> Expect.equal True (M.shouldInjectPlanPrompt 1 8)
                        , \() -> Expect.equal True (M.shouldInjectPlanPrompt 8 8)
                        , \() -> Expect.equal False (M.shouldInjectPlanPrompt 9 8)
                        ]
                        ()
            , test "shouldAutoRun: only sub-plans (depth > 1)" <|
                \_ ->
                    Expect.all
                        [ \() -> Expect.equal False (M.shouldAutoRun 1)
                        , \() -> Expect.equal True (M.shouldAutoRun 2)
                        ]
                        ()
            ]
        , describe "planMetaForSessionIndex (status-bar binding)"
            [ test "matches the creation origin (non-forked plan)" <|
                \_ ->
                    case M.planMetaForSessionIndex sampleMetas "sess-a" 1 of
                        Just ( planId, _ ) ->
                            Expect.equal True (List.member planId [ "p-1", "p-2" ])

                        Nothing ->
                            Expect.fail "expected a binding for sess-a"
                        , test "matches only the CONVERSATION id — a physical fork id must be resolved by the caller (P39/B4)" <|
                \_ ->
                    -- The old parentSessionOf branch is gone: the query is
                    -- conversation-keyed, so a raw fork instance id does
                    -- NOT match (the caller resolves it through the
                    -- lineage registry before querying — see
                    -- Plan.Update.planMetaForMessage).
                    Expect.equal (M.planMetaForSessionIndex sampleMetas "sess-fork" 1) Nothing
            , test "wrong plan index or unrelated session → Nothing" <|
                \_ ->
                    Expect.all
                        [ \_ -> M.planMetaForSessionIndex sampleMetas "sess-a" 2 |> Expect.equal Nothing
                        , \_ -> M.planMetaForSessionIndex sampleMetas "sess-other" 1 |> Expect.equal Nothing
                        , \_ -> M.planMetaForSessionIndex Dict.empty "sess-a" 1 |> Expect.equal Nothing
                        ]
                        ()
            ]
        ]


sampleMetas : Dict.Dict String M.PlanMeta
sampleMetas =
    Dict.fromList
        [ ( "p-1", metaOf "sess-a" )
        , ( "p-2", metaOf "sess-a" )
        , ( "p-3", metaOf "sess-b" )
        ]


metaOf : String -> M.PlanMeta
metaOf sessionId =
    metaOfDepth sessionId 1


metaOfDepth : String -> Int -> M.PlanMeta
metaOfDepth sessionId depth =
    { origin = { sessionId = sessionId, planIndex = 1 }
    , feedbacks = []
    , depth = depth
    , createdAt = 1
    , name = "plan-" ++ sessionId
    , lastStatus = "not_started"
    , parentPlanId = Nothing
    }


nodeBoundTo : String -> PT.NodeRunState
nodeBoundTo sid =
    { nodeId = "n1"
    , status = PT.WaitingForPlan
    , attempts = 1
    , maxAttempts = 3
    , conversationId = Just sid
    , lastSessionId = Just sid
    , attemptSessions = [ sid ]
    , failures = []
    , startedAt = Nothing
    , finishedAt = Nothing
    , output = Nothing
    }
