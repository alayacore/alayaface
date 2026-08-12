module Plan.Update exposing
    ( Dispatch
    , sessionsDir
    , planDirIn
    , planDirOf
    , planFilePathOf
    , planOriginSessionDir
    , sessionDirForCreate
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
    , resolveEventSessionId
    , planMetaForMessage
    , planRunningForSession
    , eventSessionId
    , planSystemPrompt
    , runStepIn
    , startRunIn
    , feedbackCompletedPlan
    , appendMetaFeedback
    , persistRunStatus
    , restartPlanCascade
    , openNextOrStart
    , cascadeStepIn
    , nodeSessionIdsForPlan
    , collectCloseSetFromSession
    , collectCloseSetFromPlan
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
    , runSummaryForPlan
    , freezeSessionVersion
    , versionPlanStatus
    , workCopyId
    , sessionIdOfWorkCopy
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
import App.Windows exposing (addPlanWindow, chainPayload, setPlanWin)
import App.NodeConnection as NC
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Process
import Set exposing (Set)
import Task
import Time
import Session.Types as T
import Session.Meta as SM
import Session.Protocol as P
import Plan.Types as PT
import Plan.Runner as R
import Plan.Meta as PM
import Plan.Cascade as PC
import Plan.Detect
import Plan.Frames
import Ports
import Arch.Values as AV
import Arch.Freeze as Freeze


{-| The main message dispatcher (App/Update.update), injected so plan
logic stays pure and testable.
-}
type alias Dispatch =
    Msg -> Model -> ( Model, Cmd Msg )


sessionsDir : String -> String
sessionsDir home =
    home ++ "/.alayaface/sessions"


-- The plan's directory: under its owning session's REAL on-disk dir
-- (sessions/<id> for a top-level session, the nested node-session dir
-- for a plan child — P28: top level is never a plan child), followed by
-- plans/<planId>. `sessionDirs` maps every known session id → its
-- on-disk dir (recorded at creation, rebuilt by the meta scan). Unknown
-- ids fall back to the top-level path (pre-P39 data / in-flight
-- creates). Passing the id alone and joining sessions/<id> was the P28
-- bug: a plan child (node session) leaked its plans/ to the sessions/
-- top level.
planDirIn : String -> Dict String String -> String -> String -> String
planDirIn home sessionDirMap originSessionId planId =
    let
        originDir =
            Dict.get originSessionId sessionDirMap
                |> Maybe.withDefault (sessionsDir home ++ "/" ++ originSessionId)
    in
    originDir ++ "/plans/" ++ planId


{-| The plan's on-disk directory, resolved from the planMetas index: the
origin session's ON-DISK id (resumes get fresh live ids whose dir does
not exist — the plan must live under the original dir id, which is what
PlanSaveReady records), resolved to its REAL directory via sessionDirs.
-}
planDirOf : Model -> String -> Maybe String
planDirOf model planId =
    case Dict.get planId model.planMetas of
        Just meta ->
            Just (planDirIn model.homeDir model.sessionDirMap meta.origin.sessionId planId)

        Nothing ->
            Nothing


{-| The plan's JSON file path (<planDir>/<planId>.json).
-}
planFilePathOf : Model -> String -> Maybe String
planFilePathOf model planId =
    Maybe.map (\d -> d ++ "/" ++ planId ++ ".json") (planDirOf model planId)


{-| The owning session's ON-DISK DIRECTORY for a plan (meta origin id,
resolved through sessionDirs). Plan node sessions are created/resumed
NESTED under this dir — passing the DIRECTORY (not just the id) keeps
nested node sessions (plan children) inside their real subtree instead
of leaking to the sessions/ top level (P28 layout bug).
-}
planOriginSessionDir : Model -> String -> Maybe String
planOriginSessionDir model planId =
    Dict.get planId model.planMetas
        |> Maybe.andThen
            (\meta ->
                Dict.get meta.origin.sessionId model.sessionDirMap
                    |> Maybe.withDefault (sessionsDir model.homeDir ++ "/" ++ meta.origin.sessionId)
                    |> Just
            )


{-| The on-disk directory of a session being created: top-level
sessions/<id> for plain sessions; the NESTED node-session dir
<originDir>/plans/<planId>/<nodeId>/<id> for plan children (P28 layout —
children never leak to the sessions/ top level). Mirrors the backend's
dirs.CreatePlanSessionDirFrom. Recorded in sessionDirMap at
SessionCreated.
-}
sessionDirForCreate : Model -> String -> String
sessionDirForCreate model id =
    case model.planCreating of
        Just (RunnerCreate planId nodeId) ->
            case planOriginSessionDir model planId of
                Just originDir ->
                    originDir ++ "/plans/" ++ planId ++ "/" ++ nodeId ++ "/" ++ id

                Nothing ->
                    sessionsDir model.homeDir ++ "/" ++ id

        _ ->
            sessionsDir model.homeDir ++ "/" ++ id


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
                            , Ports.setConnectionChain (chainPayload m3 m3.connectionChain)
                            ]
                        )

                    else
                        ( m2, Ports.setConnectionChain (chainPayload m2 m2.connectionChain) )

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

The match itself lives in Plan.Meta.planMetaForSessionIndex — the same
rule the status bar uses. C2b (§8.1, I-F): `sid` is the stable
Session.id (windows and frames are keyed by it; work copies are a
boundary detail), so the match is a direct `origin.sessionId == sid` —
no lineage registry, no resume map. A fork's replayed message and a
resumed window pass the same Session.id, so they bind to the same plan
without any resolution step.
-}
messageBoundToPlan : Model -> String -> Int -> Bool
messageBoundToPlan model sid planIndex =
    PM.planMetaForSessionIndex model.planMetas sid planIndex /= Nothing


{-| The plan whose meta binds (sessionId, planIndex) — the status-bar
lookup for a plan message (the render-only counterpart of
`messageBoundToPlan`, sharing the same rule). C2b: `sid` is the stable
Session.id, matched directly against the meta origin — no lineage
registry, no resume map (fork/resume windows keep their Session.id).
Kept here (not in the View) so the binding rule is one source of truth
and the fork/resume scenarios are unit-testable.
-}
planMetaForMessage : Model -> String -> Int -> Maybe ( String, PM.PlanMeta )
planMetaForMessage model sid planIndex =
    PM.planMetaForSessionIndex model.planMetas sid planIndex


{-| Whether a plan whose origin CONVERSATION is the given session is
currently RUNNING (InProgress). While a plan executes, the session's
input is disabled: the plan's result replaces everything after its plan
JSON, so a user message sent mid-run would be truncated away by the
completion (and would corrupt the "plan is the last meaningful message"
invariant the creation anchor relies on). Resolves resumed/forked
instances to the conversation.
-}
planRunningForSession : Model -> String -> Bool
planRunningForSession model sid =
    let
        convId =
            resolveEventSessionId model sid
    in
    Dict.foldl
        (\pid meta acc ->
            acc
                || (meta.origin.sessionId == convId
                        && (Dict.get pid model.planWindows
                                |> Maybe.andThen .run
                                |> Maybe.map (\r -> r.status == PT.InProgress)
                                |> Maybe.withDefault False
                           )
                   )
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


{-| Resolve an event-carrying session id to the CONVERSATION id the
runner matches nodes on: a fresh live id from resume_session maps back
to its original on-disk dir id (planResumedFrom), then through the
session lineage registry (P39/Phase B — a fork instance routes to the
conversation its node is bound to; for root sessions the conversation
id IS the instance id, so pre-fork behavior is unchanged). Every
session-bearing event must be resolved through this before reaching the
runner — a raw live id would silently miss the node binding (e.g.
closing a resumed node session would leave its node stuck Running).
-}
resolveEventSessionId : Model -> String -> String
resolveEventSessionId model sid =
    let
        origId =
            Dict.get sid model.planResumedFrom |> Maybe.withDefault sid
    in
    SM.resolveConversation model.sessionLineage origId


{-| Find the plan window whose run owns the given session id. A resumed
session id (fresh UUID) is resolved back to its original on-disk dir id
via planResumedFrom; the id is then resolved through the session
lineage registry to its CONVERSATION id (P39/Phase B — a fork instance
routes to the conversation its node is bound to; for root sessions the
conversation id IS the instance id, so pre-fork behavior is unchanged).
-}
findPlanIdBySession : Model -> String -> Maybe String
findPlanIdBySession model sid =
    let
        convId =
            resolveEventSessionId model sid
    in
    Dict.foldl
        (\pid win acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    case win.run of
                        Just run ->
                            if R.nodeBySessionId convId run == Nothing then
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
                        -- P39/Phase C: an ACTIVE cascade routes the
                        -- completion through the state machine
                        -- (cascadeOnPlanCompleted → PlanCompleted event);
                        -- a plain completion uses feedbackCompletedPlan.
                        ( model3, feedbackCmds ) =
                            if run.status /= PT.Completed && run2.status == PT.Completed then
                                let
                                    ( mF, cF ) =
                                        cascadeOnPlanCompleted dispatch planId now model2
                                in
                                ( mF
                                , if mF.planCascadeFork == Nothing then
                                    -- D11: no fork pending — close the
                                    -- window right after the feedback is
                                    -- queued (Failed/Stopped windows stay
                                    -- for review/retry).
                                    Cmd.batch
                                        [ cF
                                        , Task.perform (\_ -> PlanClose planId) Time.now
                                        ]

                                  else
                                    -- P38: the fork adoption closes the
                                    -- window once the fork took over —
                                    -- keep the plan visible while the
                                    -- fork is being created, so the
                                    -- completion isn't followed by an
                                    -- abrupt close + background streaming.
                                    cF
                                )

                            else
                                ( model2, Cmd.none )

                        -- P39/Phase C: post-step cascade machine events
                        -- (a resumed node's TaskDone → NodeSucceeded /
                        -- LevelFailed → branch re-run or end).
                        ( model4, cascadeCmds ) =
                            cascadeAfterRunnerStep dispatch planId ev run2 model3
                    in
                    ( model4, Cmd.batch [ cmds, feedbackCmds, metaCmd, cascadeCmds ] )

                Nothing ->
                    ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


{-| Initialize the run state for a fresh run of the given plan window
(fresh RunState on first run; a re-run keeps the existing state — its
node statuses are reset by StartRun). Shared by the manual Run button
and the sub-plan auto-run. P37: concurrency is NOT user-configurable —
every run uses `defaultConcurrency` (8); the future dynamic path will
compute it from system load here.
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
                            { baseRun | concurrency = PT.defaultConcurrency }

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


{-| P38: after the confirmation, ancestors whose windows auto-closed on
completion (D11) are REOPENED from disk (their runs are needed to resume
nodes and capture old summaries). Open the next queued ancestor, or —
once the queue drains — build the cascade state and start the root run.
Called right after a confirm and after every fs read that finished the
open/restore flow (planReadTarget cleared).
-}
openNextOrStart : Model -> ( Model, Cmd Msg )
openNextOrStart model =
    case model.planCascadeOpenQueue of
        next :: rest ->
            case planFilePathOf model next of
                Just path ->
                    let
                        ( m1, c1 ) =
                            openPlanFile path { model | planCascadeOpenQueue = rest }
                    in
                    ( m1, c1 )

                Nothing ->
                    -- no readable path: skip and keep draining
                    openNextOrStart { model | planCascadeOpenQueue = rest }

        [] ->
            startCascadeNow model


{-| All ancestors are open: build the execution state from the confirmed
scope (old summaries captured BEFORE the root run resets outputs), arm
the cascade and fire the root's Run. Failure to build (a level without a
runnable node) aborts the cascade silently.
-}
startCascadeNow : Model -> ( Model, Cmd Msg )
startCascadeNow model =
    case model.planCascadePreview of
        Just scope ->
            let
                runs =
                    Dict.map (\_ w -> w.run) model.planWindows
            in
            case PC.buildCascadeState scope runs of
                Just cs ->
                    ( { model | planCascadePreview = Nothing, planCascade = Just cs }
                    , Task.perform (\t -> PlanRunStartAt (Time.posixToMillis t)) Time.now
                    )

                Nothing ->
                    ( { model | planCascadePreview = Nothing }, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


{-| R3: a plan just completed — send the results summary back to the
session that auto-created it (auto-continue, D6) and record the
feedback in meta.json. If the origin session is a plan NODE's session
(recursion), also resume the node (WaitingForPlan → Running via
ResumeDelegatedNode) so the model can answer based on the results.
Plans inside a truncated region (planSuppressFeedback) never feed back.

P39/Phase C: this is the PLAIN (non-cascade) completion path. When the
plan is part of an ACTIVE cascade, `cascadeOnPlanCompleted` feeds
PlanCompleted to the state machine, which owns the gate / truncate /
fork / resume decisions (feedbackCompletedPlan is not used for those).
-}
feedbackCompletedPlan : String -> Int -> Model -> ( Model, Cmd Msg )
feedbackCompletedPlan planId now model =
    if Set.member planId model.planSuppressFeedback then
        -- P38: a plan living inside a truncated region: its completion
        -- must not insert anything into the rewound conversation.
        ( { model | planCascade = Nothing }, Cmd.none )

    else
        case Dict.get planId model.planMetas of
            Just meta ->
                let
                    -- P39/Phase B: the result lives in the conversation's
                    -- HEAD physical instance (a fork replaced the
                    -- creation session; the registry resolves it).
                    headSid =
                        SM.headInstanceFor model.sessionLineage meta.origin.sessionId
                            |> Maybe.withDefault meta.origin.sessionId

                    liveOrigin =
                        NC.liveSessionForOrigin model.sessions model.planResumedFrom headSid

                    summary =
                        summaryOf planId model

                    prefix =
                        PC.insertPrefix planId summary

                    feedbackCmd =
                        case liveOrigin of
                            Just liveSid ->
                                Ports.sendPrompt { sessionId = liveSid, text = prefix, media = [] }

                            Nothing ->
                                Cmd.none

                    -- If the origin is a plan node session, resume the
                    -- waiting node so it answers based on the results.
                    -- Only when the feedback prompt was ACTUALLY delivered
                    -- (the origin session is open): with a closed origin
                    -- no continuation prompt can arrive, so marking the
                    -- node Running would leave it stuck in Running
                    -- forever. A closed origin keeps the node
                    -- WaitingForPlan — the run stays InProgress and the
                    -- user can reopen the node session / re-run the
                    -- sub-plan to recover.
                    resumeCmd =
                        case liveOrigin of
                            Just _ ->
                                case findPlanIdBySession model headSid of
                                    Just _ ->
                                        Task.perform
                                            (\t -> PlanRunFrame (Time.posixToMillis t) (R.ResumeDelegatedNode headSid))
                                            Time.now

                                    Nothing ->
                                        Cmd.none

                            Nothing ->
                                Cmd.none

                    fb =
                        PM.Feedback now "completed" prefix planId

                    ( m1, metaCmd ) =
                        appendMetaFeedback planId fb model

                    -- C 架构：plan 完成 → 把**当前工作副本会话**（结果
                    -- 插入的那个）固化为不可变版本（planViews[planId] =
                    -- 新 run；其他 plan 按当前状态固化）。重跑路径下
                    -- 工作副本是 fork 出的新会话（其版本 = 重跑后世界），
                    -- 而重跑前的会话在确认时已固化（V0，plan 保持旧状态）。
                    -- 只对顶层会话固化（节点会话的版本化在 C3）。
                    ( m2, freezeCmd ) =
                        case liveOrigin of
                            Just liveSid ->
                                let
                                    originDiskId =
                                        onDiskSessionId model liveSid
                                in
                                if findPlanIdBySession model originDiskId == Nothing then
                                    freezeSessionVersion m1 originDiskId (Just planId)

                                else
                                    ( m1, Cmd.none )

                            Nothing ->
                                ( m1, Cmd.none )
                in
                ( m2, Cmd.batch [ feedbackCmd, resumeCmd, metaCmd, freezeCmd ] )

            Nothing ->
                ( model, Cmd.none )


-- ─── C 架构：版本固化（docs/arch-persistent.md §4.2）──────────────

{-| 把 plan 的当前运行状态固化为不可变 RunSummary（版本化状态的最小
信息：状态栏 / plan 概览）。优先 live window 的 run；窗口关闭（plan
完成自动关）时回退到内存缓存 planRunStatuses / meta.lastStatus——已
执行的 plan 在窗口关闭后仍必须记录为已执行（否则固化时被当成未执行）。
-}
runSummaryForPlan : Model -> String -> Maybe AV.RunSummary
runSummaryForPlan model planId =
    case Dict.get planId model.planWindows of
        Just win ->
            case win.run of
                Just run ->
                    Just
                        { runId = run.runId
                        , status = PT.runStatusToString run.status
                        , startedAt = Maybe.withDefault 0 run.startedAt
                        , finishedAt = run.finishedAt
                        , summary = PC.feedbackSummary run
                        }

                Nothing ->
                    persistedRunSummary model planId

        Nothing ->
            persistedRunSummary model planId


{-| 窗口关闭后的 run 摘要回退：从内存缓存 planRunStatuses（最新）或
meta.lastStatus（持久化快照）构建；summary 取 meta 最后一条 feedback。
-}
persistedRunSummary : Model -> String -> Maybe AV.RunSummary
persistedRunSummary model planId =
    let
        statusStr =
            case Dict.get planId model.planRunStatuses of
                Just st ->
                    Just (PT.runStatusToString st)

                Nothing ->
                    Dict.get planId model.planMetas
                        |> Maybe.andThen (\meta -> PT.runStatusFromString meta.lastStatus)
                        |> Maybe.map PT.runStatusToString

        summary =
            Dict.get planId model.planMetas
                |> Maybe.map PM.lastFeedbackText
                |> Maybe.withDefault ""
    in
    case statusStr of
        Just st ->
            Just
                { runId = planId
                , status = st
                , startedAt = 0
                , finishedAt = Nothing
                , summary = summary
                }

        Nothing ->
            Nothing


{-| C2b（§8.1）：Session.id → 当前工作副本（alayacore 会话 id）。
无映射（root 会话的工作副本 = 自身）→ 返回自身。UI 命令
（sendPrompt / cancel / close 等）用它发到正确的 alayacore 会话。
-}
workCopyId : Model -> String -> String
workCopyId model sessionId =
    Dict.get sessionId model.sessionWorkCopies |> Maybe.withDefault sessionId


{-| C2b（§8.1）：alayacore 工作副本 id → Session.id（稳定身份）。
反查 sessionWorkCopies；无映射 → 自身（root）。入站帧用它路由到
会话条目。
-}
sessionIdOfWorkCopy : Model -> String -> String
sessionIdOfWorkCopy model coreId =
    Dict.foldl
        (\sid core acc ->
            if core == coreId then
                sid

            else
                acc
        )
        coreId
        model.sessionWorkCopies


{-| C 架构：从会话版本（该会话 head 的 planViews）解析 plan 的显示
状态——同一 plan 在不同版本里状态不同（老会话看到旧状态）。返回
run status 字符串（PT.runStatusToString 形式）；Nothing = 该会话尚
无版本记录（回退现有全局状态逻辑）。C2b：`sid` 是稳定的 Session.id
（窗口/帧按它路由），直接查 refs——不再经 planResumedFrom。
-}
versionPlanStatus : Model -> String -> String -> Maybe String
versionPlanStatus model sid planId =
    case Dict.get sid model.sessionRefs of
        Just refs ->
            case Dict.get refs.head model.versionCache of
                Just version ->
                    case Dict.get planId version.planViews of
                        Just maybeRun ->
                            case maybeRun of
                                Just runHash ->
                                    case Dict.get runHash model.runSummaries of
                                        Just run ->
                                            Just run.status

                                        Nothing ->
                                            Nothing

                                Nothing ->
                                    Just "not-started"

                        Nothing ->
                            Nothing

                Nothing ->
                    Nothing

        Nothing ->
            Nothing


{-| 固化指定会话的当前版本：消息切块 + 该会话所有 plan 的状态
（有 run → RunSummary；未执行 → Nothing）→ 新 Version（parent = 旧
head）→ 激活固化（或入队）。
-}
freezeSessionVersion : Model -> String -> Maybe String -> ( Model, Cmd Msg )
freezeSessionVersion model sessionId runPlanId =
    let
        messages =
            Dict.get sessionId model.sessions
                |> Maybe.map .messages
                |> Maybe.withDefault []

        -- 该会话拥有的 plan（C：id 稳定，直接按 meta origin 匹配）
        ownedPids =
            Dict.foldl
                (\pid meta acc ->
                    if meta.origin.sessionId == sessionId then
                        pid :: acc

                    else
                        acc
                )
                []
                model.planMetas

        -- 本次完成的 plan 强制记录为已执行（即使窗口已关）
        otherPids =
            List.filter
                (\pid -> Just pid /= runPlanId)
                ownedPids

        runs =
            List.filterMap
                (\pid -> Maybe.map (\r -> ( pid, r )) (runSummaryForPlan model pid))
                otherPids
                ++ (case runPlanId of
                        Just pid ->
                            case runSummaryForPlan model pid of
                                Just r ->
                                    [ ( pid, r ) ]

                                Nothing ->
                                    []

                        Nothing ->
                            []
                   )

        unexecuted =
            List.filter
                (\pid -> Just pid /= runPlanId && runSummaryForPlan model pid == Nothing)
                ownedPids

        parent =
            Dict.get sessionId model.sessionRefs
                |> Maybe.map .head

        st =
            Freeze.begin sessionId messages runs unexecuted parent
    in
    case model.freezeActive of
        Just _ ->
            -- 串行固化：已有固化在进行，本固化入队（reqId 只在活动项
            -- 上有意义，覆盖会导致结果错配）。
            ( { model | freezeQueue = model.freezeQueue ++ [ st ] }, Cmd.none )

        Nothing ->
            let
                putCmds =
                    Freeze.initialPuts st
                        |> List.map
                            (\( reqId, content ) ->
                                Ports.objectPut { reqId = String.fromInt reqId, content = content }
                            )
            in
            ( { model | freezeActive = Just st }, Cmd.batch putCmds )


-- ─── Cascade state-machine wiring (P39/Phase C) ────────────────────

{-| Feed a machine event and execute its effects against the model.
Ends the cascade when the machine reaches Done. No-op when no cascade
is armed.
-}
cascadeStepIn : Dispatch -> PC.Event -> Model -> ( Model, Cmd Msg )
cascadeStepIn dispatch ev model =
    case model.planCascade of
        Nothing ->
            ( model, Cmd.none )

        Just cs ->
            let
                ( cs2, effects ) =
                    PC.cascadeStep ev cs

                m1 =
                    { model
                        | planCascade =
                            if cs2.phase == PC.Done then
                                Nothing

                            else
                                Just cs2
                    }
            in
            applyCascadeEffects dispatch m1 effects


{-| A plan just completed while a cascade is armed: record the feedback
and feed PlanCompleted (with the current summary) to the machine — the
gate (summary unchanged → silently end) and the fork/insert decision
live in the machine. Plain (non-cascade) completions go through
`feedbackCompletedPlan`.
-}
cascadeOnPlanCompleted : Dispatch -> String -> Int -> Model -> ( Model, Cmd Msg )
cascadeOnPlanCompleted dispatch planId now model =
    case model.planCascade of
        Nothing ->
            feedbackCompletedPlan planId now model

        Just _ ->
            let
                summary =
                    summaryOf planId model

                fb =
                    PM.Feedback now "completed" (PC.insertPrefix planId summary) planId

                ( m1, metaCmd ) =
                    appendMetaFeedback planId fb model

                ( m2, c2 ) =
                    cascadeStepIn dispatch (PC.PlanCompleted planId summary) m1
            in
            -- C 架构：cascade（重跑）路径**不在这里固化**——本事件先于
            -- fork（结果插入新工作副本），此时固化会捕获"重跑前世界"
            -- 并覆盖确认时固化的 V0。重跑后的版本固化在 C2b（工作副本
            -- 归属重构后，fork 会话 = 同一 Session 的 head）完成。
            ( m2, Cmd.batch [ metaCmd, c2 ] )


{-| Execute the machine's effects against the model (each effect is
translated with the Model the executor owns).
-}
applyCascadeEffects : Dispatch -> Model -> List PC.Effect -> ( Model, Cmd Msg )
applyCascadeEffects dispatch model effects =
    List.foldl (applyCascadeEffect dispatch) ( model, Cmd.none ) effects


applyCascadeEffect : Dispatch -> PC.Effect -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
applyCascadeEffect dispatch e ( m, cmds ) =
    case e of
        PC.ForkInstance planId ->
            let
                ( m1, c1 ) =
                    forkOrInsertInPlace dispatch planId m
            in
            ( m1, Cmd.batch [ cmds, c1 ] )

        PC.InsertResult planId instanceId summary ->
            ( m
            , Cmd.batch
                [ cmds
                , Ports.sendPrompt { sessionId = instanceId, text = PC.insertPrefix planId summary, media = [] }
                ]
            )

        PC.ResumeNode planId nodeId convId ->
            let
                m1 =
                    resetNodeForResume planId nodeId convId m

                c1 =
                    Task.perform
                        (\t -> PlanRunFrame (Time.posixToMillis t) (R.ResumeDelegatedNode convId))
                        Time.now
            in
            ( m1, Cmd.batch [ cmds, c1 ] )

        PC.BranchRerun planId nodeId ->
            let
                ( m1, c1 ) =
                    runStepIn dispatch planId 0 (R.ResumeBranchFrom nodeId) m
            in
            ( m1, Cmd.batch [ cmds, c1 ] )

        PC.RegisterFork forkId ->
            let
                ( m1, c1 ) =
                    registerForkInstance dispatch forkId m
            in
            ( m1, Cmd.batch [ cmds, c1 ] )

        PC.OpenAncestor planId ->
            case planFilePathOf m planId of
                Just path ->
                    let
                        ( m1, c1 ) =
                            openPlanFile path m
                    in
                    ( m1, Cmd.batch [ cmds, c1 ] )

                Nothing ->
                    ( m, cmds )


{-| ForkInstance effect: fork the plan's parent conversation at the
message before its old [Plan Result] (the fork really truncates on
disk), or — when there is no fork point (first run / predecessor
without a history id) — truncate in memory and feed InsertInPlace to
the machine so it inserts into the head instance directly.
-}
forkOrInsertInPlace : Dispatch -> String -> Model -> ( Model, Cmd Msg )
forkOrInsertInPlace dispatch planId model =
    case Dict.get planId model.planMetas of
        Just meta ->
            let
                headSid =
                    SM.headInstanceFor model.sessionLineage meta.origin.sessionId
                        |> Maybe.withDefault meta.origin.sessionId

                liveOrigin =
                    NC.liveSessionForOrigin model.sessions model.planResumedFrom headSid

                summary =
                    summaryOf planId model
            in
            case forkRequestFor planId liveOrigin summary model of
                Just ( target, args ) ->
                    ( { model | planCascadeFork = Just target }
                    , Ports.cascadeForkSession args
                    )

                Nothing ->
                    let
                        mTrunc =
                            truncateOrigin planId model

                        ( m1, c1 ) =
                            cascadeStepIn dispatch (PC.InsertInPlace headSid) mTrunc
                    in
                    ( m1, c1 )

        Nothing ->
            ( model, Cmd.none )


{-| RegisterFork effect: the fork is a new PHYSICAL instance of the same
conversation — register its lineage (memory + session.meta.json), close
the original head instance (safe — the machine already reset the node,
so its disconnect finds no Running node), mark the fork as replay and
close the (deferred-D11) child plan window. The InsertResult / ResumeNode
effects are issued separately by the machine.
-}
registerForkInstance : Dispatch -> String -> Model -> ( Model, Cmd Msg )
registerForkInstance dispatch forkId model =
    case model.planCascadeFork of
        Nothing ->
            ( model, Cmd.none )

        Just target ->
            let
                convId =
                    resolveEventSessionId model target.forkSource

                -- The lineage parent must be the ON-DISK instance id: a
                -- resumed fork source carries its FRESH live id (which
                -- has no meta file and no registry entry), while the
                -- chain is keyed by on-disk ids. A live id whose resume
                -- map points at the real instance resolves back to it.
                parentInstanceId =
                    Dict.get target.forkSource model.planResumedFrom
                        |> Maybe.withDefault target.forkSource

                lineageMeta =
                    { conversationId = convId
                    , parentInstanceId = Just parentInstanceId
                    }

                mLineage =
                    { model
                        | sessionLineage = Dict.insert forkId lineageMeta model.sessionLineage
                    }

                lineageCmd =
                    Ports.fsWriteFileText
                        { path = forkMetaPath model.homeDir target forkId
                        , content = E.encode 2 (SM.encode lineageMeta)
                        , createParents = True
                        }

                ( m1, closeCmd ) =
                    if target.forkSource == "" then
                        ( mLineage, Cmd.none )

                    else
                        dispatch (CloseSession target.forkSource) mLineage

                m2 =
                    { m1
                        | planCascadeFork = Nothing
                        -- The fork replays its (truncated) history: mark
                        -- it so plan messages inside are not auto-created.
                        , planReplaySessions = Set.insert forkId m1.planReplaySessions
                    }

                -- The deferred D11 close: the child plan window stays
                -- open during the fork wait; close it now that the fork
                -- took over.
                closePlanCmd =
                    Task.perform (\_ -> PlanClose target.childPlanId) Time.now
            in
            ( m2, Cmd.batch [ lineageCmd, closeCmd, closePlanCmd ] )


{-| The fork's session.meta.json path: a plan-node fork lives nested
under <originSessionDir>/plans/<planId>/<nodeId>/<forkId>/, a plain fork
at sessions/<forkId>/ — matching where the backend created the fork.
originSessionId now carries the origin's REAL directory (P28 fix).
-}
forkMetaPath : String -> PC.CascadeForkTarget -> String -> String
forkMetaPath homeDir target forkId =
    if target.planId == "" then
        sessionsDir homeDir ++ "/" ++ forkId ++ "/session.meta.json"

    else
        target.originSessionId
            ++ "/plans/"
            ++ target.planId
            ++ "/"
            ++ target.nodeId
            ++ "/"
            ++ forkId
            ++ "/session.meta.json"


{-| Reset a delegated node Succeeded → WaitingForPlan and restore its
conversation binding (closeAndClear dropped it on completion) so
ResumeDelegatedNode / TaskDone routing find it again (ResumeNode
effect).
-}
resetNodeForResume : String -> String -> String -> Model -> Model
resetNodeForResume planId nodeId convId model =
    case Dict.get planId model.planWindows of
        Just win ->
            case win.run of
                Just run ->
                    let
                        nodes =
                            Dict.update nodeId
                                (Maybe.map
                                    (\n ->
                                        if n.status == PT.Succeeded then
                                            { n | status = PT.WaitingForPlan, conversationId = Just convId }

                                        else
                                            n
                                    )
                                )
                                run.nodes
                    in
                    setPlanWin planId
                        (\w -> { w | run = Just { run | nodes = nodes, status = PT.InProgress } })
                        model

                Nothing ->
                    model

        Nothing ->
            model


{-| Args for the cascade fork port (mirrors Ports.cascadeForkSession).
-}
type alias CascadeForkArgs =
    { sourceSessionId : String
    , historyId : String
    , toolConfirm : String
    , preset : String
    , builtinTools : Maybe String
    , systemPrompt : String
    , workDir : String
    , planId : String
    , nodeId : String
    , originSessionId : String
    }


{-| Whether to truncate the parent session via a FORK, and with which
args. Only when the live origin session exists and has a fork point (the
history id of the message before the plan's old insertion). The fork
replaces the delegated ancestor node (root → head level, head → next
level; none → plain origin), so it carries the node's preset / tools /
plan system prompt and lands in the plan's nested node-session dir.
-}
forkRequestFor : String -> Maybe String -> String -> Model -> Maybe ( PC.CascadeForkTarget, CascadeForkArgs )
forkRequestFor planId liveOrigin summary model =
    case liveOrigin of
        Nothing ->
            Nothing

        Just liveSid ->
            case Dict.get liveSid model.sessions of
                Just s ->
                    -- P39/D8: the fork point is the plan's CREATION
                    -- anchor (its plan JSON's history id) — the fork
                    -- keeps the plan JSON and everything before it and
                    -- drops what follows.
                    let
                        planIndex =
                            Dict.get planId model.planMetas
                                |> Maybe.map (.origin >> .planIndex)
                                |> Maybe.withDefault 0
                    in
                    case PC.forkHistoryId planIndex s.messages of
                        Nothing ->
                            Nothing

                        Just historyId ->
                            let
                                ( levelPlanId, levelNodeId ) =
                                    forkLevelFor planId model

                                plainArgs =
                                    { sourceSessionId = liveSid
                                    , historyId = historyId
                                    , toolConfirm = ""
                                    , preset = ""
                                    , builtinTools = Nothing
                                    , systemPrompt = ""
                                    , workDir = ""
                                    , planId = ""
                                    , nodeId = ""
                                    , originSessionId = ""
                                    }
                            in
                            if levelPlanId == "" then
                                Just
                                    ( { childPlanId = planId
                                      , summary = summary
                                      , planId = ""
                                      , nodeId = ""
                                      , forkSource = liveSid
                                      , originSessionId = ""
                                      }
                                    , plainArgs
                                    )

                            else
                                let
                                    args =
                                        nodeSessionArgsIn levelPlanId levelNodeId model
                                in
                                Just
                                    ( { childPlanId = planId
                                      , summary = summary
                                      , planId = levelPlanId
                                      , nodeId = levelNodeId
                                      , forkSource = liveSid
                                      , originSessionId = Maybe.withDefault "" args.originSessionId
                                      }
                                    , { sourceSessionId = liveSid
                                      , historyId = historyId
                                      , toolConfirm = Maybe.withDefault "" args.toolConfirm
                                      , preset = Maybe.withDefault "" args.preset
                                      , builtinTools = args.builtinTools
                                      , systemPrompt = Maybe.withDefault "" args.systemPrompt
                                      , workDir = Maybe.withDefault "" args.workDir
                                      , planId = Maybe.withDefault "" args.planId
                                      , nodeId = Maybe.withDefault "" args.nodeId
                                      , originSessionId = Maybe.withDefault "" args.originSessionId
                                      }
                                    )

                Nothing ->
                    Nothing


{-| The ancestor level whose node the fork replaces: root completion →
head level; head completion → next level; none → the origin is a plain
session (plain fork).
-}
forkLevelFor : String -> Model -> ( String, String )
forkLevelFor planId model =
    case model.planCascade of
        Just cs ->
            let
                lvl =
                    if cs.rootPlanId == planId then
                        List.head cs.levels

                    else
                        List.head (List.drop 1 cs.levels)
            in
            case lvl of
                Just level ->
                    ( level.planId, level.nodeId )

                Nothing ->
                    ( "", "" )

        Nothing ->
            ( "", "" )


{-| The plan's current feedback summary (from its open run; "" when the
window/run is gone).
-}
summaryOf : String -> Model -> String
summaryOf planId model =
    Dict.get planId model.planWindows
        |> Maybe.andThen .run
        |> Maybe.map PC.feedbackSummary
        |> Maybe.withDefault ""


{-| P39/Phase C: post-step cascade machine events. A TaskDone from the
current head level's node decides the branch re-run (NodeSucceeded →
BranchRerun) or the cascade end (LevelFailed → Done). Everything else
is ignored by the machine.
-}
cascadeAfterRunnerStep : Dispatch -> String -> R.Event -> PT.RunState -> Model -> ( Model, Cmd Msg )
cascadeAfterRunnerStep dispatch planId ev run2 model =
    case ( ev, model.planCascade ) of
        ( R.TaskDone sid _ _ _, Just cs ) ->
            case List.head cs.levels of
                Just lvl ->
                    if lvl.planId == planId && lvl.conversationId == sid then
                        case Dict.get lvl.nodeId run2.nodes of
                            Just n ->
                                case n.status of
                                    PT.Succeeded ->
                                        cascadeStepIn dispatch (PC.NodeSucceeded planId lvl.nodeId) model

                                    PT.Failed ->
                                        cascadeStepIn dispatch (PC.LevelFailed planId lvl.nodeId) model

                                    _ ->
                                        ( model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


{-| Truncate the plan's origin session at its anchor — the plan's
CREATION point (right after its plan JSON): a plan's result replaces
what follows its plan, never appended past later plans. Resolves the
live session id (resumed sessions differ from the on-disk origin id).
P39/Phase B: the truncation target is the conversation's HEAD physical
instance (a fork replaced the creation session). No-op when the origin
is closed or has no anchor.
-}
truncateOrigin : String -> Model -> Model
truncateOrigin planId model =
    case Dict.get planId model.planMetas of
        Just meta ->
            let
                headSid =
                    SM.headInstanceFor model.sessionLineage meta.origin.sessionId
                        |> Maybe.withDefault meta.origin.sessionId
            in
            case NC.liveSessionForOrigin model.sessions model.planResumedFrom headSid of
                Just liveSid ->
                    case Dict.get liveSid model.sessions of
                        Just s ->
                            case PC.anchorIndexFor meta.origin.planIndex s.messages of
                                Just idx ->
                                    { model
                                        | sessions =
                                            Dict.insert liveSid
                                                { s | messages = PC.truncateMessagesAt idx s.messages }
                                                model.sessions
                                    }

                                Nothing ->
                                    model

                        Nothing ->
                            model

                Nothing ->
                    model

        Nothing ->
            model


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
                            -- Only WaitingForPlan nodes bind a delegated
                            -- sub-plan's session; filterMap drops nodes
                            -- without a conversation binding (no "" sentinel
                            -- that could false-match an empty origin id).
                            Dict.foldl
                                (\_ n acc ->
                                    if n.status == PT.WaitingForPlan then
                                        Maybe.map (\sid -> sid :: acc) n.conversationId
                                            |> Maybe.withDefault acc

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


{-| Every LIVE session window bound to a node of this plan: direct
bindings (`planNodeSessions` sid → "planId/nodeId") plus resumed
windows (`planResumedFrom` live → orig, orig bound to the plan). Only
sessions with an open window are returned — a closed binding's backend
handle is already gone (resume replaced it), so closing it again would
only produce "Session not found" noise. Node sessions can be open under
ANY run status — e.g. a node session resumed from disk under a
Stopped/FailedRun/Completed plan for review — so PlanClose closes them
regardless of the run state.
-}
nodeSessionIdsForPlan : String -> Model -> List String
nodeSessionIdsForPlan planId model =
    let
        isNodeOfPlan label =
            String.startsWith (planId ++ "/") label

        live sid =
            Dict.member sid model.sessions

        direct =
            Dict.foldl
                (\sid label acc ->
                    if isNodeOfPlan label && live sid then
                        sid :: acc
                    else
                        acc
                )
                []
                model.planNodeSessions

        viaResume =
            Dict.foldl
                (\liveId orig acc ->
                    case Dict.get orig model.planNodeSessions of
                        Just label ->
                            if isNodeOfPlan label && live liveId then
                                liveId :: acc
                            else
                                acc

                        Nothing ->
                            acc
                )
                []
                model.planResumedFrom
    in
    List.foldl
        (\sid acc ->
            if List.member sid acc then
                acc

            else
                sid :: acc
        )
        direct
        viaResume


-- ─── Ownership-graph close set (P39/D1) ────────────────────────────

{-| Collect every plan and session that must close when the given
SESSION closes — the ownership graph in ONE traversal (P34/D1):
session → its plans (meta origin) → their node sessions → their
sub-plans → …, visited-deduplicated and cycle-safe. Returns
( plans, sessions ) in discovery order.
-}
collectCloseSetFromSession : Model -> String -> ( List String, List String )
collectCloseSetFromSession model sid =
    collectCloseSetHelp model
        [ sid ]
        (Set.singleton sid)
        Set.empty
        []


{-| Same collection starting from a PLAN (its node sessions, their
sub-plans, …). The plan itself is included in the plans list.
-}
collectCloseSetFromPlan : Model -> String -> ( List String, List String )
collectCloseSetFromPlan model planId =
    collectCloseSetHelp model
        []
        Set.empty
        (Set.singleton planId)
        [ planId ]
        |> (\( plans, sessions ) -> ( List.reverse plans, List.reverse sessions ))


collectCloseSetHelp :
    Model
    -> List String
    -> Set String
    -> Set String
    -> List String
    -> ( List String, List String )
collectCloseSetHelp model sessionQueue visitedSessions visitedPlans planQueue =
    case sessionQueue of
        s :: rest ->
            let
                disk =
                    Dict.get s model.planResumedFrom |> Maybe.withDefault s

                plans =
                    PM.plansOwnedBySession model.planMetas disk
                        |> List.filter (\p -> not (Set.member p visitedPlans))

                visitedPlans2 =
                    Set.union visitedPlans (Set.fromList plans)

                planQueue2 =
                    planQueue ++ plans
            in
            collectCloseSetHelp model rest visitedSessions visitedPlans2 planQueue2

        [] ->
            case planQueue of
                p :: rest ->
                    let
                        nodeSids =
                            nodeSessionIdsForPlan p model
                                |> List.filter (\s -> not (Set.member s visitedSessions))

                        visitedSessions2 =
                            Set.union visitedSessions (Set.fromList nodeSids)

                        sessionQueue2 =
                            nodeSids
                    in
                    collectCloseSetHelp model sessionQueue2 visitedSessions2 visitedPlans rest

                [] ->
                    ( Set.toList visitedPlans, Set.toList visitedSessions )


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
    , originSessionId = planOriginSessionDir model planId
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
                -- P39/Phase B: frames carry the PHYSICAL instance id;
                -- the runner matches nodes by CONVERSATION id, so
                -- resolve through the lineage registry first (root
                -- sessions: identity). The resolution MUST go through
                -- planResumedFrom like findPlanIdBySession does: a
                -- RESUMED node session streams frames under its fresh
                -- live id, and the node binding is the original
                -- conversation id — resolving the raw id alone would
                -- produce a TaskDone/SessionError the runner cannot
                -- match (node stuck Running forever).
                let
                    convId =
                        resolveEventSessionId model ev.sessionId
                in
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
                                                , Just (R.TaskDone convId err (lastAssistantOutput model ev.sessionId) (lastAssistantIsPlan model ev.sessionId))
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
                                        ( model, Just (R.SessionError convId text) )

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

