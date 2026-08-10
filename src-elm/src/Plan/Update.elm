module Plan.Update exposing
    ( Dispatch
    , sessionsDir
    , planDirIn
    , planDirOf
    , planFilePathOf
    , planOriginSessionId
    , runStatesOf
    , onDiskSessionId
    , planDirEntryDecoder
    , fsOkDecoder
    , fsReadOkDecoder
    , fsListDirTaggedDecoder
    , fsReadTaggedDecoder
    , nextFsReq
    , handlePlanReadTarget
    , openPlanFile
    , setPlanErrors
    , messageBoundToPlan
    , planIndexForMessage
    , becamePlanMessage
    , planCountOf
    , bumpPlanCount
    , findPlanMessageRaw
    , injectPlanErrorIntoSession
    , findResumedLive
    , planWinKeyForPath
    , findPlanIdBySession
    , eventSessionId
    , planSystemPrompt
    , runStepIn
    , startRunIn
    , feedbackCompletedPlan
    , feedbackSummary
    , appendMetaFeedback
    , persistRunStatus
    , restartPlanCascade
    , subPlansOfPlan
    , runDiffLog
    , applyEffectsIn
    , applyEffectIn
    , startNextCreateIn
    , nodeSessionArgsIn
    , planWorkDir
    , persistRunIn
    , runPathFor
    , isSessionReady
    , planEventFromFrame
    , lastAssistantOutput
    , lastAssistantIsPlan
    )

{-| Plan Mode update logic (M2): auto-create / feedback / restart
cascade / meta scan / status bar / runner wiring. Pure functions in the
same style as Plan/Runner.elm — directly unit-testable. Extracted from
App/Update.elm (D2); App/Update.elm keeps the message dispatch and
delegates here. Types live in App.Types / Plan.Types.

The main dispatcher (App/Update.update) is injected as `Dispatch` where
an effect must route back through it (e.g. CloseSessionFor → CloseSession
runs the full session lifecycle + cascade close). This keeps the module
cycle-free and the functions pure: a test passes a stub dispatcher.
-}

import App.Types exposing (..)
import App.Windows exposing (addPlanWindow, setPlanWin)
import App.NodeConnection as NC
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Process
import Task
import Time
import Session.Types as T
import Session.Protocol as P
import Plan.Types as PT
import Plan.Runner as R
import Plan.Meta as PM
import Plan.Detect
import Plan.Frames
import Ports


{-| The main message dispatcher (App/Update.update), injected so plan
logic stays pure and testable.
-}
type alias Dispatch =
    Msg -> Model -> ( Model, Cmd Msg )


sessionsDir : String -> String
sessionsDir home =
    home ++ "/.alayaface/sessions"


-- The plan's directory under its owning session:
-- sessions/<originSessionId>/plans/<planId>
planDirIn : String -> String -> String -> String
planDirIn home originSessionId planId =
    sessionsDir home ++ "/" ++ originSessionId ++ "/plans/" ++ planId


{-| The plan's on-disk directory, resolved from the planMetas index: the
origin session's ON-DISK id (resumes get fresh live ids whose dir does
not exist — the plan must live under the original dir id, which is what
PlanSaveReady records).
-}
planDirOf : Model -> String -> Maybe String
planDirOf model planId =
    case Dict.get planId model.planMetas of
        Just meta ->
            Just (planDirIn model.homeDir meta.origin.sessionId planId)

        Nothing ->
            Nothing


{-| The plan's JSON file path (<planDir>/<planId>.json).
-}
planFilePathOf : Model -> String -> Maybe String
planFilePathOf model planId =
    Maybe.map (\d -> d ++ "/" ++ planId ++ ".json") (planDirOf model planId)


{-| The owning session's ON-DISK id for a plan (meta origin). Plan node
sessions are created/resumed nested under this session's dir.
-}
planOriginSessionId : Model -> String -> Maybe String
planOriginSessionId model planId =
    Dict.get planId model.planMetas
        |> Maybe.map (.origin >> .sessionId)


{-| Every open plan's run-state nodes, keyed by planId (empty dict for
windows without a run). Feed to the pure depth helpers in Plan.Meta —
the run state records which sessions belong to which plan's nodes.
-}
runStatesOf : Model -> Dict String (Dict String PT.NodeRunState)
runStatesOf model =
    Dict.map
        (\_ win -> win.run |> Maybe.map .nodes |> Maybe.withDefault Dict.empty)
        model.planWindows


{-| The on-disk session id for a LIVE session id: resumes hand out FRESH
ids whose own dir does not exist — map back through planResumedFrom.
-}
onDiskSessionId : Model -> String -> String
onDiskSessionId model sid =
    Dict.get sid model.planResumedFrom |> Maybe.withDefault sid


planDirEntryDecoder : D.Decoder { name : String, isDir : Bool }
planDirEntryDecoder =
    D.map2 (\n d -> { name = n, isDir = d })
        (D.field "name" D.string)
        (D.field "isDir" D.bool)


fsOkDecoder : D.Decoder { ok : Bool, error : String }
fsOkDecoder =
    D.map2 (\ok err -> { ok = ok, error = err })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


fsReadOkDecoder : D.Decoder { ok : Bool, content : String, error : String }
fsReadOkDecoder =
    D.map3 (\ok content err -> { ok = ok, content = content, error = err })
        (D.field "ok" D.bool)
        (D.field "content" D.string)
        (D.field "error" D.string)


{-| Decoder for the tagged fs_list_dir response: { reqId, ok, entries, error }.
-}
fsListDirTaggedDecoder : D.Decoder { reqId : String, ok : Bool, entries : List D.Value, error : String }
fsListDirTaggedDecoder =
    D.map4 (\reqId ok entries err -> { reqId = reqId, ok = ok, entries = entries, error = err })
        (D.field "reqId" D.string)
        (D.field "ok" D.bool)
        (D.field "entries" (D.list D.value))
        (D.field "error" D.string)


{-| Decoder for the tagged fs_read_file_text response: { reqId, ok, content, error }.
-}
fsReadTaggedDecoder : D.Decoder { reqId : String, ok : Bool, content : String, error : String }
fsReadTaggedDecoder =
    D.map4 (\reqId ok content err -> { reqId = reqId, ok = ok, content = content, error = err })
        (D.field "reqId" D.string)
        (D.field "ok" D.bool)
        (D.field "content" D.string)
        (D.field "error" D.string)


{-| Allocate the next fs request id. Only fsListDir and fsReadFileText
carry one — the two ports shared by the plan-meta scan and the normal
UI flows. The id is echoed in the response so routing is decided by
match, never by global state flags.
-}
nextFsReq : Model -> ( String, Model )
nextFsReq model =
    let
        n =
            model.fsReqCounter + 1
    in
    ( "fs-" ++ String.fromInt n, { model | fsReqCounter = n } )


{-| Handle a fs_read_file_text result that matched the plan read target:
open/import (isResume=False), Load run (isResume=True + continueRun=True)
or a silent best-effort run-state restore when a plan window opens
(isResume=True + continueRun=False). `ok/content/error` are the decoded
fields of the tagged response.
-}
handlePlanReadTarget : Dispatch -> Model -> PlanReadTarget -> Bool -> String -> String -> ( Model, Cmd Msg )
handlePlanReadTarget dispatch model target ok content error =
    if target.isResume then
        -- Read <plan>.run.json → restore run state in the target plan
        -- window (and optionally continue).
        if ok then
            let
                win0 =
                    Dict.get target.planId model.planWindows
                        |> Maybe.withDefault emptyPlanWindow
            in
            case ( D.decodeString PT.decodeRunStateOverlay content, win0.view.plan ) of
                ( Ok overlay, Just plan ) ->
                    if target.continueRun then
                        -- Load run: unfinished nodes re-run; restore then continue.
                        let
                            baseRun =
                                PT.applyRunStateOverlay overlay (PT.emptyRunState "resume" plan)

                            run =
                                R.resumeState baseRun

                            win1 =
                                { win0
                                    | run = Just run
                                    , runPath = Just target.path
                                    , resumePath = Nothing
                                    , selectedNode = Nothing
                                }

                            m1 =
                                { model
                                    | planReadTarget = Nothing
                                    , planWindows = Dict.insert target.planId win1 model.planWindows
                                }
                        in
                        runStepIn dispatch target.planId 0 R.ContinueRun m1

                    else
                        -- Silent restore: only when the window has no run
                        -- yet (a Run clicked in between must not be
                        -- overwritten).
                        if win0.run == Nothing then
                            let
                                run =
                                    PT.applyRunStateOverlay overlay (PT.emptyRunState "resume" plan)

                                win1 =
                                    { win0
                                        | run = Just run
                                        , runPath = Just target.path
                                        , resumePath = Nothing
                                        , selectedNode = Nothing
                                    }

                                m1 =
                                    { model
                                        | planReadTarget = Nothing
                                        , planWindows = Dict.insert target.planId win1 model.planWindows
                                    }
                            in
                            ( m1, Cmd.none )

                        else
                            ( { model | planReadTarget = Nothing }, Cmd.none )

                ( Ok _, Nothing ) ->
                    ( { model | planReadTarget = Nothing }, Cmd.none )

                ( Err err, _ ) ->
                    if target.continueRun then
                        ( { model
                            | planReadTarget = Nothing
                            , planWindows =
                                Dict.update target.planId
                                    (Maybe.map
                                        (\w ->
                                            let
                                                wv =
                                                    w.view
                                            in
                                            { w
                                                | resumePath = Nothing
                                                , view = { wv | errors = [ "Invalid run state: " ++ D.errorToString err ], saving = False }
                                            }
                                        )
                                    )
                                    model.planWindows
                          }
                        , Cmd.none
                        )

                    else
                        -- silent restore: ignore a corrupt run file
                        ( { model | planReadTarget = Nothing }, Cmd.none )

        else if target.continueRun then
            let
                win0 =
                    Dict.get target.planId model.planWindows
                        |> Maybe.withDefault emptyPlanWindow
            in
            ( { model
                | planReadTarget = Nothing
                , planWindows =
                    Dict.insert target.planId
                        { win0 | resumePath = Nothing }
                        model.planWindows
              }
            , Cmd.none
            )

        else
            -- no run file yet: nothing to restore
            ( { model | planReadTarget = Nothing }, Cmd.none )

    else
        -- Open/import: parse the plan file and open (or focus) its
        -- window; then best-effort restore the saved run state so
        -- node→session bindings come back.
        if ok then
            case PT.parsePlan content of
                Ok plan ->
                    let
                        win0 =
                            Dict.get target.planId model.planWindows
                                |> Maybe.withDefault emptyPlanWindow

                        wv =
                            win0.view

                        win1 =
                            { win0
                                | view =
                                    { wv
                                        | plan = Just plan
                                        , path = Just target.path
                                        , errors = []
                                        , saving = False
                                    }
                            }

                        m1 =
                            { model
                                | planReadTarget = Nothing
                            }

                        m2 =
                            addPlanWindow target.planId win1 m1
                    in
                    if win0.run == Nothing then
                        -- Fresh window: chain a silent read of
                        -- <plan>.run.json to restore statuses/bindings.
                        let
                            runPath =
                                runPathFor target.path

                            ( reqId2, m3 ) =
                                nextFsReq m2
                        in
                        ( { m3
                            | planReadTarget =
                                Just
                                    { reqId = reqId2
                                    , planId = target.planId
                                    , path = runPath
                                    , isResume = True
                                    , continueRun = False
                                    }
                          }
                        , Cmd.batch
                            [ Ports.fsReadFileText { reqId = reqId2, path = runPath }
                            , Ports.setConnectionChain m3.connectionChain
                            ]
                        )

                    else
                        ( m2, Ports.setConnectionChain m2.connectionChain )

                Err errs ->
                    -- Invalid plan file: surface the parse errors in the
                    -- plan window.
                    ( setPlanErrors errs { model | planReadTarget = Nothing }
                    , Cmd.none
                    )

        else
            ( setPlanErrors [ error ] { model | planReadTarget = Nothing }
            , Cmd.none
            )


-- Shared open: set the read target and read the plan file. Used by the
-- [Plan: …] status-bar link (path comes from planFilePathOf — plans
-- always live under their owning session).
openPlanFile : String -> Model -> ( Model, Cmd Msg )
openPlanFile path model =
    let
        ( reqId, m1 ) =
            nextFsReq model
    in
    ( { m1
        | planReadTarget =
            Just
                { reqId = reqId
                , planId = planWinKeyForPath path
                , path = path
                , isResume = False
                , continueRun = False
                }
      }
    , Ports.fsReadFileText { reqId = reqId, path = path }
    )


setPlanErrors : List String -> Model -> Model
setPlanErrors errs model =
    case model.planActiveId of
        Just pid ->
            setPlanWin pid
                (\w ->
                    let
                        wv =
                            w.view
                    in
                    { w | view = { wv | errors = errs, saving = False } }
                )
                model

        Nothing ->
            -- No plan window yet (e.g. validation failed right after an
            -- offer): show the errors in a fresh error-only window.
            addPlanWindow
                ("plan-error-" ++ String.fromInt (Dict.size model.planWindows))
                { emptyPlanWindow | view = { emptyPlanView | errors = errs } }
                model


{-| Whether some plan's meta origin binds the given plan message of the
given SESSION (planIndex = which plan message of that session, counted
with the same isPlanMessage predicate as the detector). Message ids are
deliberately NOT used: they are per-session implementation details that
may differ across cores/restores, while the order of plan messages is
stable. Replay guard: a replayed historical message must not create a
duplicate plan.
-}
messageBoundToPlan : Model -> String -> Int -> Bool
messageBoundToPlan model sid planIndex =
    let
        -- meta origin records the session's ON-DISK id; a resumed session
        -- renders with a fresh live id — resolve before comparing.
        onDiskId =
            Dict.get sid model.planResumedFrom |> Maybe.withDefault sid
    in
    Dict.foldl
        (\_ meta acc ->
            acc
                || (meta.origin.sessionId == onDiskId && meta.origin.planIndex == planIndex)
        )
        False
        model.planMetas


{-| The plan index of the LAST message of the list: how many plan
messages (detected with Plan.Detect.isPlanMessage) the session has up to
and including it. Called right after a plan message arrives, so it equals
that message's plan index; rendering uses the same predicate.
-}
planIndexForMessage : List T.Message -> Int
planIndexForMessage msgs =
    List.foldl
        (\m acc ->
            if Plan.Detect.isPlanMessage m.content then
                acc + 1

            else
                acc
        )
        0
        msgs


{-| True when the just-received content completes a plan message that
was NOT a plan message before — i.e. the message's accumulated content
(historyContents for its tag:historyId) just crossed the ```json fence
for the first time. Used to bump the incremental per-session plan
counter exactly once per plan message (M3/D4). `prevContent` is the
accumulated content BEFORE this delta/frame; `newContent` after.
-}
becamePlanMessage : String -> String -> Bool
becamePlanMessage prevContent newContent =
    not (Plan.Detect.isPlanMessage prevContent) && Plan.Detect.isPlanMessage newContent


{-| The incremental per-session plan-message count (M3/D4): O(1) read
replacing the O(n) `planIndexForMessage` scan in the per-frame AT path.
Semantics identical to planIndexForMessage — locked by tests
(replay/append/restore).
-}
planCountOf : Dict String Int -> String -> Int
planCountOf counts sid =
    Dict.get sid counts |> Maybe.withDefault 0


{-| Bump the per-session plan count when a message just became a plan
message (`becamePlanMessage`). O(1).
-}
bumpPlanCount : Dict String Int -> String -> Bool -> Dict String Int
bumpPlanCount counts sid becamePlan =
    if becamePlan then
        Dict.update sid (\c -> Just (Maybe.withDefault 0 c + 1)) counts

    else
        counts


{-| The raw plan JSON of the session's planIndex-th plan message (used
by the manual "Open plan" entry for suppressed auto-creates).
-}
findPlanMessageRaw : Model -> String -> Int -> Maybe String
findPlanMessageRaw model sid planIndex =
    case Dict.get sid model.sessions of
        Just s ->
            s.messages
                |> List.filter (\m -> Plan.Detect.isPlanMessage m.content)
                |> List.drop (max 0 (planIndex - 1))
                |> List.head
                |> Maybe.andThen (\m -> Plan.Detect.extractPlanJson m.content)

        Nothing ->
            Nothing


{-| R2: inject a visible error message into the given session (the plan
JSON message that failed to parse during auto-create). The user sees the
error inline next to the plan message instead of a broken window.
-}
injectPlanErrorIntoSession : List String -> String -> Model -> Model
injectPlanErrorIntoSession errs sid model =
    case Dict.get sid model.sessions of
        Just s ->
            let
                errMsg =
                    { id = "plan-error-" ++ sid ++ "-" ++ String.fromInt (List.length s.messages)
                    , role = T.Error
                    , content = "Plan parsing failed: " ++ String.join "; " errs
                    , toolId = Nothing
                    , toolName = Nothing
                    , isError = True
                    , historyId = Nothing
                    , media = Nothing
                    }
            in
            { model | sessions = Dict.insert sid { s | messages = s.messages ++ [ errMsg ] } model.sessions }

        Nothing ->
            model


{-| Accessor for the active plan window.
-}
findResumedLive : String -> Model -> Maybe String
findResumedLive origId model =
    Dict.foldl
        (\liveId mapped acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    if mapped == origId && Dict.member liveId model.sessions then
                        Just liveId

                    else
                        Nothing
        )
        Nothing
        model.planResumedFrom


{-| The pure inputs the chain builder needs, lifted from the model.
-}
planWinKeyForPath : String -> String
planWinKeyForPath path =
    let
        base =
            String.split "/" path
                |> List.reverse
                |> List.head
                |> Maybe.withDefault path
    in
    if String.endsWith ".json" base then
        String.dropRight 5 base

    else
        base


{-| Find the plan window whose run owns the given session id. A resumed
session id (fresh UUID) is resolved back to its original on-disk dir id
via planResumedFrom, so closing a resumed node session still attributes
the window to its plan node (runner disconnect handling).
-}
findPlanIdBySession : Model -> String -> Maybe String
findPlanIdBySession model sid =
    let
        origId =
            Dict.get sid model.planResumedFrom |> Maybe.withDefault sid
    in
    Dict.foldl
        (\pid win acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case win.run of
                        Just run ->
                            if R.nodeBySessionId origId run == Nothing then
                                Nothing

                            else
                                Just pid

                        Nothing ->
                            Nothing
        )
        Nothing
        model.planWindows


{-| The session id carried by a runner event, if any. Delegated to
Plan.Runner (pure + unit-tested) so a dropped-event regression like
ResumeDelegatedNode is caught by the test suite.
-}
eventSessionId : R.Event -> Maybe String
eventSessionId =
    R.eventSessionId
planSystemPrompt : String
planSystemPrompt =
    """You can use AlayaFace's plan mode: for complex or multi-step tasks, first output a plan so its subtasks run in parallel / by dependency, instead of doing everything yourself in one go.

When to output a plan:
- The task needs multiple steps, research/search across several areas, or a summarized report → output a plan;
- A simple task (doable in one sentence) → just do it directly, do not output a plan.

Plan format (output exactly one ```json code block, then stop and wait for the plan to finish executing):
{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "plan name",
  "goal": "goal description",
  "concurrency": 8,
  "default_max_attempts": 3,
  "tasks": [
    { "id": "t1", "title": "subtask title", "prompt": "complete, self-contained instruction", "depends_on": [], "preset": "Default", "max_attempts": 3 }
  ]
}
Rules:
- The top level MUST include "type": "alayaface-plan" (without it the framework will not recognize the plan)
- Field names must be spelled exactly as in the schema above (depends_on, concurrency, max_attempts, ...) — a misspelled or extra field makes the whole plan be rejected; do not invent fields
- ids are globally unique; prompts are self-contained by default; if a downstream task needs an upstream task's output, reference it in the prompt with {{t1.output}} (the framework replaces it with that upstream task's final output once it completes; you may only reference tasks already declared as dependencies — never reference tasks outside the dependency graph)
- Tasks that can run in parallel must not depend on each other
- By default, do NOT set a preset (absent = Default, which has a working model configured). Only set one if the user explicitly asks for a specific preset environment (Fast/Deep/Data/Safe, etc.) — those presets may have no model configured yet, and using one will make the task fail immediately
- For risky tasks involving commands, restrict the tool set with the tools field (e.g. read-only tools); the "Safe" preset disables execute_command but likewise needs a model configured beforehand
- Even if a task needs no decomposition (doable in one sentence), still output a plan (a single task is fine) — that is your output format
- After outputting the plan: stop, wait for the plan to finish and its result to come back, then continue your answer based on the result"""

{-| Run one state-machine step for a specific plan window, with a
timestamp, then dispatch effects. Appends a log line for every node
whose status changed (bounded).
-}
runStepIn : Dispatch -> String -> Int -> R.Event -> Model -> ( Model, Cmd Msg )
runStepIn dispatch planId now ev model =
    case Dict.get planId model.planWindows of
        Just win ->
            case win.run of
                Just run ->
                    let
                        ( run2, effects ) =
                            R.step now ev run

                        diff =
                            runDiffLog run run2

                        win2 =
                            { win | run = Just run2, runLog = List.take 80 (win.runLog ++ diff) }

                        -- Apply effects against the POST-step model: e.g.
                        -- SendPrompt resolves the node prompt through the
                        -- run that already contains the just-bound session
                        -- id (looking it up in the pre-step run would drop
                        -- the prompt, leaving node sessions empty).
                        model1 =
                            { model
                                | planWindows = Dict.insert planId win2 model.planWindows
                                , planRunStatuses = Dict.insert planId run2.status model.planRunStatuses
                            }

                        -- Persist the run status into meta.json whenever it
                        -- changes (NotStarted → Running → … → Completed /
                        -- Failed / Stopped). Reopened sessions then show the
                        -- last known status in the status bar instead of a
                        -- placeholder. Run-level status changes are rare (a
                        -- handful per run), so the write is cheap.
                        ( model1b, metaCmd ) =
                            if run2.status /= run.status then
                                persistRunStatus planId run2.status model1

                            else
                                ( model1, Cmd.none )

                        ( model2, cmds ) =
                            applyEffectsIn dispatch planId model1b effects

                        -- R3: when a run transitions INTO Completed, feed
                        -- the results back to the origin session (auto-
                        -- continue, D6). Failed/Stopped runs feed back
                        -- NOTHING (D8).
                        -- R4 (D11): a Completed plan window closes itself
                        -- right after the feedback is queued (Failed/
                        -- Stopped windows stay for review/retry).
                        ( model3, feedbackCmds ) =
                            if run.status /= PT.Completed && run2.status == PT.Completed then
                                let
                                    ( mF, cF ) =
                                        feedbackCompletedPlan planId now model2
                                in
                                ( mF
                                , Cmd.batch
                                    [ cF
                                    , Task.perform (\_ -> PlanClose planId) Time.now
                                    ]
                                )

                            else
                                ( model2, Cmd.none )
                    in
                    ( model3, Cmd.batch [ cmds, feedbackCmds, metaCmd ] )

                Nothing ->
                    ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


{-| Initialize the run state for a fresh run of the given plan window
(fresh RunState on first run; a re-run keeps the existing state — its
node statuses are reset by StartRun) and apply the header concurrency
override. Shared by the manual Run button and the sub-plan auto-run.
-}
startRunIn : String -> Int -> Model -> Model
startRunIn planId ts model =
    case Dict.get planId model.planWindows of
        Just win ->
            case win.view.plan of
                Just plan ->
                    let
                        baseRun =
                            Maybe.withDefault
                                (PT.emptyRunState (PT.slugify plan.name ++ "-" ++ String.fromInt ts) plan)
                                win.run

                        run =
                            case PT.parseConcurrency win.view.concurrencyInput of
                                Just c ->
                                    { baseRun | concurrency = c }

                                Nothing ->
                                    baseRun

                        win2 =
                            case win.run of
                                Just _ ->
                                    { win | run = Just run }

                                Nothing ->
                                    { win
                                        | run = Just run
                                        , runPath = Maybe.map runPathFor win.view.path
                                        , selectedNode = Nothing
                                        , runLog = []
                                    }
                    in
                    { model | planWindows = Dict.insert planId win2 model.planWindows }

                Nothing ->
                    model

        Nothing ->
            model


{-| R3: a plan just completed — send the results summary back to the
session that auto-created it (auto-continue, D6) and record the
feedback in meta.json. If the origin session is a plan NODE's session
(recursion), also resume the node (WaitingForPlan → Running via
ResumeDelegatedNode) so the model can answer based on the results.
-}
feedbackCompletedPlan : String -> Int -> Model -> ( Model, Cmd Msg )
feedbackCompletedPlan planId now model =
    case Dict.get planId model.planMetas of
        Just meta ->
            let
                origin =
                    meta.origin

                summary =
                    feedbackSummary planId model

                prefix =
                    "[Plan Result] The plan has completed. Results:\n\n"
                        ++ summary
                        ++ "\n\n[Plan: "
                        ++ planId
                        ++ "]"

                -- Origin session (ON-DISK id) alive → send the
                -- continuation prompt (auto-continue). Resolve to the
                -- LIVE window id (the original if open, or the fresh id
                -- of a resume of it). Closed → D7 (part): record the
                -- feedback for later display; the auto-resume+continue
                -- follow-up is pending.
                liveOrigin =
                    NC.liveSessionForOrigin model.sessions model.planResumedFrom origin.sessionId

                feedbackCmd =
                    case liveOrigin of
                        Just liveSid ->
                            Ports.sendPrompt { sessionId = liveSid, text = prefix, media = [] }

                        Nothing ->
                            Cmd.none

                -- If the origin is a plan node session, resume the
                -- waiting node so it answers based on the results. Only
                -- when the feedback prompt was ACTUALLY delivered (the
                -- origin session is open): with a closed origin no
                -- continuation prompt can arrive, so marking the node
                -- Running would leave it stuck in Running forever (no
                -- live session, no answer). A closed origin keeps the
                -- node WaitingForPlan — the run stays InProgress and the
                -- user can reopen the node session / re-run the sub-plan
                -- to recover.
                resumeCmd =
                    case liveOrigin of
                        Just _ ->
                            case findPlanIdBySession model origin.sessionId of
                                Just _ ->
                                    Task.perform
                                        (\t -> PlanRunFrame (Time.posixToMillis t) (R.ResumeDelegatedNode origin.sessionId))
                                        Time.now

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none

                fb =
                    PM.Feedback now "completed" prefix planId

                ( m1, metaCmd ) =
                    appendMetaFeedback planId fb model
            in
            ( m1, Cmd.batch [ feedbackCmd, resumeCmd, metaCmd ] )

        Nothing ->
            ( model, Cmd.none )


{-| Concatenate every succeeded node's recorded output into a readable
summary (P24 outputs are captured at TaskDone and persisted).
-}
feedbackSummary : String -> Model -> String
feedbackSummary planId model =
    case Dict.get planId model.planWindows of
        Just win ->
            case win.run of
                Just run ->
                    run.plan.tasks
                        |> List.filterMap
                            (\t ->
                                case Dict.get t.id run.nodes of
                                    Just n ->
                                        if n.status == PT.Succeeded then
                                            Maybe.map (\out -> "## " ++ t.id ++ " · " ++ t.title ++ "\n" ++ out) n.output

                                        else
                                            Nothing

                                    Nothing ->
                                        Nothing
                            )
                        |> String.join "\n\n"

                Nothing ->
                    ""

        Nothing ->
            ""


{-| Append a feedback entry to the plan's meta (in memory + persisted to
meta.json).
-}
appendMetaFeedback : String -> PM.Feedback -> Model -> ( Model, Cmd Msg )
appendMetaFeedback planId fb model =
    case Dict.get planId model.planMetas of
        Just meta ->
            case planDirOf model planId of
                Just planDir ->
                    let
                        newMeta =
                            { meta | feedbacks = meta.feedbacks ++ [ fb ] }

                        metaPath =
                            PM.metaPathFor planDir planId
                    in
                    ( { model | planMetas = Dict.insert planId newMeta model.planMetas }
                    , Ports.fsWriteFileText { path = metaPath, content = E.encode 2 (PM.encodeMeta newMeta), createParents = True }
                    )

                Nothing ->
                    ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


{-| Persist a plan's run status into its meta.json (in memory + disk).
Called from runStepIn whenever the run status changes; the status bar
reads `lastStatus` after a restart (planRunStatuses is in-memory only).
-}
persistRunStatus : String -> PT.RunStatus -> Model -> ( Model, Cmd Msg )
persistRunStatus planId st model =
    case Dict.get planId model.planMetas of
        Just meta ->
            case planDirOf model planId of
                Just planDir ->
                    let
                        newMeta =
                            { meta | lastStatus = PT.runStatusToString st }

                        metaPath =
                            PM.metaPathFor planDir planId
                    in
                    ( { model | planMetas = Dict.insert planId newMeta model.planMetas }
                    , Ports.fsWriteFileText { path = metaPath, content = E.encode 2 (PM.encodeMeta newMeta), createParents = True }
                    )

                Nothing ->
                    ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


{-| R4 (D9): restart a plan skipping succeeded nodes, cascading to the
sub-plans of delegated (WaitingForPlan) nodes — their planId is reused
(no regeneration), and after the sub-plan completes its feedback resumes
the parent node. Recursion depth is unbounded (D14, experience period).
-}
restartPlanCascade : Dispatch -> String -> Model -> ( Model, Cmd Msg )
restartPlanCascade dispatch planId model =
    let
        ( m1, c1 ) =
            runStepIn dispatch planId 0 R.RestartRun model

        subPlans =
            subPlansOfPlan planId m1

        ( m2, cmds ) =
            List.foldl
                (\spId ( m, c ) ->
                    let
                        ( m3, c3 ) =
                            restartPlanCascade dispatch spId m
                    in
                    ( m3, Cmd.batch [ c, c3 ] )
                )
                ( m1, Cmd.none )
                subPlans
    in
    ( m2, Cmd.batch [ c1, cmds ] )


{-| Sub-plans delegated by this plan's WaitingForPlan nodes (found via
meta origin.sessionId matching the node's session id).
-}
subPlansOfPlan : String -> Model -> List String
subPlansOfPlan planId model =
    let
        nodeSids =
            case Dict.get planId model.planWindows of
                Just win ->
                    case win.run of
                        Just run ->
                            Dict.foldl
                                (\_ n acc ->
                                    if n.status == PT.WaitingForPlan then
                                        Maybe.withDefault "" n.sessionId :: acc

                                    else
                                        acc
                                )
                                []
                                run.nodes

                        Nothing ->
                            []

                Nothing ->
                    []
    in
    Dict.foldl
        (\spId meta acc ->
            if List.member meta.origin.sessionId nodeSids then
                spId :: acc

            else
                acc
        )
        []
        model.planMetas


{-| One log line per node whose status changed between two snapshots.
-}
runDiffLog : PT.RunState -> PT.RunState -> List String
runDiffLog before after =
    Dict.foldl
        (\id n2 acc ->
            case Dict.get id before.nodes of
                Just n1 ->
                    if n1.status /= n2.status then
                        (id
                            ++ " ["
                            ++ String.fromInt n2.attempts
                            ++ " attempts] "
                            ++ PT.nodeStatusToString n1.status
                            ++ " → "
                            ++ PT.nodeStatusToString n2.status
                        )
                            :: acc

                    else
                        acc

                Nothing ->
                    acc
        )
        []
        after.nodes
        |> List.reverse


applyEffectsIn : Dispatch -> String -> Model -> List PT.Effect -> ( Model, Cmd Msg )
applyEffectsIn dispatch planId model effects =
    List.foldl (applyEffectIn dispatch planId) ( model, Cmd.none ) effects


applyEffectIn : Dispatch -> String -> PT.Effect -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
applyEffectIn dispatch planId e ( m, cmds ) =
    case e of
        PT.CreateSessionFor nodeId ->
            -- Serialized session creation: one in-flight create at a
            -- time (globally); SessionCreated binds it to the pending
            -- node via (planId, nodeId). User creates share the queue
            -- (tagged UserCreate) so they can never be misbound.
            if m.planCreating == Nothing then
                ( { m | planCreating = Just (RunnerCreate planId nodeId) }
                , Cmd.batch [ cmds, Ports.createSession (nodeSessionArgsIn planId nodeId m) ]
                )

            else
                ( { m | planCreateQueue = m.planCreateQueue ++ [ RunnerCreate planId nodeId ] }, cmds )

        PT.SendPrompt sid text ->
            -- The prompt text is carried by the effect (resolved by the
            -- runner from the plan at bind time), so there is nothing to
            -- re-resolve here.
            if text == "" then
                ( m, cmds )

            else
                ( m
                , Cmd.batch
                    [ cmds
                    , Ports.sendPrompt { sessionId = sid, text = text, media = [] }
                    ]
                )

        PT.CloseSessionFor sid _ ->
            -- The runner closed this node's session (Stop / failure /
            -- cancel): kill the process AND remove its window — the user
            -- clicked Stop and expects the session to be gone, not a
            -- stale dead window. History stays on disk (~/.alayaface/
            -- sessions/<sid>) and is restored on node click.
            let
                ( m2, c2 ) =
                    dispatch (CloseSession sid) m
            in
            ( m2, Cmd.batch [ cmds, c2 ] )

        PT.ScheduleRetry nodeId delayMs ->
            ( m
            , Cmd.batch
                [ cmds
                , Task.perform (\_ -> PlanRunnerTick planId nodeId) (Process.sleep (toFloat delayMs))
                ]
            )

        PT.PersistRunState ->
            ( m, Cmd.batch [ cmds, persistRunIn planId m ] )

        PT.Notify _ ->
            ( m, cmds )


{-| Kick off the next queued session creation (one in-flight at a time).
Handles both runner creates and user creates from the same queue.
-}
startNextCreateIn : Model -> ( Model, Cmd Msg )
startNextCreateIn model =
    case ( model.planCreating, model.planCreateQueue ) of
        ( Nothing, task :: rest ) ->
            let
                m1 =
                    { model | planCreating = Just task, planCreateQueue = rest }
            in
            case task of
                RunnerCreate planId nodeId ->
                    ( m1, Ports.createSession (nodeSessionArgsIn planId nodeId model) )

                UserCreate _ ->
                    -- Fixed plan mode (D2): every user session gets the
                    -- planner hint via --system — "complex tasks → output
                    -- a plan JSON first". No role lock; the model keeps
                    -- its tools and may still execute directly.
                    ( { m1 | pendingSwitchOnCreate = True }
                    , Ports.createSession
                        { toolConfirm = Nothing
                        , preset = Nothing
                        , builtinTools = Nothing
                        , systemPrompt = Just planSystemPrompt
                        , workDir = Nothing
                        , planId = Nothing
                        , nodeId = Nothing
                        , originSessionId = Nothing
                        }
                    )

        _ ->
            ( model, Cmd.none )


{-| Session-creation args for a runner node: toolConfirm=allow (auto-
approve tools so tasks don't stall) plus the node's preset/tools
overrides (Nothing = preset defaults / all tools). Node sessions carry
the plan system prompt ONLY while the plan is within the global
recursion limit (plan.depth ≤ recursion_limit, default 8): over the
limit the prompt is omitted so the model stops delegating — that is how
recursion is bounded. (This is the only gate; resume_session re-applies
the persisted spawn args, so the decision is made once at creation.)

NOTE: alayacore's --tool-confirm is a list of tool names that REQUIRE
confirmation; "allow" matches no real tool, so nothing is confirmed →
every tool auto-runs. That is exactly the runner's intent (unattended
execution), but it means a plan task CAN auto-run risky tools — use the
Safe preset / tools field to restrict per node.

planId/nodeId/originSessionId tag the session as a PLAN CHILD: the
backend stores its directory nested under
sessions/<originSessionId>/plans/<planId>/<nodeId>/ so the sessions/ top
level only ever contains plain (non-plan) sessions and every plan lives
inside the session that created it.
-}
nodeSessionArgsIn : String -> String -> Model -> { toolConfirm : Maybe String, preset : Maybe String, builtinTools : Maybe String, systemPrompt : Maybe String, workDir : Maybe String, planId : Maybe String, nodeId : Maybe String, originSessionId : Maybe String }
nodeSessionArgsIn planId nodeId model =
    let
        task =
            Dict.get planId model.planWindows
                |> Maybe.andThen .run
                |> Maybe.map .plan
                |> Maybe.map .tasks
                |> Maybe.withDefault []
                |> List.filter (\t -> t.id == nodeId)
                |> List.head

        depth =
            PM.depthOf model.planMetas planId

        systemPrompt =
            if PM.shouldInjectPlanPrompt depth model.globalConfig.recursionLimit then
                Just planSystemPrompt

            else
                Nothing
    in
    { toolConfirm = Just "allow"
    , preset = task |> Maybe.andThen .preset
    , builtinTools = task |> Maybe.andThen .tools
    , systemPrompt = systemPrompt
    , workDir = planWorkDir planId model
    , planId = Just planId
    , nodeId = Just nodeId
    , originSessionId = planOriginSessionId model planId
    }


{-| Per-plan working directory for node sessions: every node of a plan
shares sessions/<originSessionId>/plans/<planId>/work (created by the
backend on spawn), so tasks can exchange files within the plan while
plans stay isolated from each other and from the backend's cwd. Nothing
while the plan's origin is unknown (falls back to the backend cwd).
-}
planWorkDir : String -> Model -> Maybe String
planWorkDir planId model =
    case planDirOf model planId of
        Just dir ->
            Just (dir ++ "/work")

        Nothing ->
            Nothing


{-| Persist the current run state to <planId>.run.json.
-}
persistRunIn : String -> Model -> Cmd Msg
persistRunIn planId model =
    case Dict.get planId model.planWindows of
        Just win ->
            case ( win.run, win.runPath ) of
                ( Just run, Just path ) ->
                    Ports.fsWriteFileText
                        { path = path
                        , content = E.encode 2 (PT.encodeRunState run)
                        , createParents = True
                        }

                _ ->
                    Cmd.none

        Nothing ->
            Cmd.none


{-| Derive the run.json path from a plan file path (plan.json → plan.run.json).
-}
runPathFor : String -> String
runPathFor planPath =
    if String.endsWith ".json" planPath then
        String.dropRight 5 planPath ++ ".run.json"

    else
        planPath ++ ".run.json"


{-| Whether a frame is the core's explicit readiness signal:
`SM {"type":"session","data":{"state":"ready"}}` (alayacore v0.62.4+).
Emitted AFTER all replayed history content — the authoritative
"replay ended, session interactive" marker. The replay-suppression
marker (planReplaySessions) is removed on this frame.
-}
isSessionReady : P.FrameEvent -> Bool
isSessionReady ev =
    if ev.tag /= "SM" then
        False

    else
        case ev.json of
            Just json ->
                case D.decodeValue P.systemMsgDecoder json of
                    Ok env ->
                        env.msgType == "session"
                            && ((D.decodeValue (D.field "state" D.string) env.data
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""
                                )
                                    == "ready"
                               )

                    Err _ ->
                        False

            Nothing ->
                False


{-| Extract a runner event from a frame for a node-owned session:
SM task done (in_progress=false) or SM error.

R5 gate: alayacore emits a boot task frame (in_progress:false, context 0)
BEFORE any prompt is processed. Without a preceding in_progress:true that
boot frame is indistinguishable from a real task completion — the runner
would mark the just-bound node Succeeded (output Nothing) and closeAndClear
would CANCEL its just-started session ("Canceled" right after the first
prompt, node done in milliseconds). We therefore track sessions that have
seen in_progress:true (a real task start — always follows the prompt, which
is only sent after bind) and only dispatch TaskDone for those.
-}
planEventFromFrame : Model -> P.FrameEvent -> ( Model, Maybe R.Event )
planEventFromFrame model ev =
    if ev.tag /= "SM" then
        ( model, Nothing )

    else
        case findPlanIdBySession model ev.sessionId of
            Nothing ->
                ( model, Nothing )

            Just _ ->
                case ev.json of
                    Just json ->
                        case D.decodeValue P.systemMsgDecoder json of
                            Ok env ->
                                case env.msgType of
                                    "task" ->
                                        let
                                            inProgress =
                                                D.decodeValue (D.field "in_progress" D.bool) env.data
                                                    |> Result.toMaybe
                                                    |> Maybe.withDefault True

                                            taskError =
                                                D.decodeValue (D.field "task_error" D.bool) env.data
                                                    |> Result.toMaybe
                                                    |> Maybe.withDefault False

                                            ( started, maybeDone ) =
                                                Plan.Frames.taskEvent model.planTaskStarted ev.sessionId inProgress taskError
                                        in
                                        case maybeDone of
                                            Just ( sid, err ) ->
                                                ( { model | planTaskStarted = started }
                                                , Just (R.TaskDone sid err (lastAssistantOutput model ev.sessionId) (lastAssistantIsPlan model ev.sessionId))
                                                )

                                            Nothing ->
                                                ( { model | planTaskStarted = started }, Nothing )

                                    "error" ->
                                        let
                                            text =
                                                D.decodeValue (D.field "text" D.string) env.data
                                                    |> Result.toMaybe
                                                    |> Maybe.withDefault "Error"
                                        in
                                        ( model, Just (R.SessionError ev.sessionId text) )

                                    _ ->
                                        ( model, Nothing )

                            Err _ ->
                                ( model, Nothing )

                    Nothing ->
                        ( model, Nothing )


{-| The final assistant answer of a session — recorded as the node's
output when its task completes (used by {{<id>.output}} injection).
Frames arrive in order: the final AT text is handled before the SM
task-done frame that triggers this lookup, so the last Assistant
message here is the completed task's answer.
-}
lastAssistantOutput : Model -> String -> Maybe String
lastAssistantOutput model sid =
    case Dict.get sid model.sessions of
        Just s ->
            s.messages
                |> List.filter (\m -> m.role == T.Assistant)
                |> List.map .content
                |> List.filter (not << String.isEmpty)
                |> List.reverse
                |> List.head
                |> Maybe.map String.trim

        Nothing ->
            Nothing


{-| Whether the session's LAST assistant message contains a plan JSON
(with the alayaface-plan marker) — the recursion delegation judgment.
A node whose final answer is a plan document is NOT done: it waits for
the auto-created sub-plan's result to be fed back (R-series).
-}
lastAssistantIsPlan : Model -> String -> Bool
lastAssistantIsPlan model sid =
    case Dict.get sid model.sessions of
        Just s ->
            case
                s.messages
                    |> List.filter (\m -> m.role == T.Assistant)
                    |> List.map .content
                    |> List.filter (not << String.isEmpty)
                    |> List.reverse
                    |> List.head
            of
                Just content ->
                    case Plan.Detect.extractPlanJson content of
                        Just raw ->
                            Plan.Detect.hasPlanTypeMarker raw

                        Nothing ->
                            False

                Nothing ->
                    False

        Nothing ->
            False


-- UPDATE

