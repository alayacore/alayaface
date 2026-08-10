module PlanUpdateTest exposing (suite)

{-| Direct unit tests for Plan/Update (M2): the plan-mode update logic
extracted from App/Update.elm is exercised WITHOUT going through the
full App.Update.update dispatcher — a stub Dispatch is injected where
an effect must route back through the dispatcher (CloseSessionFor etc.).
These are the "direct tests" replacing the previous indirect coverage.
-}

import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import Dict
import App.Types as AT
import Plan.Update as PU
import Plan.Types as PT
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
                            , parentSessionId = Nothing
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
                            , parentSessionId = Nothing
                            }

                        m =
                            { initModelWithSession
                                | planMetas = Dict.insert "p1" meta Dict.empty
                                , planResumedFrom = Dict.insert "live1" "s1" Dict.empty
                            }
                    in
                    Expect.equal ( PU.messageBoundToPlan m "live1" 2 ) True
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
        ]
