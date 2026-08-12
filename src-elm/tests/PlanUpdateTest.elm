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
                    -- resume 后窗口 key 仍是 Session.id（"s1"），工作副本是 live1
                    -- （sessionWorkCopies[s1] = live1）。绑定按 Session.id 直接匹配
                    -- meta origin——不再需要 planResumedFrom 解析。
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
                    -- 重跑 fork 后窗口 key 仍是 Session.id（plan origin "s1"），
                    -- 工作副本换为 s-fork（sessionWorkCopies[s1] = s-fork）。
                    -- 绑定直接命中 meta origin——不再需要血缘 registry；工作副本
                    -- core id（"s-fork"）本身不再绑定任何 plan。
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
                            }
                    in
                    -- C2b-7：无血缘——节点按会话 id 直接绑定；绑定的
                    -- id（conv-1）找到 plan；无关 id 不解析。
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
        , describe "resolveEventSessionId"
            [ test "resumed live ids resolve through planResumedFrom THEN the registry" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planResumedFrom = Dict.fromList [ ( "live-2", "orig-1" ) ]
                            }
                    in
                    -- C2b-7：无血缘——resume live 只经 planResumedFrom 回到
                    -- 原目录 id；未知 id 回退自身。
                    Expect.all
                        [ \_ -> PU.resolveEventSessionId m0 "live-2" |> Expect.equal "orig-1"
                        , \_ -> PU.resolveEventSessionId m0 "orig-1" |> Expect.equal "orig-1"
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
                    -- resume 后窗口 key 仍是 Session.id（"s1"）；工作副本 live-s1
                    -- 只是边界细节。版本查询直接按 Session.id。
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
                    -- 用户重跑 fork 后查看的窗口 key = Session.id（plan origin
                    -- "s1"），工作副本是 s-fork（sessionWorkCopies[s1] = s-fork）。
                    -- 状态栏按 Session.id 直接命中 meta origin——不再需要
                    -- planResumedFrom → 血缘 registry 的解析链。
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
                    -- C2b-7：无血缘——按 Session.id 直接匹配。
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
                        [ -- C2b-7：节点 fork 不再注册血缘（sessionLineage 已删）。
                        -- 断言由节点绑定保持 + 节点重置即可。
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
                        , \m ->
                            Expect.equal ( m.planCascadeFork, Set.member "fork-x" m.planReplaySessions )
                                ( Nothing, True )
                        ]
                        m1
            , test "a plain (top-level) fork registers NO lineage; replay mark on the Session.id (C2b)" <|
                \_ ->
                    -- C2b（§8.1）：顶层重跑 fork 不写血缘——Session.id 稳定，
                    -- fork 会话只是同一 Session 的工作副本（映射由
                    -- forkSessionCreated 写入 sessionWorkCopies）。这里断言
                    -- registerForkInstance 部分：lineage 不增长、fork 标记
                    -- 清空、重放抑制标记在 Session.id 上。
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
                        [ -- C2b-7：血缘字段已删；顶层 fork 只清标记 + 重放标记。
                        \mm -> Expect.equal mm.planCascadeFork Nothing
                        , \mm -> Expect.equal (Set.member "s1" mm.planReplaySessions) True
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
