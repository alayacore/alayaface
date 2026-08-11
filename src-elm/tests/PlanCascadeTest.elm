module PlanCascadeTest exposing (tests)

import Dict exposing (Dict)
import Expect
import Json.Decode as D
import Json.Encode as E
import Plan.Cascade as C
import Plan.Meta as M
import Plan.Types as PT
import Session.Meta as SM
import Session.Types as T
import Test exposing (Test, describe, test)


planFromJson : String -> PT.Plan
planFromJson json =
    case PT.parsePlan json of
        Ok p ->
            p

        Err errs ->
            Debug.todo ("bad test plan: " ++ String.join "; " errs)


-- chain: t1 → t2 → t3 (t2 is the delegated node)
planB : PT.Plan
planB =
    planFromJson """{ "type": "alayaface-plan", "name": "B", "tasks": [
      { "id": "t1", "title": "one", "prompt": "p1" },
      { "id": "t2", "title": "two", "prompt": "p2", "depends_on": ["t1"] },
      { "id": "t3", "title": "three", "prompt": "p3", "depends_on": ["t2"] },
      { "id": "t4", "title": "four", "prompt": "p4" }
    ] }"""


-- t4 (above) is a parallel branch; planC: p1 → p2 (p2 delegated)
planC : PT.Plan
planC =
    planFromJson """{ "type": "alayaface-plan", "name": "C", "tasks": [
      { "id": "p1", "title": "one", "prompt": "p1" },
      { "id": "p2", "title": "two", "prompt": "p2", "depends_on": ["p1"] }
    ] }"""


msg : T.Role -> String -> T.Message
msg role content =
    { id = "m-" ++ content
    , role = role
    , content = content
    , toolId = Nothing
    , toolName = Nothing
    , isError = False
    , historyId = Nothing
    , media = Nothing
    }


withHistory : String -> T.Message -> T.Message
withHistory h m =
    { m | historyId = Just h }


planResultMsg : String -> String -> T.Message
planResultMsg planId summary =
    msg T.User (C.insertPrefix planId summary)


metaOf : String -> String -> Maybe String -> M.PlanMeta
metaOf planId originSid parent =
    { origin = { sessionId = originSid, planIndex = 1 }
    , feedbacks = []
    , depth = 1
    , createdAt = 1
    , name = "plan-" ++ planId
    , lastStatus = "completed"
    , parentPlanId = parent
    }


-- run for planA (the root being re-run)
planA : PT.Plan
planA =
    planFromJson """{ "type": "alayaface-plan", "name": "A", "tasks": [
      { "id": "t1", "title": "one", "prompt": "p1" }
    ] }"""


runA : PT.RunState
runA =
    PT.emptyRunState "r-a" planA


-- run for planB with t2 bound to session s1 (succeeded, output "old")
runB : PT.RunState
runB =
    let
        base =
            PT.emptyRunState "r-b" planB
    in
    { base
        | nodes =
            Dict.update "t2"
                (Maybe.map (\n -> { n | conversationId = Just "s1", status = PT.Succeeded, output = Just "old" }))
                base.nodes
    }


-- run for planC with p2 bound to session s2
runC : PT.RunState
runC =
    let
        base =
            PT.emptyRunState "r-c" planC
    in
    { base
        | nodes =
            Dict.update "p2"
                (Maybe.map (\n -> { n | conversationId = Just "s2", status = PT.Succeeded, output = Just "old-c" }))
                base.nodes
    }


ctxFor : Dict String (List T.Message) -> { planMetas : Dict String M.PlanMeta, runs : Dict String (Maybe PT.RunState), sessions : Dict String T.SessionState, sessionLineage : Dict String SM.SessionMeta }
ctxFor sessions =
    let
        sessionWith sid msgs =
            let
                base =
                    T.emptySession sid
            in
            { base | messages = msgs }
    in
    { planMetas =
        Dict.fromList
            [ ( "a", metaOf "a" "s1" (Just "b") )
            , ( "b", metaOf "b" "s2" (Just "c") )
            , ( "c", metaOf "c" "s3" Nothing )
            , ( "sib", metaOf "sib" "s1" Nothing )
            , ( "other", metaOf "other" "s9" Nothing )
            ]
    , runs = Dict.fromList [ ( "b", Just runB ), ( "c", Just runC ) ]
    , sessions = Dict.map sessionWith sessions
    , sessionLineage = Dict.empty
    }


sessionMap : Dict String (List T.Message)
sessionMap =
    Dict.fromList
        [ -- root A's origin: old result + a user follow-up after it
          ( "s1"
          , [ msg T.User "hello"
            , planResultMsg "a" "result-a"
            , msg T.Assistant "done"
            , msg T.User "my follow-up"
            ]
          )
        , -- B's origin: old result, nothing after
          ( "s2"
          , [ msg T.User "orig"
            , planResultMsg "b" "result-b"
            ]
          )
        , -- top-level plain session (open)
          ( "s3", [ msg T.User "top" ] )
        ]


tests : Test
tests =
    describe "Plan.Cascade (P38)"
        [ describe "findInsertionIndex"
            [ test "finds the LAST [Plan Result] message for the plan" <|
                \_ ->
                    let
                        msgs =
                            [ planResultMsg "a" "first"
                            , msg T.User "middle"
                            , planResultMsg "a" "second"
                            ]
                    in
                    Expect.equal (Just 2) (C.findInsertionIndex "a" msgs)
            , test "other plans' results do not match" <|
                \_ ->
                    let
                        msgs =
                            [ planResultMsg "b" "other-plan" ]
                    in
                    Expect.equal Nothing (C.findInsertionIndex "a" msgs)
            , test "no insertion → Nothing" <|
                \_ ->
                    Expect.equal Nothing (C.findInsertionIndex "a" [ msg T.User "plain" ])
            ]
        , describe "countUserMessagesAfter"
            [ test "counts only User messages after the insertion" <|
                \_ ->
                    let
                        msgs =
                            [ planResultMsg "a" "r"
                            , msg T.Assistant "answer"
                            , msg T.User "typed"
                            , msg T.Tool "tool"
                            ]
                    in
                    Expect.equal 1 (C.countUserMessagesAfter (C.findInsertionIndex "a" msgs) msgs)
            , test "no insertion → 0" <|
                \_ ->
                    Expect.equal 0 (C.countUserMessagesAfter Nothing [ msg T.User "x" ])
            ]
        , describe "truncateMessagesAt"
            [ test "drops the insertion and everything after" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "keep"
                            , planResultMsg "a" "r"
                            , msg T.Assistant "drop"
                            ]
                    in
                    C.truncateMessagesAt 1 msgs
                        |> List.map .content
                        |> Expect.equal [ "keep" ]
            ]
        , describe "transitiveSuccessors"
            [ test "chain: direct + indirect dependents" <|
                \_ ->
                    C.transitiveSuccessors "t2" planB.tasks
                        |> List.sort
                        |> Expect.equal [ "t3" ]
            , test "diamond: both paths" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "type": "alayaface-plan", "name": "x", "tasks": [
                              { "id": "a", "title": "a", "prompt": "a" },
                              { "id": "b", "title": "b", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "c", "prompt": "c", "depends_on": ["a"] },
                              { "id": "d", "title": "d", "prompt": "d", "depends_on": ["b", "c"] }
                            ] }"""
                    in
                    C.transitiveSuccessors "a" plan.tasks
                        |> List.sort
                        |> Expect.equal [ "b", "c", "d" ]
            , test "parallel independent tasks are not included" <|
                \_ ->
                    C.transitiveSuccessors "t2" planB.tasks
                        |> List.member "t4"
                        |> Expect.equal False
            ]
        , describe "feedbackSummary"
            [ test "concatenates succeeded outputs only" <|
                \_ ->
                    let
                        run =
                            { runB
                                | nodes =
                                    Dict.update "t1"
                                        (Maybe.map (\n -> { n | status = PT.Succeeded, output = Just "out1" }))
                                        runB.nodes
                            }
                    in
                    C.feedbackSummary run
                        |> String.contains "## t1 · one\nout1"
                        |> Expect.equal True
            , test "empty when nothing succeeded" <|
                \_ ->
                    C.feedbackSummary (PT.emptyRunState "r" planB)
                        |> Expect.equal ""
            ]
        , describe "insertPrefix"
            [ test "result text carries the trailing [Plan: id] link token" <|
                \_ ->
                    let
                        p =
                            C.insertPrefix "a-1" "## t1\nout"
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (String.startsWith "[Plan Result]" p)
                        , \_ -> Expect.equal True (String.contains "[Plan: a-1]" p)
                        ]
                        ()
            ]
        , describe "impactScope"
            [ test "walks root → B → C → top session" <|
                \_ ->
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "a"
                    in
                    Expect.all
                        [ \s -> Expect.equal True s.rootHasInsertion
                        , \s -> Expect.equal 1 s.rootUserMessages
                        , \s -> Expect.equal 2 (List.length s.levels)
                        , \s ->
                            Expect.equal
                                [ "b", "c" ]
                                (List.map .planId s.levels)
                        , \s ->
                            Expect.equal
                                [ { planId = "b", nodeId = Just "t2", nodeSessionId = "s1", truncateSessionId = "s2", branchNodes = [ "t2", "t3" ] }
                                , { planId = "c", nodeId = Just "p2", nodeSessionId = "s2", truncateSessionId = "s3", branchNodes = [ "p2" ] }
                                ]
                                (List.map (\l -> { planId = l.planId, nodeId = l.nodeId, nodeSessionId = l.nodeSessionId, truncateSessionId = l.truncateSessionId, branchNodes = l.branchNodes }) s.levels)
                        , \s -> Expect.equal (Just "s3") s.topSessionId
                        , \s -> Expect.equal 0 (List.sum (List.map .truncateUserMessages s.levels))
                        ]
                        scope
            , test "closePlanIds = non-chain plans owned by truncated sessions" <|
                \_ ->
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "a"
                    in
                    Expect.equal [ "sib" ] scope.closePlanIds
            , test "needsConfirm: re-run with insertion → True; first run → False" <|
                \_ ->
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "a"

                        fresh =
                            C.impactScope
                                (ctxFor (Dict.fromList [ ( "s1", [ msg T.User "hello" ] ) ]))
                                "a"
                    in
                    Expect.equal ( C.needsConfirm scope, C.needsConfirm fresh )
                        ( True, False )
            , test "closed origin session stops the walk (no feedback possible)" <|
                \_ ->
                    let
                        closed =
                            ctxFor (Dict.remove "s1" sessionMap)
                    in
                    C.impactScope closed "a"
                        |> .levels
                        |> Expect.equal []
            , test "unknown root → empty scope" <|
                \_ ->
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "nope"
                    in
                    Expect.equal ( scope.levels, scope.topSessionId, C.needsConfirm scope )
                        ( [], Nothing, False )
            ]
        , describe "bindingInRun"
            [ test "finds the node bound to a session and its branch" <|
                \_ ->
                    C.bindingInRun "s1" (Just runB)
                        |> Expect.equal (Just ( "t2", [ "t2", "t3" ] ))
            , test "closed run → Nothing" <|
                \_ ->
                    C.bindingInRun "s1" Nothing
                        |> Expect.equal Nothing
            ]
        , describe "forkHistoryId"
            [ test "history id of the message before the last insertion" <|
                \_ ->
                    let
                        msgs =
                            [ withHistory "h-1" (msg T.User "keep")
                            , planResultMsg "a" "old"
                            , withHistory "h-2" (msg T.Assistant "drop")
                            ]
                    in
                    Expect.equal (Just "h-1") (C.forkHistoryId "a" msgs)
            , test "no insertion → Nothing" <|
                \_ ->
                    Expect.equal Nothing (C.forkHistoryId "a" [ msg T.User "x" ])
            , test "insertion at index 0 → Nothing (nothing to fork at)" <|
                \_ ->
                    Expect.equal Nothing (C.forkHistoryId "a" [ planResultMsg "a" "r" ])
            , test "predecessor without historyId → Nothing (fallback to in-memory)" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "keep"
                            , planResultMsg "a" "old"
                            ]
                    in
                    Expect.equal Nothing (C.forkHistoryId "a" msgs)
            ]
        , describe "buildCascadeState"
            [ test "captures node ids and old summaries for every level" <|
                \_ ->
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "a"

                        runs =
                            Dict.fromList
                                [ ( "a", Just runA )
                                , ( "b", Just runB )
                                , ( "c", Just runC )
                                ]
                    in
                    case C.buildCascadeState scope runs of
                        Just cs ->
                            Expect.all
                                [ \c -> Expect.equal "a" c.rootPlanId
                                , \c -> Expect.equal [ "b", "c" ] (List.map .planId c.levels)
                                , \c -> Expect.equal [ "t2", "p2" ] (List.map .nodeId c.levels)
                                , \c -> Expect.equal [ "s1", "s2" ] (List.map .nodeSessionId c.levels)
                                ]
                                cs

                        Nothing ->
                            Expect.fail "buildCascadeState returned Nothing"
            , test "missing ancestor run → Nothing (level cannot run)" <|
                \_ ->
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "a"
                    in
                    C.buildCascadeState scope Dict.empty
                        |> Expect.equal Nothing
            ]
        , describe "roundtrip through encodePlan-style JSON"
            [ test "meta parentPlanId survives encode/decode" <|
                \_ ->
                    let
                        meta =
                            metaOf "a" "s1" (Just "b")

                        encoded =
                            E.encode 2 (M.encodeMeta meta)
                    in
                    case D.decodeString M.decodeMeta encoded of
                        Ok m ->
                            Expect.equal (Just "b") m.parentPlanId

                        Err e ->
                            Expect.fail ("decode failed: " ++ D.errorToString e)
            ]
        ]
