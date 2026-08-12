module PlanCascadeTest exposing (tests)

import Dict exposing (Dict)
import Expect
import Json.Decode as D
import Json.Encode as E
import Plan.Cascade as C
import Plan.Meta as M
import Plan.Types as PT
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


{-| A plan JSON message as the model emits it (Plan.Detect.isPlanMessage
matches the ```json fence + alayaface-plan type marker).
-}
planMsg : String -> T.Message
planMsg name =
    msg T.Assistant
        ("```json\n{\"type\":\"alayaface-plan\",\"schema_version\":1,\"name\":\""
            ++ name
            ++ "\",\"tasks\":[]}\n```"
        )


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


ctxFor : Dict String (List T.Message) -> { planMetas : Dict String M.PlanMeta, runs : Dict String (Maybe PT.RunState), sessions : Dict String T.SessionState }
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
    }


sessionMap : Dict String (List T.Message)
sessionMap =
    Dict.fromList
        [ -- root A's origin: plan JSON + old result + a follow-up after
          ( "s1"
          , [ msg T.User "hello"
            , planMsg "A"
            , planResultMsg "a" "result-a"
            , msg T.Assistant "done"
            , msg T.User "my follow-up"
            ]
          )
        , -- B's origin: plan JSON + old result, nothing after
          ( "s2"
          , [ msg T.User "orig"
            , planMsg "B"
            , planResultMsg "b" "result-b"
            ]
          )
        , -- top-level plain session (open)
          ( "s3", [ msg T.User "top" ] )
        ]


tests : Test
tests =
    describe "Plan.Cascade (P38)"
        [ describe "findPlanAnchor"
            [ test "index right after the planIndex-th plan message" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "intro"
                            , planMsg "A"
                            , msg T.User "between"
                            , planMsg "B"
                            ]
                    in
                    Expect.equal (Just 4) (C.findPlanAnchor 2 msgs)
            , test "planIndex <= 0 → Nothing" <|
                \_ ->
                    Expect.equal Nothing (C.findPlanAnchor 0 [ planMsg "A" ])
            , test "planIndex out of range → Nothing (plan message truncated away)" <|
                \_ ->
                    Expect.equal Nothing (C.findPlanAnchor 3 [ planMsg "A" ])
            , test "no plan messages → Nothing" <|
                \_ ->
                    Expect.equal Nothing (C.findPlanAnchor 1 [ msg T.User "x" ])
            ]
        , describe "anchorIndexFor"
            [ test "the plan's creation point is the anchor even when an old result exists" <|
                \_ ->
                    -- Unified semantics: a plan's result ALWAYS replaces
                    -- what follows its plan JSON — the old [Plan Result]
                    -- feedback is not a separate anchor (input is
                    -- disabled while the plan runs, so nothing
                    -- legitimately sits between the plan and its result).
                    let
                        msgs =
                            [ planMsg "A"
                            , msg T.User "between"
                            , planResultMsg "a" "old"
                            , msg T.Assistant "after"
                            ]
                    in
                    Expect.equal (Just 1) (C.anchorIndexFor 1 msgs)
            , test "old feedback appended PAST another plan → still the creation anchor" <|
                \_ ->
                    -- Pre-D8 bug data: A completed late, its feedback was
                    -- appended after plan B. The anchor is A's creation
                    -- point regardless — B (and the late feedback) are
                    -- replaced.
                    let
                        msgs =
                            [ planMsg "A"
                            , planMsg "B"
                            , planResultMsg "b" "b-result"
                            , planResultMsg "a" "a-late"
                            ]
                    in
                    Expect.equal (Just 1) (C.anchorIndexFor 1 msgs)
            , test "a mid-conversation plan replaces what follows" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "intro"
                            , planMsg "A"
                            , planMsg "B"
                            , planResultMsg "b" "b-result"
                            ]
                    in
                    Expect.equal (Just 2) (C.anchorIndexFor 1 msgs)
            , test "anchor at the very end → Nothing (plain append)" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "intro"
                            , planMsg "A"
                            ]
                    in
                    Expect.equal Nothing (C.anchorIndexFor 1 msgs)
            , test "no anchor at all → Nothing" <|
                \_ ->
                    Expect.equal Nothing (C.anchorIndexFor 1 [ msg T.User "x" ])
            ]
        , describe "countUserMessagesAfter"
            [ test "counts only User messages after the anchor" <|
                \_ ->
                    let
                        msgs =
                            [ planMsg "A"
                            , msg T.Assistant "answer"
                            , msg T.User "typed"
                            , msg T.Tool "tool"
                            ]
                    in
                    Expect.equal 1 (C.countUserMessagesAfter (C.anchorIndexFor 1 msgs) msgs)
            , test "no anchor → 0" <|
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
            , test "a resumed session (work copy) still shows the insertion point (C2b)" <|
                \_ ->
                    -- C2b：Session.id = s1（稳定身份，无血缘）；resume 后
                    -- 窗口按 Session.id 呈现（内容 = 工作副本的截断历史）。
                    -- impactScope 按 origin 直接定位，找到旧 [Plan Result]
                    -- → 有插入点（级联确认仍会出现）。
                    let
                        base =
                            ctxFor sessionMap

                        s1msgs =
                            Dict.get "s1" sessionMap |> Maybe.withDefault []

                        liveFork =
                            let
                                liveBase =
                                    T.emptySession "s1"
                            in
                            { liveBase | messages = s1msgs }

                        ctx =
                            { base | sessions = Dict.insert "s1" liveFork base.sessions }
                    in
                    Expect.equal
                        (C.impactScope ctx "a").rootHasInsertion
                        True
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
            , test "P39/D8: a mid-conversation plan that never completed still anchors the scope" <|
                \_ ->
                    -- plan "a" (planIndex 1) never completed here: another
                    -- plan B and its result sit after A's plan JSON. The
                    -- scope must anchor at A's CREATION point (right after
                    -- its plan JSON) — replacing what follows (B and the
                    -- typed follow-up) instead of appending to the end.
                    let
                        msgs =
                            [ msg T.User "intro"
                            , planMsg "A"
                            , planMsg "B"
                            , planResultMsg "b" "b-result"
                            , msg T.User "typed after"
                            ]

                        scope =
                            C.impactScope (ctxFor (Dict.fromList [ ( "s1", msgs ) ])) "a"
                    in
                    Expect.all
                        [ \s -> Expect.equal True s.rootHasInsertion
                        , \s -> Expect.equal 2 s.rootUserMessages
                        , \s -> Expect.equal [ "sib" ] s.closePlanIds
                        ]
                        scope
            , test "P39/D8: first run with nothing after the plan → no confirmation (plain append)" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "intro"
                            , planMsg "A"
                            ]

                        scope =
                            C.impactScope (ctxFor (Dict.fromList [ ( "s1", msgs ) ])) "a"
                    in
                    Expect.equal ( scope.rootHasInsertion, C.needsConfirm scope )
                        ( False, False )
            , test "P39/D8: closePlans matches by conversation — a fork head truncation closes plans created on the root instance" <|
                \_ ->
                    -- The root conversation s1 was forked (head = s-fork):
                    -- truncating the head must still close plan "sib"
                    -- whose meta records the ORIGINAL instance id.
                    let
                        base =
                            ctxFor sessionMap

                        scope =
                            C.impactScope base "a"
                    in
                    Expect.equal [ "sib" ] scope.closePlanIds
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
            [ test "forks at the plan JSON (keeps it, drops what follows)" <|
                \_ ->
                    let
                        msgs =
                            [ withHistory "h-0" (msg T.User "intro")
                            , withHistory "h-1" (planMsg "A")
                            , withHistory "h-2" (planMsg "B")
                            , withHistory "h-3" (planResultMsg "b" "b-result")
                            ]
                    in
                    -- Unified semantics: the fork point is the plan's
                    -- plan JSON — fork "up to" h-1 keeps the plan JSON
                    -- and drops plan B and everything after.
                    Expect.equal (Just "h-1") (C.forkHistoryId 1 msgs)
            , test "no plan message → Nothing" <|
                \_ ->
                    Expect.equal Nothing (C.forkHistoryId 1 [ msg T.User "x" ])
            , test "plan at index 0 → Nothing (nothing to fork at)" <|
                \_ ->
                    Expect.equal Nothing (C.forkHistoryId 1 [ planMsg "A" ])
            , test "plan JSON without historyId → Nothing (fallback to in-memory)" <|
                \_ ->
                    let
                        msgs =
                            [ msg T.User "keep"
                            , planMsg "A"
                            , planMsg "B"
                            ]
                    in
                    Expect.equal Nothing (C.forkHistoryId 1 msgs)
            , test "anchor at the very end → Nothing (plain append)" <|
                \_ ->
                    let
                        msgs =
                            [ withHistory "h-0" (msg T.User "intro")
                            , withHistory "h-1" (planMsg "A")
                            ]
                    in
                    Expect.equal Nothing (C.forkHistoryId 1 msgs)
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
                                , \c -> Expect.equal [ "s1", "s2" ] (List.map .conversationId c.levels)
                                , \c -> Expect.equal C.WaitingPlan c.phase
                                ]
                                cs

                        Nothing ->
                            Expect.fail "buildCascadeState returned Nothing"
            , test "P39/D8: root without a run (FIRST run) still builds the cascade" <|
                \_ ->
                    -- A plan that never completed but has an anchor is
                    -- confirmed and armed BEFORE it runs; the machine is
                    -- built with no old summary to compare against.
                    let
                        scope =
                            C.impactScope (ctxFor sessionMap) "a"
                    in
                    case C.buildCascadeState scope Dict.empty of
                        Just cs ->
                            Expect.all
                                [ \c -> Expect.equal "a" c.rootPlanId
                                , \c -> Expect.equal "" c.rootOldSummary
                                , \c -> Expect.equal C.WaitingPlan c.phase
                                ]
                                cs

                        Nothing ->
                            Expect.fail "first-run cascade must build"
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
        , describe "cascadeStep (P39/Phase C state machine)"
            (let
                mkLevel planId nodeId convId old =
                    { planId = planId
                    , nodeId = nodeId
                    , conversationId = convId
                    , oldSummary = old
                    }

                mkState phase levels currentPlan currentSummary =
                    { rootPlanId = "a"
                    , rootOldSummary = "old-root"
                    , levels = levels
                    , phase = phase
                    , currentPlanId = currentPlan
                    , currentSummary = currentSummary
                    }

                lvlB =
                    mkLevel "b" "t2" "s1" "old-b"

                lvlC =
                    mkLevel "c" "p2" "s2" "old-c"
             in
             [ test "ReRunConfirmed arms the machine in WaitingPlan" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.ReRunConfirmed (mkState C.Done [] "a" "x")) (mkState C.Done [] "a" "x")
                        in
                        Expect.equal ( cs2.phase, effects ) ( C.WaitingPlan, [] )
              , test "root completes with a CHANGED summary → ForkInstance" <|
                    \_ ->
                        let
                            cs =
                                mkState C.WaitingPlan [ lvlB ] "a" ""

                            ( cs2, effects ) =
                                C.cascadeStep (C.PlanCompleted "a" "new-root") cs
                        in
                        Expect.all
                            [ \_ -> Expect.equal ( cs2.phase, effects ) ( C.WaitingFork, [ C.ForkInstance "a" ] )
                            , \_ -> Expect.equal ( cs2.currentPlanId, cs2.currentSummary ) ( "a", "new-root" )
                            ]
                            ()
              , test "root completes UNCHANGED (gate hit) → silently Done" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.PlanCompleted "a" "old-root") (mkState C.WaitingPlan [ lvlB ] "a" "")
                        in
                        Expect.equal ( cs2.phase, effects ) ( C.Done, [] )
              , test "unrelated plan completion in WaitingPlan is ignored" <|
                    \_ ->
                        let
                            cs =
                                mkState C.WaitingPlan [ lvlB ] "a" ""

                            ( cs2, effects ) =
                                C.cascadeStep (C.PlanCompleted "zzz" "x") cs
                        in
                        Expect.equal ( cs2, effects ) ( cs, [] )
              , test "InstanceReady success → RegisterFork + InsertResult + ResumeNode (head level)" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.InstanceReady (Ok "fork-1")) (mkState C.WaitingFork [ lvlB ] "a" "new-root")
                        in
                        Expect.equal
                            ( cs2.phase, effects )
                            ( C.WaitingNode
                            , [ C.RegisterFork "fork-1"
                              , C.InsertResult "a" "fork-1" "new-root"
                              , C.ResumeNode "b" "t2" "s1"
                              ]
                            )
              , test "InstanceReady success with NO levels → register + insert only" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.InstanceReady (Ok "fork-1")) (mkState C.WaitingFork [] "a" "new-root")
                        in
                        Expect.equal
                            ( cs2.phase, effects )
                            ( C.WaitingNode
                            , [ C.RegisterFork "fork-1"
                              , C.InsertResult "a" "fork-1" "new-root"
                              ]
                            )
              , test "InstanceReady failure → Done (nothing was truncated)" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.InstanceReady (Err "boom")) (mkState C.WaitingFork [ lvlB ] "a" "")
                        in
                        Expect.equal ( cs2.phase, effects ) ( C.Done, [] )
              , test "InsertInPlace (no fork point) → insert + resume, no lineage" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.InsertInPlace "s1") (mkState C.WaitingFork [ lvlB ] "a" "new-root")
                        in
                        Expect.equal
                            ( cs2.phase, effects )
                            ( C.WaitingNode
                            , [ C.InsertResult "a" "s1" "new-root"
                              , C.ResumeNode "b" "t2" "s1"
                              ]
                            )
              , test "NodeSucceeded on the head node → BranchRunning + BranchRerun" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.NodeSucceeded "b" "t2") (mkState C.WaitingNode [ lvlB ] "a" "")
                        in
                        Expect.equal ( cs2.phase, effects ) ( C.BranchRunning, [ C.BranchRerun "b" "t2" ] )
              , test "NodeSucceeded for a different node is ignored" <|
                    \_ ->
                        let
                            cs =
                                mkState C.WaitingNode [ lvlB ] "a" ""

                            ( cs2, effects ) =
                                C.cascadeStep (C.NodeSucceeded "b" "OTHER") cs
                        in
                        Expect.equal ( cs2, effects ) ( cs, [] )
              , test "LevelFailed on the head node → Done" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.LevelFailed "b" "t2") (mkState C.WaitingNode [ lvlB ] "a" "")
                        in
                        Expect.equal ( cs2.phase, effects ) ( C.Done, [] )
              , test "head completes UNCHANGED (gate hit) → Done" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.PlanCompleted "b" "old-b") (mkState C.BranchRunning [ lvlB ] "a" "")
                        in
                        Expect.equal ( cs2.phase, effects ) ( C.Done, [] )
              , test "head completes CHANGED → drop the level, fork the next (multi-level propagation)" <|
                    \_ ->
                        let
                            ( cs2, effects ) =
                                C.cascadeStep (C.PlanCompleted "b" "new-b") (mkState C.BranchRunning [ lvlB, lvlC ] "a" "")
                        in
                        Expect.equal
                            ( cs2.phase, cs2.levels, effects )
                            ( C.WaitingFork, [ lvlC ], [ C.ForkInstance "b" ] )
              , test "multi-level end-to-end: root → fork → node → branch → head → next fork" <|
                    \_ ->
                        let
                            s0 =
                                mkState C.WaitingPlan [ lvlB, lvlC ] "a" ""

                            ( s1, e1 ) =
                                C.cascadeStep (C.PlanCompleted "a" "new-root") s0

                            ( s2, e2 ) =
                                C.cascadeStep (C.InstanceReady (Ok "fork-1")) s1

                            ( s3, e3 ) =
                                C.cascadeStep (C.NodeSucceeded "b" "t2") s2

                            ( s4, e4 ) =
                                C.cascadeStep (C.PlanCompleted "b" "new-b") s3

                            ( s5, e5 ) =
                                C.cascadeStep (C.InstanceReady (Ok "fork-2")) s4
                        in
                        Expect.all
                            [ \_ ->
                                Expect.equal
                                    [ s1.phase, s2.phase, s3.phase, s4.phase, s5.phase ]
                                    [ C.WaitingFork, C.WaitingNode, C.BranchRunning, C.WaitingFork, C.WaitingNode ]
                            , \_ ->
                                Expect.equal e1 [ C.ForkInstance "a" ]
                            , \_ ->
                                Expect.equal e2
                                    [ C.RegisterFork "fork-1", C.InsertResult "a" "fork-1" "new-root", C.ResumeNode "b" "t2" "s1" ]
                            , \_ -> Expect.equal e3 [ C.BranchRerun "b" "t2" ]
                            , \_ -> Expect.equal e4 [ C.ForkInstance "b" ]
                            , \_ ->
                                Expect.equal e5
                                    [ C.RegisterFork "fork-2", C.InsertResult "b" "fork-2" "new-b", C.ResumeNode "c" "p2" "s2" ]
                            ]
                            ()
              , test "events in the wrong phase are ignored (zero ordering assumptions)" <|
                    \_ ->
                        let
                            cs =
                                mkState C.WaitingPlan [ lvlB ] "a" ""

                            ( cs2, effects ) =
                                C.cascadeStep (C.NodeSucceeded "b" "t2") cs
                        in
                        Expect.equal ( cs2, effects ) ( cs, [] )
              ])
        ]
