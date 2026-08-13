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
import Arch.Values as AV
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
            , test "planDirIn follows the origin's REAL directory when known (P28 layout fix)" <|
                \_ ->
                    let
                        home = "/h"
                        -- a plan child (node session) nested under the
                        -- top-level session's plan subtree
                        dirMap =
                            Dict.fromList
                                [ ( "s1", "/h/.alayaface/sessions/s1" )
                                , ( "node-1", "/h/.alayaface/sessions/s1/plans/p1/t1/node-1" )
                                ]
                    in
                    Expect.equal
                        ( PU.planDirIn home dirMap "node-1" "sub" )
                        "/h/.alayaface/sessions/s1/plans/p1/t1/node-1/plans/sub"
            , test "planDirIn falls back to the top-level path for unknown origins" <|
                \_ ->
                    Expect.equal
                        ( PU.planDirIn "/h" Dict.empty "s9" "p9" )
                        "/h/.alayaface/sessions/s9/plans/p9"
            , test "sessionDirForCreate nests plan children, top-levels plain sessions" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planCreating = Just (AT.RunnerCreate "p1" "t1")
                                , planMetas =
                                    Dict.fromList
                                        [ ( "p1", { origin = { sessionId = "s1", planIndex = 1 }, feedbacks = [], depth = 1, createdAt = 0, name = "p1", lastStatus = "", parentPlanId = Nothing } )
                                        ]
                                , sessionDirMap =
                                    Dict.fromList
                                        [ ( "s1", "/h/.alayaface/sessions/s1" ) ]
                                , homeDir = "/h"
                            }
                    in
                    Expect.equal
                        ( PU.sessionDirForCreate m0 "uuid-1" )
                        "/h/.alayaface/sessions/s1/plans/p1/t1/uuid-1"
            , test "sessionDirForCreate uses the top level for plain sessions" <|
                \_ ->
                    Expect.equal
                        ( PU.sessionDirForCreate { initModelWithSession | homeDir = "/h" } "uuid-1" )
                        "/h/.alayaface/sessions/uuid-1"
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
            , test "messageBoundToPlan binds by the stable Session.id (plain session)" <|
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
            , test "messageBoundToPlan binds a resumed session by its stable Session.id (C2b)" <|
                \_ ->
                    -- After a resume the window key is still Session.id
                    -- ("s1"), and the work copy is live1
                    -- (sessionWorkCopies[s1] = live1). The binding matches
                    -- meta origin directly by Session.id — no more
                    -- planResumedFrom resolution.
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
                                , sessionWorkCopies = Dict.insert "s1" "live1" Dict.empty
                            }
                    in
                    Expect.equal ( PU.messageBoundToPlan m "s1" 2 ) True
            , test "messageBoundToPlan binds a forked session by its stable Session.id (work copy differs)" <|
                \_ ->
                    -- After a re-run fork the window key is still
                    -- Session.id (plan origin "s1"), and the work copy is
                    -- s-fork (sessionWorkCopies[s1] = s-fork). The binding
                    -- hits meta origin directly — no lineage registry; the
                    -- work-copy core id ("s-fork") itself binds no plan.
                    let
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
                                , sessionWorkCopies = Dict.insert "s1" "s-fork" Dict.empty
                            }
                    in
                    Expect.equal
                        ( PU.messageBoundToPlan m "s1" 1
                        , PU.messageBoundToPlan m "s-fork" 1
                        , PU.messageBoundToPlan m "other" 1
                        )
                        ( True, False, False )
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
            , test "recursionGuardPrompt pins the recursion-bound contract" <|
                \_ ->
                    let
                        p =
                            PU.recursionGuardPrompt
                    in
                    Expect.equal
                        ( String.contains "do NOT output another plan" p, String.length p > 20 )
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
                            }
                    in
                    -- C2b-7: no lineage — nodes bind directly by session
                    -- id; the bound id (conv-1) finds the plan; unrelated
                    -- ids do not resolve.
                    Expect.all
                        [ \mm -> Expect.equal (PU.findPlanIdBySession mm "conv-1") (Just "p1")
                        , \mm -> Expect.equal (PU.findPlanIdBySession mm "fork-2") Nothing
                        , \mm -> Expect.equal (PU.findPlanIdBySession mm "unknown") Nothing
                        ]
                        m0
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
        , describe "planMetaForMessage (status-bar binding)"
            [ test "versionPlanStatus: plan status resolves from the session's version view (C)" <|
                \_ ->
                    -- V0 (A unexecuted, B completed) → A shows not-started,
                    -- B shows completed — from the VERSION, not the global
                    -- plan state.
                    let
                        runB =
                            AV.RunSummary "r-b" "completed" 1 (Just 2) "## b"

                        v0 =
                            { blocks = [ "b0" ]
                            , planViews = Dict.fromList [ ( "pA", Nothing ), ( "pB", Just "run-b" ) ]
                            , parent = Nothing
                            }

                        m =
                            { initModelWithSession
                                | sessionRefs =
                                    Dict.insert "s1"
                                        (AV.SessionRefs "s1" "v0" [ "v0" ] Nothing)
                                        Dict.empty
                                , versionCache = Dict.insert "v0" v0 Dict.empty
                                , runSummaries = Dict.insert "run-b" runB Dict.empty
                            }
                    in
                    Expect.all
                        [ \_ -> Expect.equal (PU.versionPlanStatus m "s1" "pA") (Just "not-started")
                        , \_ -> Expect.equal (PU.versionPlanStatus m "s1" "pB") (Just "completed")
                        , \_ -> Expect.equal (PU.versionPlanStatus m "s1" "unknown") Nothing
                        ]
                        ()
            , test "versionPlanStatus reads the version of the stable Session.id (C2b)" <|
                \_ ->
                    -- After a resume the window key is still Session.id
                    -- ("s1"); the work copy live-s1 is just an edge detail.
                    -- Version lookup goes straight by Session.id.
                    let
                        v0 =
                            { blocks = []
                            , planViews = Dict.fromList [ ( "pA", Just "run-a" ) ]
                            , parent = Nothing
                            }

                        m =
                            { initModelWithSession
                                | sessionRefs =
                                    Dict.insert "s1"
                                        (AV.SessionRefs "s1" "v0" [ "v0" ] Nothing)
                                        Dict.empty
                                , versionCache = Dict.insert "v0" v0 Dict.empty
                                , runSummaries = Dict.insert "run-a" (AV.RunSummary "r-a" "completed" 1 (Just 2) "## a") Dict.empty
                            }
                    in
                    Expect.equal (PU.versionPlanStatus m "s1" "pA") (Just "completed")
            , test "no refs yet → Nothing (falls back to the current global status)" <|
                \_ ->
                    PU.versionPlanStatus initModelWithSession "s1" "pA"
                        |> Expect.equal Nothing
            , test "fork window status bar binds by the stable Session.id (C2b)" <|
                \_ ->
                    -- After a user re-run fork, the window being viewed has
                    -- key = Session.id (plan origin "s1"), and the work copy
                    -- is s-fork (sessionWorkCopies[s1] = s-fork). The status
                    -- bar hits meta origin directly by Session.id — no more
                    -- planResumedFrom → lineage-registry resolution chain.
                    let
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
                                , sessionWorkCopies = Dict.insert "s1" "s-fork" Dict.empty
                            }
                    in
                    PU.planMetaForMessage m "s1" 1
                        |> Maybe.map Tuple.first
                        |> Expect.equal (Just "p1")
            , test "no binding → Nothing (status bar renders the Open plan fallback)" <|
                \_ ->
                    PU.planMetaForMessage initModelWithSession "s1" 1
                        |> Expect.equal Nothing
            ]
        , describe "planRunningForSession (input disabled while a plan runs)"
            [ test "InProgress plan of the conversation → True" <|
                \_ ->
                    let
                        meta =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = "running"
                            , parentPlanId = Nothing
                            }

                        baseRun =
                            PT.emptyRunState "r1" plan

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planWindows =
                                    Dict.insert "p1"
                                        { planWindowWithPlan | run = Just { baseRun | status = PT.InProgress } }
                                        Dict.empty
                            }
                    in
                    PU.planRunningForSession m "s1"
                        |> Expect.equal True
            , test "a RESUMED/FORKED instance of the conversation → True" <|
                \_ ->
                    let
                        meta =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = "running"
                            , parentPlanId = Nothing
                            }

                        baseRun =
                            PT.emptyRunState "r1" plan

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planWindows =
                                    Dict.insert "p1"
                                        { planWindowWithPlan | run = Just { baseRun | status = PT.InProgress } }
                                        Dict.empty
                            }
                    in
                    -- C2b-7: no lineage — match directly by Session.id.
                    Expect.all
                        [ \mm -> PU.planRunningForSession mm "s1" |> Expect.equal True
                        , \mm -> PU.planRunningForSession mm "other" |> Expect.equal False
                        ]
                        m
            , test "Completed/NotStarted/Stopped plan → False (input enabled again)" <|
                \_ ->
                    let
                        meta =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = "completed"
                            , parentPlanId = Nothing
                            }

                        baseRun =
                            PT.emptyRunState "r1" plan

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planWindows =
                                    Dict.insert "p1"
                                        { planWindowWithPlan | run = Just { baseRun | status = PT.Completed } }
                                        Dict.empty
                            }
                    in
                    PU.planRunningForSession m "s1"
                        |> Expect.equal False
            , test "plan of ANOTHER session → False" <|
                \_ ->
                    let
                        meta =
                            { origin = { sessionId = "s2", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "x"
                            , lastStatus = "running"
                            , parentPlanId = Nothing
                            }

                        baseRun =
                            PT.emptyRunState "r1" plan

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planWindows =
                                    Dict.insert "p1"
                                        { planWindowWithPlan | run = Just { baseRun | status = PT.InProgress } }
                                        Dict.empty
                            }
                    in
                    PU.planRunningForSession m "s1"
                        |> Expect.equal False
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
                        [ -- C2b-7: node forks no longer register lineage
                          -- (sessionLineage removed). Assert via the node
                          -- binding staying + the node reset.
                        \m ->
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
                        -- (C3: uniformly marked by Session.id, not forkId)
                        , \m ->
                            Expect.equal ( m.planCascadeFork, Set.member "s1" m.planReplaySessions )
                                ( Nothing, True )
                        ]
                        m1
            , test "a plain (top-level) fork registers NO lineage; replay mark on the Session.id (C2b)" <|
                \_ ->
                    -- C2b (§8.1): a top-level re-run fork writes NO
                    -- lineage — Session.id is stable, and the fork session
                    -- is just a work copy of the same Session (the mapping
                    -- is written to sessionWorkCopies by
                    -- forkSessionCreated). This asserts the
                    -- registerForkInstance part: lineage does not grow, the
                    -- fork marker is cleared, and the replay-suppression
                    -- mark is on the Session.id.
                    let
                        target =
                            { childPlanId = "p1"
                            , summary = "new"
                            , planId = ""
                            , nodeId = ""
                            , forkSource = "s1"
                            , originSessionId = ""
                            }

                        cascade =
                            { rootPlanId = "p1"
                            , rootOldSummary = "old"
                            , levels = []
                            , phase = PC.WaitingFork
                            , currentPlanId = "p1"
                            , currentSummary = "new"
                            }

                        m0 =
                            { initModelWithSession
                                | planCascade = Just cascade
                                , planCascadeFork = Just target
                            }

                        ( m1, _ ) =
                            PU.cascadeStepIn stubDispatch (PC.InstanceReady (Ok "fork-x")) m0
                    in
                    Expect.all
                        [ -- C2b-7: lineage fields removed; a top-level fork
                          -- only clears the markers + replay mark.
                        \mm -> Expect.equal mm.planCascadeFork Nothing
                        , \mm -> Expect.equal (Set.member "s1" mm.planReplaySessions) True
                        ]
                        m1
            , test "fork with NO fork point → error, cascade ends, session untouched, no feedback (no fallback)" <|
                \_ ->
                    -- Regression (user bug): the pre-fix code "truncated in
                    -- memory" when the fork could not be issued (plan JSON
                    -- message without a history id). That truncation was
                    -- NOT written to session.alaya — after a restart the
                    -- old history resurrected and the result appeared at
                    -- the END of the conversation, past later plans. The
                    -- fix: surface a cascade error instead, truncate
                    -- nothing, insert nothing.
                    let
                        meta =
                            { origin = { sessionId = "s1", planIndex = 1 }
                            , feedbacks = []
                            , depth = 1
                            , createdAt = 0
                            , name = "p1"
                            , lastStatus = ""
                            , parentPlanId = Nothing
                            }

                        cascade =
                            { rootPlanId = "p1"
                            , rootOldSummary = ""
                            , levels = []
                            , phase = PC.WaitingPlan
                            , currentPlanId = "p1"
                            , currentSummary = ""
                            }

                        -- The plan JSON message carries NO history id (a
                        -- core that does not emit one) → forkHistoryId is
                        -- Nothing → the fork cannot be issued.
                        sessionMsgs =
                            [ planMessage "hi"
                            , planMessage fencedPlan
                            ]

                        session0 =
                            T.emptySession "s1"

                        sessionWithMsgs =
                            { session0 | messages = sessionMsgs }

                        m0 =
                            { initModelWithSession
                                | sessions =
                                    Dict.insert "s1" sessionWithMsgs initModelWithSession.sessions
                                , planMetas = Dict.insert "p1" meta Dict.empty
                                , planWindows = Dict.insert "p1" planWindowWithPlan Dict.empty
                                , planCascade = Just cascade
                            }

                        ( m1, _ ) =
                            PU.cascadeStepIn stubDispatch (PC.PlanCompleted "p1" "new") m0
                    in
                    Expect.all
                        [ \mm ->
                            -- the cascade ended with a recorded error
                            Expect.equal
                                ( mm.planCascade, mm.planCascadeError )
                                ( Nothing
                                , Just "Cannot insert the plan result: no fork point (the plan message carries no history id)."
                                )
                        , \mm ->
                            -- the origin conversation is untouched (no
                            -- in-memory truncation)
                            case Dict.get "s1" mm.sessions of
                                Just s ->
                                    Expect.equal
                                        (List.map .content s.messages)
                                        [ "hi", fencedPlan ]

                                Nothing ->
                                    Expect.fail "session s1 missing"
                        , \mm ->
                            -- the plan window carries the error banner
                            case Dict.get "p1" mm.planWindows |> Maybe.map (.view >> .errors) of
                                Just errs ->
                                    Expect.equal errs
                                        [ "Cannot insert the plan result: no fork point (the plan message carries no history id)." ]

                                Nothing ->
                                    Expect.fail "plan window p1 missing"
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
