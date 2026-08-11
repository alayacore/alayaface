module PlanUpdateTest exposing (suite)

{-| Direct unit tests for Plan/Update (M2): the plan-mode update logic
extracted from App/Update.elm is exercised WITHOUT going through the
full App.Update.update dispatcher — a stub Dispatch is injected where
an effect must route back through the dispatcher (CloseSessionFor etc.).
These are the "direct tests" replacing the previous indirect coverage.
-}

import Expect
import Json.Encode as E
import Set
import Test exposing (Test, describe, test)
import Dict
import App.Types as AT
import Plan.Update as PU
import Plan.Types as PT
import Plan.Meta as PM
import Plan.Cascade as PC
import Session.Meta as SM
import Session.Types as T
import TestHelpers exposing (initModelWithSession)


rawPlanJson : String
rawPlanJson =
    """{"type": "alayaface-plan", "name": "x", "concurrency": 2, "tasks": [
  { "id": "t1", "title": "T1", "prompt": "p1" },
  { "id": "t2", "title": "T2", "prompt": "p2", "depends_on": ["t1"] }
]}"""


{-| The fenced form a model emits in a message (Plan.Detect.isPlanMessage
matches on this).
-}
fencedPlan : String
fencedPlan =
    "```json\n" ++ rawPlanJson ++ "\n```"


plan : PT.Plan
plan =
    case PT.parsePlan rawPlanJson of
        Ok p ->
            p

        Err errs ->
            Debug.todo ("bad test plan: " ++ String.join "; " errs)


stubDispatch : PU.Dispatch
stubDispatch =
    \_ m -> ( m, Cmd.none )


planMessage : String -> T.Message
planMessage content =
    { id = "m-" ++ content
    , role = T.Assistant
    , content = content
    , toolId = Nothing
    , toolName = Nothing
    , isError = False
    , historyId = Nothing
    , media = Nothing
    }


overlayJson : String
overlayJson =
    E.encode 0 (PT.encodeRunState (PT.emptyRunState "resume" plan))


planWindowWithPlan : AT.PlanWindow
planWindowWithPlan =
    let
        v0 =
            AT.emptyPlanView
    in
    { view = { v0 | plan = Just plan, path = Just "/h/sessions/s1/plans/p1/p1.json" }
    , run = Nothing
    , runPath = Nothing
    , runLog = []
    , selectedNode = Nothing
    , resumePath = Nothing
    , infoOpen = False
    }


suite : Test
suite =
    describe "Plan/Update (direct)"
        [ describe "pure helpers"
            [ test "planWinKeyForPath strips the directory and .json" <|
                \_ ->
                    PU.planWinKeyForPath "/home/u/.alayaface/sessions/s1/plans/demo-1/demo-1.json"
                        |> Expect.equal "demo-1"
            , test "planWinKeyForPath handles an extensionless path" <|
                \_ ->
                    PU.planWinKeyForPath "plans/demo-1/demo-1"
                        |> Expect.equal "demo-1"
            , test "nextFsReq allocates monotonic ids" <|
                \_ ->
                    let
                        ( id, m1 ) =
                            PU.nextFsReq initModelWithSession

                        ( id2, m2 ) =
                            PU.nextFsReq m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal id "fs-1"
                        , \_ -> Expect.equal id2 "fs-2"
                        , \_ -> Expect.equal m1.fsReqCounter 1
                        , \_ -> Expect.equal m2.fsReqCounter 2
                        ]
                        initModelWithSession
            , test "planIndexForMessage counts fenced plan blocks" <|
                \_ ->
                    PU.planIndexForMessage
                        [ planMessage "plain text"
                        , planMessage fencedPlan
                        , planMessage "more text"
                        , planMessage fencedPlan
                        ]
                        |> Expect.equal 2
            , test "injectPlanErrorIntoSession appends an inline error" <|
                \_ ->
                    let
                        m =
                            PU.injectPlanErrorIntoSession [ "bad json" ] "s1" initModelWithSession

                        s =
                            Dict.get "s1" m.sessions |> Maybe.withDefault (T.emptySession "s1")
                    in
                    case List.reverse s.messages of
                        last :: _ ->
                            Expect.equal ( last.isError, last.content )
                                ( True, "Plan parsing failed: bad json" )

                        [] ->
                            Expect.fail "no message injected"
            , test "messageBoundToPlan matches the on-disk origin id" <|
                \_ ->
                    let
                        meta =
                            { origin = { sessionId = "s1", planIndex = 0 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = ""
                            , parentPlanId = Nothing
                            }

                        m =
                            { initModelWithSession | planMetas = Dict.insert "p1" meta Dict.empty }
                    in
                    Expect.equal ( PU.messageBoundToPlan m "s1" 0, PU.messageBoundToPlan m "s1" 1, PU.messageBoundToPlan m "other" 0 )
                        ( True, False, False )
            , test "messageBoundToPlan resolves a resumed live id" <|
                \_ ->
                    let
                        meta =
                            { origin = { sessionId = "s1", planIndex = 2 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = ""
                            , parentPlanId = Nothing
                            }

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planResumedFrom = Dict.insert "live1" "s1" Dict.empty
                            }
                    in
                    Expect.equal ( PU.messageBoundToPlan m "live1" 2 ) True
            , test "messageBoundToPlan follows a P38 fork through the lineage registry (same rule as the status bar)" <|
                \_ ->
                    let
                        -- The plan was created in s1; a re-run cascade
                        -- forked it to s-fork (truncated history). The
                        -- replayed plan message in s-fork must NOT
                        -- auto-create a duplicate — and the status-bar
                        -- query must bind it to the same plan (one rule,
                        -- Plan.Meta.planMetaForSessionIndex; the fork id
                        -- resolves through the lineage registry).
                        meta =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = "completed"
                            , parentPlanId = Nothing
                            }

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , sessions =
                                    Dict.insert "s-fork" (T.emptySession "s-fork") initModelWithSession.sessions
                                , sessionLineage =
                                    Dict.fromList
                                        [ ( "s1", SM.empty "s1" )
                                        , ( "s-fork", { conversationId = "s1", parentInstanceId = Just "s1" } )
                                        ]
                            }
                    in
                    Expect.equal
                        ( PU.messageBoundToPlan m "s-fork" 1
                        , PU.messageBoundToPlan m "s1" 1
                        , PU.messageBoundToPlan m "other" 1
                        )
                        ( True, True, False )
            , test "findResumedLive maps an on-disk id back to a live session" <|
                \_ ->
                    let
                        live =
                            T.emptySession "live1"

                        m =
                            { initModelWithSession
                                | sessions = Dict.insert "live1" live initModelWithSession.sessions
                                , planResumedFrom = Dict.insert "live1" "s1" Dict.empty
                            }
                    in
                    Expect.equal ( PU.findResumedLive "s1" m ) (Just "live1")
            , test "findResumedLive skips live ids with no open session" <|
                \_ ->
                    let
                        m =
                            { initModelWithSession
                                | planResumedFrom = Dict.insert "ghost" "s1" Dict.empty
                            }
                    in
                    Expect.equal ( PU.findResumedLive "s1" m ) Nothing
            , test "isSessionReady only accepts the session ready frame" <|
                \_ ->
                    let
                        ready =
                            { sessionId = "s1"
                            , tag = "SM"
                            , rawValue = "x"
                            , historyId = Nothing
                            , content = Just "x"
                            , json =
                                Just
                                    (E.object
                                        [ ( "type", E.string "session" )
                                        , ( "data", E.object [ ( "state", E.string "ready" ) ] )
                                        ]
                                    )
                            , userContentType = Nothing
                            }

                        taskFrame =
                            { ready | json = Just (E.object [ ( "type", E.string "task" ) ]) }
                    in
                    Expect.equal ( PU.isSessionReady ready, PU.isSessionReady taskFrame )
                        ( True, False )
            , test "lastAssistantOutput returns the last assistant text" <|
                \_ ->
                    let
                        s0 =
                            T.emptySession "s1"

                        m =
                            { initModelWithSession
                                | sessions =
                                    Dict.insert "s1"
                                        { s0 | messages = [ planMessage "hello", planMessage "world" ] }
                                        Dict.empty
                            }
                    in
                    PU.lastAssistantOutput m "s1" |> Expect.equal (Just "world")
            , test "planSystemPrompt pins the plan-mode contract" <|
                \_ ->
                    let
                        p =
                            PU.planSystemPrompt
                    in
                    Expect.equal ( String.contains "alayaface-plan" p, String.contains "type" p )
                        ( True, True )
            ]
        , describe "findPlanIdBySession (P39/Phase B lineage routing)"
            [ test "routes a fork instance to the node's conversation" <|
                \_ ->
                    let
                        runBound =
                            let
                                base =
                                    PT.emptyRunState "r-1" plan

                                n1 =
                                    { nodeId = "t1"
                                    , status = PT.Running
                                    , attempts = 1
                                    , maxAttempts = 3
                                    , conversationId = Just "conv-1"
                                    , lastSessionId = Just "conv-1"
                                    , attemptSessions = [ "conv-1" ]
                                    , failures = []
                                    , startedAt = Just 1
                                    , finishedAt = Nothing
                                    , output = Nothing
                                    }
                            in
                            { base | nodes = Dict.insert "t1" n1 base.nodes }

                        win =
                            { planWindowWithPlan | run = Just runBound }

                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" win Dict.empty
                                , sessionLineage =
                                    Dict.fromList
                                        [ ( "conv-1", SM.empty "conv-1" )
                                        , ( "fork-2", { conversationId = "conv-1", parentInstanceId = Just "conv-1" } )
                                        ]
                            }
                    in
                    -- The node is bound to conversation conv-1; the FORK
                    -- physical instance resolves through the registry to
                    -- conv-1 and finds the plan.
                    Expect.equal (PU.findPlanIdBySession m0 "fork-2") (Just "p1")
            , test "a root instance matches directly (identity)" <|
                \_ ->
                    let
                        runBound =
                            let
                                base =
                                    PT.emptyRunState "r-2" plan

                                n1 =
                                    { nodeId = "t1"
                                    , status = PT.Running
                                    , attempts = 1
                                    , maxAttempts = 3
                                    , conversationId = Just "s1"
                                    , lastSessionId = Just "s1"
                                    , attemptSessions = [ "s1" ]
                                    , failures = []
                                    , startedAt = Just 1
                                    , finishedAt = Nothing
                                    , output = Nothing
                                    }
                            in
                            { base | nodes = Dict.insert "t1" n1 base.nodes }

                        win =
                            { planWindowWithPlan | run = Just runBound }

                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" win Dict.empty
                            }
                    in
                    Expect.equal (PU.findPlanIdBySession m0 "s1") (Just "p1")
            , test "sessions not bound to any node do not match" <|
                \_ ->
                    let
                        win =
                            { planWindowWithPlan | run = Just (PT.emptyRunState "r-3" plan) }

                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" win Dict.empty
                            }
                    in
                    Expect.equal (PU.findPlanIdBySession m0 "stranger") Nothing
            ]
        , describe "resolveEventSessionId"
            [ test "resumed live ids resolve through planResumedFrom THEN the registry" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planResumedFrom = Dict.fromList [ ( "live-2", "orig-1" ) ]
                                , sessionLineage =
                                    Dict.fromList
                                        [ ( "orig-1", SM.empty "conv-9" )
                                        , ( "fork-3", { conversationId = "conv-9", parentInstanceId = Just "orig-1" } )
                                        ]
                            }
                    in
                    -- live-2 is a resume of orig-1 → conversation conv-9;
                    -- fork-3 is a fork instance → conv-9; an unknown id
                    -- falls back to itself (root identity).
                    Expect.all
                        [ \_ -> PU.resolveEventSessionId m0 "live-2" |> Expect.equal "conv-9"
                        , \_ -> PU.resolveEventSessionId m0 "fork-3" |> Expect.equal "conv-9"
                        , \_ -> PU.resolveEventSessionId m0 "unknown" |> Expect.equal "unknown"
                        ]
                        ()
            , test "resumed live id without a registry entry resolves to its original dir id" <|
                \_ ->
                    let
                        -- Node sessions are their own conversation roots
                        -- and are NOT registered (runner-created sessions
                        -- skip the registry); the resolved id must be the
                        -- ORIGINAL dir id — the node's binding — not the
                        -- fresh live id.
                        m0 =
                            { initModelWithSession
                                | planResumedFrom = Dict.fromList [ ( "live-2", "orig-1" ) ]
                            }
                    in
                    PU.resolveEventSessionId m0 "live-2" |> Expect.equal "orig-1"
            ]
        , describe "planMetaForMessage (status-bar binding)"
            [ test "resumed fork window binds through planResumedFrom → lineage registry → conversation origin" <|
                \_ ->
                    let
                        -- The plan was created in s1 and forked to s-fork;
                        -- the user views the fork through a RESUMED window
                        -- (fresh live id). The status bar binds: live →
                        -- s-fork (planResumedFrom) → s1 (lineage registry)
                        -- → meta origin.
                        meta =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = "completed"
                            , parentPlanId = Nothing
                            }

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planResumedFrom = Dict.insert "live-fork" "s-fork" Dict.empty
                                , sessionLineage =
                                    Dict.fromList
                                        [ ( "s1", SM.empty "s1" )
                                        , ( "s-fork", { conversationId = "s1", parentInstanceId = Just "s1" } )
                                        ]
                            }
                    in
                    PU.planMetaForMessage m "live-fork" 1
                        |> Maybe.map Tuple.first
                        |> Expect.equal (Just "p1")
            , test "no binding → Nothing (status bar renders the Open plan fallback)" <|
                \_ ->
                    PU.planMetaForMessage initModelWithSession "s1" 1
                        |> Expect.equal Nothing
            ]
        , describe "cascadeStepIn (P39/Phase C machine wiring)"
            [ test "InstanceReady registers the fork's lineage and the ResumeNode effect keeps the conversation binding" <|
                \_ ->
                    let
                        -- The ancestor plan p0 has a Succeeded node n1
                        -- whose session (conv "s1") was forked to "fork-x".
                        n1 =
                            { nodeId = "n1"
                            , status = PT.Succeeded
                            , attempts = 1
                            , maxAttempts = 3
                            , conversationId = Nothing
                            , lastSessionId = Just "s1"
                            , attemptSessions = [ "s1" ]
                            , failures = []
                            , startedAt = Just 1
                            , finishedAt = Just 2
                            , output = Just "old"
                            }

                        runP0 =
                            let
                                base =
                                    PT.emptyRunState "r0" plan
                            in
                            { base | status = PT.InProgress, nodes = Dict.insert "n1" n1 base.nodes }

                        winP0 =
                            { planWindowWithPlan | run = Just runP0 }

                        metaP1 =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "p1"
                            , lastStatus = "completed"
                            , parentPlanId = Nothing
                            }

                        target =
                            { childPlanId = "p1"
                            , summary = "new"
                            , planId = "p0"
                            , nodeId = "n1"
                            , forkSource = "s1"
                            , originSessionId = "s1"
                            }

                        cascade =
                            { rootPlanId = "p1"
                            , rootOldSummary = "old"
                            , levels =
                                [ { planId = "p0"
                                  , nodeId = "n1"
                                  , conversationId = "s1"
                                  , oldSummary = "old"
                                  }
                                ]
                            , phase = PC.WaitingFork
                            , currentPlanId = "p1"
                            , currentSummary = "new"
                            }

                        m0 =
                            { initModelWithSession
                                | sessions = Dict.insert "s1" (T.emptySession "s1") initModelWithSession.sessions
                                , planWindows = Dict.insert "p0" winP0 Dict.empty
                                , planMetas = Dict.insert "p1" metaP1 Dict.empty
                                , planCascade = Just cascade
                                , planCascadeFork = Just target
                            }

                        ( m1, _ ) =
                            PU.cascadeStepIn stubDispatch (PC.InstanceReady (Ok "fork-x")) m0
                    in
                    Expect.all
                        [ -- lineage registered: fork → conversation s1, parent s1
                        \m ->
                            Dict.get "fork-x" m.sessionLineage
                                |> Expect.equal
                                    (Just { conversationId = "s1", parentInstanceId = Just "s1" })
                        -- node keeps the CONVERSATION binding and is reset to WaitingForPlan
                        , \m ->
                            case Dict.get "p0" m.planWindows |> Maybe.andThen .run |> Maybe.andThen (\r -> Dict.get "n1" r.nodes) of
                                Just n ->
                                    Expect.equal
                                        ( n.status, n.conversationId, Maybe.map .status (Dict.get "p0" m.planWindows |> Maybe.andThen .run) )
                                        ( PT.WaitingForPlan, Just "s1", Just PT.InProgress )

                                Nothing ->
                                    Expect.fail "node n1 missing"
                        -- machine advanced to WaitingNode (resume in flight)
                        , \m ->
                            case m.planCascade of
                                Just cs ->
                                    Expect.equal
                                        ( cs.phase, List.map .conversationId cs.levels )
                                        ( PC.WaitingNode, [ "s1" ] )

                                Nothing ->
                                    Expect.fail "cascade missing"
                        -- fork consumed; fork session marked as replay
                        , \m ->
                            Expect.equal ( m.planCascadeFork, Set.member "fork-x" m.planReplaySessions )
                                ( Nothing, True )
                        ]
                        m1
            ]
        , describe "handlePlanReadTarget"
            [ test "open/import parses the plan and chains a run restore" <|
                \_ ->
                    let
                        target =
                            { reqId = "fs-1"
                            , planId = "p1"
                            , path = "/h/sessions/s1/plans/p1/p1.json"
                            , isResume = False
                            , continueRun = False
                            }

                        m0 =
                            { initModelWithSession | planReadTarget = Just target }

                        ( m1, _ ) =
                            PU.handlePlanReadTarget stubDispatch m0 target True rawPlanJson ""
                    in
                    case Dict.get "p1" m1.planWindows of
                        Just w ->
                            let
                                opened =
                                    case w.view.plan of
                                        Just p ->
                                            p.name

                                        Nothing ->
                                            "none"
                            in
                            Expect.all
                                [ \m -> Expect.equal opened "x"
                                , \m ->
                                    Expect.equal m.planReadTarget
                                        (Just
                                            { reqId = "fs-1"
                                            , planId = "p1"
                                            , path = "/h/sessions/s1/plans/p1/p1.run.json"
                                            , isResume = True
                                            , continueRun = False
                                            }
                                        )
                                , \m -> Expect.equal m.fsReqCounter 1
                                , \m -> Expect.equal m.planActiveId (Just "p1")
                                ]
                                m1

                        Nothing ->
                            Expect.fail "plan window not created"
            , test "silent restore loads a valid run overlay when the window has no run" <|
                \_ ->
                    let
                        target =
                            { reqId = "fs-2"
                            , planId = "p1"
                            , path = "/h/sessions/s1/plans/p1/p1.run.json"
                            , isResume = True
                            , continueRun = False
                            }

                        m0 =
                            { initModelWithSession
                                | planReadTarget = Just target
                                , planWindows = Dict.insert "p1" planWindowWithPlan Dict.empty
                            }

                        ( m1, _ ) =
                            PU.handlePlanReadTarget stubDispatch m0 target True overlayJson ""
                    in
                    case Dict.get "p1" m1.planWindows of
                        Just w ->
                            Expect.equal
                                ( w.run /= Nothing, w.runPath, m1.planReadTarget )
                                ( True, Just "/h/sessions/s1/plans/p1/p1.run.json", Nothing )

                        Nothing ->
                            Expect.fail "plan window missing"
            , test "silent restore ignores a corrupt run file" <|
                \_ ->
                    let
                        target =
                            { reqId = "fs-3"
                            , planId = "p1"
                            , path = "/h/sessions/s1/plans/p1/p1.run.json"
                            , isResume = True
                            , continueRun = False
                            }

                        m0 =
                            { initModelWithSession
                                | planReadTarget = Just target
                                , planWindows = Dict.insert "p1" planWindowWithPlan Dict.empty
                            }

                        ( m1, _ ) =
                            PU.handlePlanReadTarget stubDispatch m0 target True "not-json" ""
                    in
                    Expect.equal ( Dict.get "p1" m1.planWindows |> Maybe.andThen .run, m1.planReadTarget )
                        ( Nothing, Nothing )
            , test "continueRun with no run file clears resumePath" <|
                \_ ->
                    let
                        target =
                            { reqId = "fs-4"
                            , planId = "p1"
                            , path = "/h/sessions/s1/plans/p1/p1.run.json"
                            , isResume = True
                            , continueRun = True
                            }

                        w0 =
                            { planWindowWithPlan | resumePath = Just target.path }

                        m0 =
                            { initModelWithSession
                                | planReadTarget = Just target
                                , planWindows = Dict.insert "p1" w0 Dict.empty
                            }

                        ( m1, _ ) =
                            PU.handlePlanReadTarget stubDispatch m0 target False "" "read failed"
                    in
                    case Dict.get "p1" m1.planWindows of
                        Just w ->
                            Expect.equal ( w.resumePath, m1.planReadTarget ) ( Nothing, Nothing )

                        Nothing ->
                            Expect.fail "plan window missing"
            , test "continueRun with a corrupt run file surfaces the error" <|
                \_ ->
                    let
                        target =
                            { reqId = "fs-5"
                            , planId = "p1"
                            , path = "/h/sessions/s1/plans/p1/p1.run.json"
                            , isResume = True
                            , continueRun = True
                            }

                        m0 =
                            { initModelWithSession
                                | planReadTarget = Just target
                                , planWindows = Dict.insert "p1" planWindowWithPlan Dict.empty
                            }

                        ( m1, _ ) =
                            PU.handlePlanReadTarget stubDispatch m0 target True "junk" ""
                    in
                    case Dict.get "p1" m1.planWindows of
                        Just w ->
                            Expect.equal
                                ( w.resumePath
                                , List.head w.view.errors |> Maybe.map (String.startsWith "Invalid run state: ")
                                , m1.planReadTarget
                                )
                                ( Nothing, Just True, Nothing )

                        Nothing ->
                            Expect.fail "plan window missing"
            ]
        , describe "setPlanErrors"
            [ test "writes errors into the active plan window" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , planWindows = Dict.insert "p1" planWindowWithPlan Dict.empty
                            }

                        m1 =
                            PU.setPlanErrors [ "boom" ] m0
                    in
                    case Dict.get "p1" m1.planWindows of
                        Just w ->
                            Expect.equal w.view.errors [ "boom" ]

                        Nothing ->
                            Expect.fail "plan window missing"
            , test "creates an error-only window when no plan is active" <|
                \_ ->
                    let
                        m1 =
                            PU.setPlanErrors [ "boom" ] initModelWithSession
                    in
                    Expect.equal (Dict.size m1.planWindows) 1
            ]
        , describe "restartPlanCascade"
            [ test "no-op without sub-plans (stub dispatch)" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            PU.restartPlanCascade stubDispatch "p1" initModelWithSession
                    in
                    Expect.equal m1 initModelWithSession
            ]
        , describe "subPlansOfPlan"
            [ test "returns sub-plans whose origin session matches a WaitingForPlan node's conversation" <|
                \_ ->
                    let
                        baseRun =
                            PT.emptyRunState "run-1" plan

                        nodes =
                            case Dict.get "t1" baseRun.nodes of
                                Just n ->
                                    Dict.insert "t1" { n | status = PT.WaitingForPlan, conversationId = Just "node-sess-1" } baseRun.nodes

                                Nothing ->
                                    baseRun.nodes

                        win =
                            { planWindowWithPlan | run = Just { baseRun | status = PT.InProgress, nodes = nodes } }

                        meta originSid =
                            { origin = { sessionId = originSid, planIndex = 0 }
                            , feedbacks = []
                            , depth = 2
                            , createdAt = 0
                            , name = "sub"
                            , lastStatus = ""
                            , parentPlanId = Just "p1"
                            }

                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" win Dict.empty
                                , planMetas =
                                    Dict.fromList
                                        [ ( "sp1", meta "node-sess-1" )
                                        , ( "sp2", meta "node-sess-1" )
                                        , ( "other", meta "unrelated-sess" )
                                        ]
                            }
                    in
                    PU.subPlansOfPlan "p1" m0
                        |> List.sort
                        |> Expect.equal [ "sp1", "sp2" ]
            , test "a WaitingForPlan node without a conversation binding yields no bogus empty-string match" <|
                \_ ->
                    let
                        baseRun =
                            PT.emptyRunState "run-1" plan

                        nodes =
                            case Dict.get "t1" baseRun.nodes of
                                Just n ->
                                    Dict.insert "t1" { n | status = PT.WaitingForPlan, conversationId = Nothing } baseRun.nodes

                                Nothing ->
                                    baseRun.nodes

                        win =
                            { planWindowWithPlan | run = Just { baseRun | status = PT.InProgress, nodes = nodes } }

                        meta originSid =
                            { origin = { sessionId = originSid, planIndex = 0 }
                            , feedbacks = []
                            , depth = 2
                            , createdAt = 0
                            , name = "sub"
                            , lastStatus = ""
                            , parentPlanId = Just "p1"
                            }

                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" win Dict.empty
                                , planMetas = Dict.fromList [ ( "sp1", meta "" ) ]
                            }
                    in
                    PU.subPlansOfPlan "p1" m0 |> Expect.equal []
            , test "Pending nodes (not delegated) are not sub-plan owners" <|
                \_ ->
                    let
                        baseRun =
                            PT.emptyRunState "run-1" plan

                        win =
                            { planWindowWithPlan | run = Just { baseRun | status = PT.InProgress } }

                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" win Dict.empty
                                , planMetas =
                                    Dict.fromList
                                        [ ( "sp1", { origin = { sessionId = "any-session", planIndex = 0 }, feedbacks = [], depth = 2, createdAt = 0, name = "sub", lastStatus = "", parentPlanId = Just "p1" } )
                                        ]
                            }
                    in
                    PU.subPlansOfPlan "p1" m0 |> Expect.equal []
            ]
        , describe "collectCloseSet (P39/D1 ownership graph)"
            (let
                metaOf originSid planId =
                    { origin = { sessionId = originSid, planIndex = 1 }
                    , feedbacks = []
                    , depth = 1
                    , createdAt = 0
                    , name = planId
                    , lastStatus = ""
                    , parentPlanId = Nothing
                    }

                -- s1 owns p1; p1's node session s2 owns p2.
                closeModel =
                    { initModelWithSession
                        | sessions =
                            Dict.fromList [ ( "s1", T.emptySession "s1" ), ( "s2", T.emptySession "s2" ) ]
                        , planMetas =
                            Dict.fromList
                                [ ( "p1", metaOf "s1" "p1" )
                                , ( "p2", metaOf "s2" "p2" )
                                ]
                        , planNodeSessions = Dict.fromList [ ( "s2", "p1/n1" ) ]
                    }
             in
             [ test "a session collects its plans → node sessions → sub-plans in ONE traversal" <|
                    \_ ->
                        let
                            ( plans, sessions ) =
                                PU.collectCloseSetFromSession closeModel "s1"
                        in
                        Expect.equal
                            ( List.sort plans, List.sort sessions )
                            ( [ "p1", "p2" ], [ "s1", "s2" ] )
              , test "a plan collects its node sessions and their sub-plans, NOT its origin session" <|
                    \_ ->
                        let
                            ( plans, sessions ) =
                                PU.collectCloseSetFromPlan closeModel "p1"
                        in
                        Expect.equal
                            ( List.sort plans, List.sort sessions )
                            ( [ "p1", "p2" ], [ "s2" ] )
              , test "deduplicates shared sessions/plans" <|
                    \_ ->
                        let
                            m =
                                { closeModel
                                    | planMetas =
                                        Dict.fromList
                                            [ ( "p1", metaOf "s1" "p1" )
                                            , ( "p2", metaOf "s1" "p2" )
                                            ]
                                    , planNodeSessions = Dict.empty
                                }
                        in
                        Expect.equal
                            ( PU.collectCloseSetFromSession m "s1" )
                            ( [ "p1", "p2" ], [ "s1" ] )
              , test "cycle-safe: a session that is its own plan's node session terminates" <|
                    \_ ->
                        let
                            -- pathological cycle: s1 owns p1 AND is p1's node session.
                            cyc =
                                { closeModel
                                    | planNodeSessions = Dict.fromList [ ( "s1", "p1/n1" ) ]
                                }
                        in
                        Expect.equal
                            ( PU.collectCloseSetFromSession cyc "s1" )
                            ( [ "p1" ], [ "s1" ] )
              ])
        ]
