module App.Update exposing
    ( update
    , SessionDir
    , decodeSessionDir
    , helpItems
    , nextCopyName
    , planSystemPrompt
    )

{-| Application update logic. Pure enough to reason about: transports
(DeltaEvent/FrameEvent/StatusEvent), session actions, window dragging,
and the preset/editor overlays. The types live in App.Types; Main only
forwards messages here.
-}

import Browser.Dom as Dom
import Dict exposing (Dict)
import Set exposing (Set)
import Json.Decode as D
import Json.Encode as E
import Process
import Task
import Time
import App.Types exposing (..)
import App.NodeConnection as NC
import App.SelectorKit as Kit
import Session.Types as T
import Session.Protocol as P
import Session.Handlers as H
import Session.Selector as Sel exposing (Page(..))
import Session.FilePicker as FP
import Plan.Types as PT
import Plan.Runner as R
import Plan.Meta as PM
import Plan.Detect
import Plan.Frames
import Overlay.HelpWindow exposing (HelpItem, filterHelpItems)
import Ports


-- Constants


defaultWinW : Int
defaultWinW = 560

defaultWinH : Int
defaultWinH = 640

-- Plan windows default larger (DAG canvas + header need room).
planDefaultWinW : Int
planDefaultWinW = 680

planDefaultWinH : Int
planDefaultWinH = 720

minWinW : Int
minWinW = 300

minWinH : Int
minWinH = 200

-- Helpers

updateSession : Model -> String -> (T.SessionState -> T.SessionState) -> Model
updateSession model sid fn =
    case Dict.get sid model.sessions of
        Just s ->
            { model | sessions = Dict.insert sid (fn s) model.sessions }

        Nothing ->
            model


updateActiveSession : Model -> (T.SessionState -> T.SessionState) -> Model
updateActiveSession model fn =
    case model.activeId of
        Just sid ->
            updateSession model sid fn

        Nothing ->
            model


focusInput : Model -> Cmd Msg
focusInput =
    Kit.focusPrompt


focusAfterDelay : String -> Cmd Msg
focusAfterDelay =
    Kit.focusAfterDelay


getActiveSession : Model -> Maybe T.SessionState
getActiveSession model =
    case model.activeId of
        Just sid ->
            Dict.get sid model.sessions

        Nothing ->
            Nothing


-- Buffer an inbound event for a session that has not been registered
-- yet (e.g. transport events racing session creation). The buffered
-- events are flushed when the session appears (see SessionCreated).
bufferPendingEvent : Model -> String -> E.Value -> ( Model, Cmd Msg )
bufferPendingEvent model sessionId raw =
    let
        existing =
            Dict.get sessionId model.pendingEvents |> Maybe.withDefault []
    in
    ( { model | pendingEvents = Dict.insert sessionId (existing ++ [ raw ]) model.pendingEvents }
    , Cmd.none
    )


-- PLAN MODE HELPERS

plansDir : String -> String
plansDir home =
    home ++ "/.alayaface/plans"


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


refreshPlanList : Model -> Cmd Msg
refreshPlanList model =
    if model.homeDir == "" then
        Ports.fsHomeDir {}

    else if model.planManager.tab == PlanTabBrowse then
        -- The Browse tab owns fs_list_dir while active; a stray plans-dir
        -- listing would land in its branch of FsListDirResult.
        Cmd.none

    else
        Ports.fsListDir { path = plansDir model.homeDir }


-- Initial file-browser state for the Plans manager Browse tab, rooted at
-- the user's home directory (mirrors the session file picker init).
initPlanBrowser : String -> T.FilePickerState
initPlanBrowser home =
    { show = True
    , mode = T.Local
    , input = home ++ "/"
    , filter = ""
    , entries = []
    , dir = home
    , baseDir = home
    , selected = 0
    , loading = True
    , error = Nothing
    , savedLocalPath = ""
    , savedUrlPath = ""
    , pendingFileName = ""
    }


-- Placeholder browser used before the home dir is known; FsHomeDirResult
-- fills it in (dir == "" marks "waiting for home dir").
emptyPlanBrowser : T.FilePickerState
emptyPlanBrowser =
    { show = True
    , mode = T.Local
    , input = ""
    , filter = ""
    , entries = []
    , dir = ""
    , baseDir = ""
    , selected = 0
    , loading = True
    , error = Nothing
    , savedLocalPath = ""
    , savedUrlPath = ""
    , pendingFileName = ""
    }


-- Shared open/import: set the read target and read the plan file. Used by
-- the Saved-tab Open button and the Browse-tab file picker.
openPlanFile : String -> Model -> ( Model, Cmd Msg )
openPlanFile path model =
    ( { model
        | planReadTarget =
            Just
                { planId = planWinKeyForPath path
                , path = path
                , isResume = False
                , continueRun = False
                }
      }
    , Ports.fsReadFileText { path = path }
    )


-- Click/Enter on a Browse-tab entry: directories navigate, files import.
-- maybeIdx = Just idx → clicked entry; Nothing → keyboard-selected entry.
planBrowserPick : Model -> Maybe Int -> ( Model, Cmd Msg )
planBrowserPick model maybeIdx =
    let
        pm =
            model.planManager
    in
    case pm.browser of
        Just fp ->
            let
                idx =
                    Maybe.withDefault fp.selected maybeIdx

                entries =
                    FP.filterEntries fp
            in
            case List.head (List.drop idx entries) of
                Just entry ->
                    if entry.isDir then
                        let
                            ( newFp, newDir ) =
                                FP.appendDirToInput fp entry.name

                            newFp2 =
                                { newFp | selected = idx }
                        in
                        ( { model | planManager = { pm | browser = Just newFp2 } }
                        , Ports.fsResolvePath { path = newDir }
                        )

                    else
                        let
                            fullPath =
                                if fp.dir == "" then
                                    entry.name
                                else
                                    fp.dir ++ "/" ++ entry.name
                        in
                        openPlanFile fullPath model

                Nothing ->
                    ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


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
    Dict.foldl
        (\_ meta acc ->
            acc
                || (case meta.origin of
                        Just o ->
                            o.sessionId == sid && o.planIndex == planIndex

                        Nothing ->
                            False
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


{-| Whether the session's LAST message is still the plan message with the
given plan index. Used by the delayed auto-open (PlanOfferSettle): a
history replay feeds plan frames one at a time, so "is it the last
message" can only be decided a moment later — if anything arrived after
it, the plan window must not auto-open.
-}
isPlanMessageStillLast : Model -> String -> Int -> Bool
isPlanMessageStillLast model sid planIndex =
    case Dict.get sid model.sessions of
        Just s ->
            case List.reverse s.messages of
                last :: _ ->
                    Plan.Detect.isPlanMessage last.content
                        && planIndexForMessage s.messages == planIndex

                [] ->
                    False

        Nothing ->
            False


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
getPlanWin : Model -> Maybe PlanWindow
getPlanWin model =
    model.planActiveId
        |> Maybe.andThen (\pid -> Dict.get pid model.planWindows)


{-| Update a specific plan window.
-}
setPlanWin : String -> (PlanWindow -> PlanWindow) -> Model -> Model
setPlanWin pid fn model =
    { model | planWindows = Dict.update pid (Maybe.map fn) model.planWindows }


{-| Update the active plan window.
-}
updateActivePlanWin : Model -> (PlanWindow -> PlanWindow) -> Model
updateActivePlanWin model fn =
    case model.planActiveId of
        Just pid ->
            setPlanWin pid fn model

        Nothing ->
            model


{-| Find a LIVE session that was resumed from the given on-disk dir id.
resume_session hands out a fresh id each time; this maps it back so a
node click can focus the already-open resumed window instead of either
resuming a second time ("Session is already active") or losing the
window. Returns Nothing when no live session was resumed from `origId`.
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


{-| Build the active node↔session connection for a session id. Nothing
for sessions not bound to a plan node (plain chats, unattached runner
sessions, …).
-}
connectionForSession : String -> Model -> Maybe NC.NodeConnection
connectionForSession sid model =
    NC.nodeConnectionFor model.planNodeSessions model.planResumedFrom sid


{-| Focus a session: raise it above everything else. If it belongs to a
plan node, also raise that plan window to the SECOND layer (directly
below the session) and tell bridge.js to draw the connection curve;
otherwise hide any curve.
-}
activateSessionModel : Model -> String -> ( Model, Cmd Msg )
activateSessionModel model id =
    case connectionForSession id model of
        Just conn ->
            let
                newPositions =
                    model.windowPositions
                        |> Dict.update id
                            (Maybe.map (\pos -> { pos | z = model.nextZIndex + 1 }))
                        |> Dict.update conn.planId
                            (Maybe.map (\pos -> { pos | z = model.nextZIndex }))
            in
            ( { model
                | activeId = Just id
                , windowPositions = newPositions
                , nextZIndex = model.nextZIndex + 2
                , nodeConnection = Just conn
              }
            , Ports.setNodeConnection (Just conn)
            )

        Nothing ->
            let
                newPositions =
                    Dict.update id
                        (Maybe.map (\pos -> { pos | z = model.nextZIndex }))
                        model.windowPositions
            in
            ( { model
                | activeId = Just id
                , windowPositions = newPositions
                , nextZIndex = model.nextZIndex + 1
                , nodeConnection = Nothing
              }
            , Ports.setNodeConnection Nothing
            )


{-| Insert (or update) a plan window, activate it, assign a default
window position if it is new, and raise it to the top.
-}
addPlanWindow : String -> PlanWindow -> Model -> Model
addPlanWindow key win model =
    let
        n =
            Dict.size model.planWindows

        positions1 =
            if Dict.member key model.windowPositions then
                model.windowPositions

            else
                Dict.insert key
                    { x = 60 + remainderBy 6 n * 50
                    , y = 60 + remainderBy 4 n * 40
                    , z = model.nextZIndex
                    , w = planDefaultWinW
                    , h = planDefaultWinH
                    }
                    model.windowPositions

        positions2 =
            Dict.update key (Maybe.map (\p -> { p | z = model.nextZIndex })) positions1
    in
    { model
        | planWindows = Dict.insert key win model.planWindows
        , planOrder =
            if List.member key model.planOrder then
                model.planOrder

            else
                model.planOrder ++ [ key ]
        , planActiveId = Just key
        , windowPositions = positions2
        , nextZIndex = model.nextZIndex + 1
    }


{-| Window key for a plan file path. Saved plans (under plans dir) use
their file name; imported files get a stable slugified key so reopening
the same file focuses the same window.
-}
planWinKeyForPath : String -> String
planWinKeyForPath path =
    let
        base =
            String.split "/" path
                |> List.reverse
                |> List.head
                |> Maybe.withDefault path

        baseNoJson =
            if String.endsWith ".json" base then
                String.dropRight 5 base

            else
                base
    in
    if String.contains ".alayaface/plans" path then
        baseNoJson

    else
        "import-" ++ PT.slugify baseNoJson


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


{-| The session id carried by a runner event, if any.
-}
eventSessionId : R.Event -> Maybe String
eventSessionId ev =
    case ev of
        R.TaskDone sid _ _ _ ->
            Just sid

        R.SessionError sid _ ->
            Just sid

        R.SessionDisconnected sid _ ->
            Just sid

        _ ->
            Nothing


-- ─── Plan runner wiring (effects ↔ ports) ──────────────────────────

{-| Fixed plan mode (D2, R2): the planner hint injected via `--system`
into EVERY session (user sessions and plan node sessions alike). No role
lock — the model keeps its tools and may execute directly. For complex
or multi-step tasks it should first emit a fenced ```json plan block
(the framework auto-creates the plan); after outputting a plan it stops
and waits for the plan to be executed and its result fed back.
-}
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
  "concurrency": 2,
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
runStepIn : String -> Int -> R.Event -> Model -> ( Model, Cmd Msg )
runStepIn planId now ev model =
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

                        ( model2, cmds ) =
                            applyEffectsIn planId model1 effects

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
                    ( model3, Cmd.batch [ cmds, feedbackCmds ] )

                Nothing ->
                    ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


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
            case meta.origin of
                Just origin ->
                    let
                        summary =
                            feedbackSummary planId model

                        prefix =
                            "[Plan Result] The plan has completed. Results:\n\n"
                                ++ summary
                                ++ "\n\n[Plan: "
                                ++ planId
                                ++ "]"

                        -- Origin session alive → send the continuation
                        -- prompt (auto-continue). Closed → D7 (part):
                        -- record the feedback for later display; the
                        -- auto-resume+continue follow-up is pending.
                        feedbackCmd =
                            if Dict.member origin.sessionId model.sessions then
                                Ports.sendPrompt { sessionId = origin.sessionId, text = prefix, media = [] }

                            else
                                Cmd.none

                        -- If the origin is a plan node session, resume the
                        -- waiting node so it answers based on the results.
                        resumeCmd =
                            case findPlanIdBySession model origin.sessionId of
                                Just _ ->
                                    Task.perform
                                        (\t -> PlanRunFrame (Time.posixToMillis t) (R.ResumeDelegatedNode origin.sessionId))
                                        Time.now

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
            let
                newMeta =
                    { meta | feedbacks = meta.feedbacks ++ [ fb ] }

                metaPath =
                    PM.metaPathFor (plansDir model.homeDir) planId
            in
            ( { model | planMetas = Dict.insert planId newMeta model.planMetas }
            , Ports.fsWriteFileText { path = metaPath, content = E.encode 2 (PM.encodeMeta newMeta), createParents = True }
            )

        Nothing ->
            ( model, Cmd.none )


{-| R4 (D9): restart a plan skipping succeeded nodes, cascading to the
sub-plans of delegated (WaitingForPlan) nodes — their planId is reused
(no regeneration), and after the sub-plan completes its feedback resumes
the parent node. Recursion depth is unbounded (D14, experience period).
-}
restartPlanCascade : String -> Model -> ( Model, Cmd Msg )
restartPlanCascade planId model =
    let
        ( m1, c1 ) =
            runStepIn planId 0 R.RestartRun model

        subPlans =
            subPlansOfPlan planId m1

        ( m2, cmds ) =
            List.foldl
                (\spId ( m, c ) ->
                    let
                        ( m3, c3 ) =
                            restartPlanCascade spId m
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
            case meta.origin of
                Just o ->
                    if List.member o.sessionId nodeSids then
                        spId :: acc

                    else
                        acc

                Nothing ->
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


applyEffectsIn : String -> Model -> List PT.Effect -> ( Model, Cmd Msg )
applyEffectsIn planId model effects =
    List.foldl (applyEffectIn planId) ( model, Cmd.none ) effects


applyEffectIn : String -> PT.Effect -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
applyEffectIn planId e ( m, cmds ) =
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
                    update (CloseSession sid) m
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
                        }
                    )

        _ ->
            ( model, Cmd.none )


{-| Session-creation args for a runner node: toolConfirm=allow (auto-
approve tools so tasks don't stall) plus the node's preset/tools
overrides (Nothing = preset defaults / all tools). No planner system
prompt — runner sessions execute tasks, not plans.

NOTE: alayacore's --tool-confirm is a list of tool names that REQUIRE
confirmation; "allow" matches no real tool, so nothing is confirmed →
every tool auto-runs. That is exactly the runner's intent (unattended
execution), but it means a plan task CAN auto-run risky tools — use the
Safe preset / tools field to restrict per node.
-}
nodeSessionArgsIn : String -> String -> Model -> { toolConfirm : Maybe String, preset : Maybe String, builtinTools : Maybe String, systemPrompt : Maybe String, workDir : Maybe String }
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
    in
    { toolConfirm = Just "allow"
    , preset = task |> Maybe.andThen .preset
    , builtinTools = task |> Maybe.andThen .tools
    -- Fixed plan mode (D2): node sessions also get the planner hint, so
    -- a node model may itself delegate to a sub-plan (recursion).
    , systemPrompt = Just planSystemPrompt
    , workDir = planWorkDir planId model
    }


{-| Per-plan working directory for node sessions: every node of a plan
shares ~/.alayaface/plans/<planId>/work (created by the backend on
spawn), so tasks can exchange files within the plan while plans stay
isolated from each other and from the backend's cwd. Nothing while the
home dir is unknown (falls back to the backend cwd).
-}
planWorkDir : String -> Model -> Maybe String
planWorkDir planId model =
    if model.homeDir == "" then
        Nothing

    else
        Just (plansDir model.homeDir ++ "/" ++ planId ++ "/work")


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

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Session Lifecycle
        CreateSession ->
            case model.planCreating of
                -- A session create is in flight: queue the user's create
                -- on the same serialized queue so the runner's
                -- SessionCreated cannot be misbound to it.
                Just _ ->
                    ( { model | planCreateQueue = model.planCreateQueue ++ [ UserCreate "normal" ], showGlobalMenu = False }
                    , Cmd.none
                    )

                Nothing ->
                    ( { model | pendingSwitchOnCreate = True, showGlobalMenu = False }
                    , Ports.createSession { toolConfirm = Nothing, preset = Nothing, builtinTools = Nothing, systemPrompt = Just planSystemPrompt, workDir = Nothing }
                    )

        SessionCreated id ->
            let
                newSession =
                    T.emptySession id

                newSessions =
                    Dict.insert id newSession model.sessions

                -- Replay any buffered events that arrived before this session was registered
                buffered =
                    Dict.get id model.pendingEvents |> Maybe.withDefault []

                sessionsAfterBuffer =
                    List.foldl applyPendingEvent newSessions buffered

                -- Only auto-switch on initial creation (activeId was Nothing)
                -- If user is already viewing a session, don't steal focus.
                -- Runner-created node sessions never steal focus: the user
                -- is watching the plan DAG and opens node sessions by
                -- clicking the DAG.
                isRunnerCreate =
                    case model.planCreating of
                        Just (RunnerCreate _ _) ->
                            True

                        _ ->
                            False

                newActiveId =
                    if not isRunnerCreate && (model.pendingSwitchOnCreate || model.activeId == Nothing) then
                        Just id
                    else
                        model.activeId

                cmds =
                    if not isRunnerCreate && (model.pendingSwitchOnCreate || model.activeId == Nothing) then
                        Cmd.batch [ Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ id)), Ports.scrollToBottom { sessionId = id } ]
                    else
                        Cmd.none

                baseModel =
                    { model
                        | sessions = sessionsAfterBuffer
                        , activeId = newActiveId
                        , initializing = False
                        , sessionOrder = model.sessionOrder ++ [ id ]
                        , sessionNums = Dict.insert id model.nextSessionNum model.sessionNums
                        , nextSessionNum = model.nextSessionNum + 1
                        , windowPositions =
                            if Dict.member id model.windowPositions then
                                model.windowPositions
                            else
                                let
                                    -- Cascade: each new window offsets from previous
                                    -- Use nextSessionNum (monotonically increasing) to avoid
                                    -- overlapping with existing windows after session closures
                                    n =
                                        model.nextSessionNum

                                    baseX =
                                        60 + remainderBy 6 n * 50

                                    baseY =
                                        60 + remainderBy 4 n * 40
                                in
                                Dict.insert id
                                    { x = baseX
                                    , y = baseY
                                    , z = model.nextZIndex
                                    , w = defaultWinW
                                    , h = defaultWinH
                                    }
                                    model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        -- Only consume pendingSwitchOnCreate when this
                        -- session actually consumed it (non-runner). A
                        -- runner session arriving in between must not
                        -- steal a user/resume focus request.
                        , pendingSwitchOnCreate =
                            if isRunnerCreate then
                                model.pendingSwitchOnCreate

                            else
                                False
                        , pendingEvents = Dict.remove id model.pendingEvents
                    }

                -- A session resumed for a plan node gets a FRESH id from
                -- resume_session while keeping the ORIGINAL on-disk dir.
                -- The node stays bound to the original id (the dir name)
                -- so it can be resumed again after this window closes;
                -- record the live→orig mapping so node clicks can find
                -- this live window and CloseSession can attribute it back
                -- to the plan node. Never consumed by a runner-created
                -- session.
                resumedConn =
                    case ( model.planResumeFrom, isRunnerCreate ) of
                        ( Just origId, False ) ->
                            Dict.get origId baseModel.planNodeSessions
                                |> Maybe.andThen NC.parseNodeConnection
                                |> Maybe.map
                                    (\( planId, nodeId ) ->
                                        { sessionId = id, planId = planId, nodeId = nodeId }
                                    )

                        _ ->
                            Nothing

                resumedModel =
                    case ( model.planResumeFrom, isRunnerCreate ) of
                        ( Just origId, False ) ->
                            let
                                label =
                                    Dict.get origId baseModel.planNodeSessions

                                -- The new session is focused; pair the z
                                -- order like activateSessionModel does
                                -- (session top, plan window second layer).
                                zRaised =
                                    case resumedConn of
                                        Just c ->
                                            baseModel.windowPositions
                                                |> Dict.update id
                                                    (Maybe.map (\pos -> { pos | z = baseModel.nextZIndex + 1 }))
                                                |> Dict.update c.planId
                                                    (Maybe.map (\pos -> { pos | z = baseModel.nextZIndex }))

                                        Nothing ->
                                            Dict.update id
                                                (Maybe.map (\pos -> { pos | z = baseModel.nextZIndex }))
                                                baseModel.windowPositions

                                zBump =
                                    case resumedConn of
                                        Just _ ->
                                            2

                                        Nothing ->
                                            1
                            in
                            { baseModel
                                | planResumeFrom = Nothing
                                , planResumeOwner = Nothing
                                , planResumedFrom = Dict.insert id origId baseModel.planResumedFrom
                                , nodeConnection = resumedConn
                                , windowPositions = zRaised
                                , nextZIndex = baseModel.nextZIndex + zBump
                                , planNodeSessions =
                                    case label of
                                        Just l ->
                                            Dict.insert id l baseModel.planNodeSessions

                                        Nothing ->
                                            baseModel.planNodeSessions
                            }

                        _ ->
                            baseModel

                -- Consume the in-flight marker for user creates (runner
                -- creates are consumed inside PlanBindSession).
                settledModel =
                    case model.planCreating of
                        Just (UserCreate _) ->
                            { resumedModel | planCreating = Nothing }

                        _ ->
                            resumedModel

                ( drainedModel, drainCmd ) =
                    case model.planCreating of
                        -- user create finished: start the next queued create
                        Just (UserCreate _) ->
                            startNextCreateIn settledModel

                        _ ->
                            ( settledModel, Cmd.none )
            in
            ( drainedModel
            , Cmd.batch
                [ cmds
                , drainCmd
                , Ports.setNodeConnection resumedConn
                , case model.planCreating of
                    -- A runner-created session: bind it to its node
                    -- (PlanBindSession also starts the next queued create).
                    Just (RunnerCreate planId nodeId) ->
                        Task.perform (\t -> PlanBindSession (Time.posixToMillis t) planId nodeId id) Time.now

                    _ ->
                        Cmd.none
                ]
            )

        SessionCreateError text ->
            -- create_session failed. Without this the in-flight marker
            -- (planCreating) would stay set forever: every later create
            -- queues behind it and the run deadlocks (e.g. invalid node
            -- preset). Fail the pending node so retry/backoff applies,
            -- then drain the queue.
            case model.planCreating of
                Just (RunnerCreate planId nodeId) ->
                    let
                        m0 =
                            { model | planCreating = Nothing }

                        ( m1, c1 ) =
                            runStepIn planId 0 (R.SessionCreateFailed nodeId text) m0

                        ( m2, c2 ) =
                            startNextCreateIn m1
                    in
                    ( m2, c2 )

                Just (UserCreate _) ->
                    -- A user-initiated create failed: clear the marker and
                    -- continue with the next queued create.
                    let
                        m0 =
                            { model | planCreating = Nothing }
                    in
                    startNextCreateIn m0

                Nothing ->
                    ( model, Cmd.none )

        CloseSession id ->
            -- If the closed window belongs to a plan run, fail its node
            -- so the runner retries/continues instead of hanging.
            let
                runnerFailCmd =
                    case findPlanIdBySession model id of
                        Just _ ->
                            Task.perform
                                (\t ->
                                    PlanRunFrame (Time.posixToMillis t)
                                        (R.SessionDisconnected id "Session window closed")
                                )
                                Time.now

                        Nothing ->
                            Cmd.none
            in
            ( { model
                | sessions = Dict.remove id model.sessions
                , sessionOrder = List.filter (\k -> k /= id) model.sessionOrder
                , sessionNums = Dict.remove id model.sessionNums
                , windowPositions = Dict.remove id model.windowPositions
                , planNodeSessions = Dict.remove id model.planNodeSessions
                , planResumedFrom = Dict.remove id model.planResumedFrom
                , planTaskStarted = Set.remove id model.planTaskStarted
                , nodeConnection =
                    if (model.nodeConnection |> Maybe.map (\c -> c.sessionId)) == Just id then
                        Nothing

                    else
                        model.nodeConnection
                , activeId =
                    if model.activeId == Just id then
                        List.head (List.reverse (List.filter (\k -> k /= id) model.sessionOrder))
                    else
                        model.activeId
              }
            , Cmd.batch
                [ Ports.closeSession { sessionId = id }
                , runnerFailCmd
                , if (model.nodeConnection |> Maybe.map (\c -> c.sessionId)) == Just id then
                    Ports.setNodeConnection Nothing

                  else
                    Cmd.none
                ]
            )

        -- Transport Events
        DeltaEvent raw ->
            case D.decodeValue P.deltaEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                newSession =
                                    H.handleDeltaEvent session ev

                                cmds =
                                    if session.atBottom then
                                        Ports.scrollToBottom { sessionId = ev.sessionId }
                                    else
                                        Cmd.none
                            in
                            ( { model
                                | sessions = Dict.insert ev.sessionId newSession model.sessions
                              }
                            , cmds
                            )

                        Nothing ->
                            bufferPendingEvent model ev.sessionId raw

                Err _ ->
                    ( model, Cmd.none )

        FrameEvent raw ->
            case D.decodeValue P.frameEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                newSession =
                                    H.handleFrameEvent session ev

                                msgCountChanged =
                                    List.length newSession.messages /= session.prevMsgCount

                                mcpJustCompleted =
                                    session.mcpStatus /= Nothing && newSession.mcpStatus == Nothing

                                cmds =
                                    Cmd.batch
                                        (List.filterMap identity
                                            [ if msgCountChanged && session.atBottom then
                                                Just (Ports.scrollToBottom { sessionId = ev.sessionId })

                                              else
                                                Nothing
                                            , Nothing
                                            ]
                                        )

                                updatedModel =
                                    { model
                                        | sessions = Dict.insert ev.sessionId { newSession | prevMsgCount = List.length newSession.messages } model.sessions
                                    }

                                -- Plan Mode (R2): when an assistant message
                                -- completes with a fenced ```json block
                                -- carrying the alayaface-plan marker, AUTO-
                                -- CREATE the plan (no button). The offer
                                -- entry is still recorded keyed by message
                                -- id so replay cannot create duplicates;
                                -- PlanCreateOffer consumes it.
                                -- NOTE: in delta mode the AT frame itself is
                                -- an empty terminator, so detect on the
                                -- final message content, not ev.content.
                                autoOfferCmd =
                                    if ev.tag == "AT" then
                                        case List.head (List.reverse newSession.messages) of
                                            Just m ->
                                                let
                                                    planIdx =
                                                        planIndexForMessage newSession.messages
                                                in
                                                if m.role == T.Assistant && not (Dict.member ( ev.sessionId, planIdx ) updatedModel.pendingPlanOffers) && not (messageBoundToPlan updatedModel ev.sessionId planIdx) then
                                                    case Plan.Detect.extractPlanJson m.content of
                                                        Just offerRaw ->
                                                            if Plan.Detect.hasPlanTypeMarker offerRaw then
                                                                -- R-series: the plan window auto-opens only when this plan
                                                                -- message is still the session's LAST message a moment later
                                                                -- (PlanOfferSettle). A history replay feeding plan frames in
                                                                -- the middle of a session (or a replay whose meta binding is
                                                                -- still being rebuilt from disk) must NOT pop a window.
                                                                Task.perform (\_ -> PlanOfferSettle ev.sessionId planIdx) (Process.sleep 1500)

                                                            else
                                                                Cmd.none

                                                        Nothing ->
                                                            Cmd.none

                                                else
                                                    Cmd.none

                                            Nothing ->
                                                Cmd.none

                                    else
                                        Cmd.none

                                updatedModel2 =
                                    if ev.tag == "AT" then
                                        case List.head (List.reverse newSession.messages) of
                                            Just m ->
                                                let
                                                    planIdx =
                                                        planIndexForMessage newSession.messages
                                                in
                                                if m.role == T.Assistant && not (Dict.member ( ev.sessionId, planIdx ) updatedModel.pendingPlanOffers) && not (messageBoundToPlan updatedModel ev.sessionId planIdx) then
                                                    case Plan.Detect.extractPlanJson m.content of
                                                        Just offerRaw ->
                                                            if Plan.Detect.hasPlanTypeMarker offerRaw then
                                                                { updatedModel | pendingPlanOffers = Dict.insert ( ev.sessionId, planIdx ) offerRaw updatedModel.pendingPlanOffers }

                                                            else
                                                                updatedModel

                                                        Nothing ->
                                                            updatedModel

                                                else
                                                    updatedModel

                                            Nothing ->
                                                updatedModel

                                    else
                                        updatedModel

                                -- Runner injection: task done / SM error for
                                -- a node-owned session feeds the state machine.
                                -- planEventFromFrame also tracks task-start
                                -- (in_progress:true) so the alayacore boot
                                -- task frame is not mistaken for a real
                                -- task completion (R5 fix).
                                ( updatedModel3, runnerEv ) =
                                    planEventFromFrame updatedModel2 ev

                                runnerFrameCmd =
                                    case runnerEv of
                                        Just runnerEvent ->
                                            Task.perform (\t -> PlanRunFrame (Time.posixToMillis t) runnerEvent) Time.now

                                        Nothing ->
                                            Cmd.none
                            in
                            -- model_sync completes asynchronously via CO:
                            -- success closes the overlay, failure keeps it open
                            case decodeSyncOutcome raw of
                                Just ( isError, message ) ->
                                    if newSession.modelSelector.page == ModelSelSyncing then
                                        update (ForSession ev.sessionId (ModelSelectorSyncResult isError message)) updatedModel3

                                    else
                                        ( updatedModel3, Cmd.batch [ cmds, runnerFrameCmd, autoOfferCmd ] )

                                Nothing ->
                                    ( updatedModel3, Cmd.batch [ cmds, runnerFrameCmd, autoOfferCmd ] )

                        Nothing ->
                            bufferPendingEvent model ev.sessionId raw

                Err _ ->
                    ( model, Cmd.none )

        StatusEvent raw ->
            case D.decodeValue P.statusEventDecoder raw of
                Ok ev ->
                    let
                        -- Runner injection: a node-owned session that
                        -- disconnects before task completion is a failure.
                        statusRunnerCmd =
                            if not ev.connected then
                                case findPlanIdBySession model ev.sessionId of
                                    Just _ ->
                                        Task.perform
                                            (\t ->
                                                PlanRunFrame (Time.posixToMillis t)
                                                    (R.SessionDisconnected ev.sessionId ev.message)
                                            )
                                            Time.now

                                    Nothing ->
                                        Cmd.none

                            else
                                Cmd.none
                    in
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                updated =
                                    { session
                                        | connected = ev.connected
                                        , statusMsg = ev.message
                                    }
                            in
                            if not ev.connected && session.modelSelector.page == ModelSelSyncing then
                                -- A disconnect means the model_sync CO will
                                -- never arrive — fail the sync instead of
                                -- leaving the overlay stuck.
                                ( { model
                                    | sessions = Dict.insert ev.sessionId
                                        { updated
                                            | modelSelector = Sel.syncFailed "Session disconnected during sync" updated.modelSelector
                                        }
                                        model.sessions
                                  }
                                , statusRunnerCmd
                                )

                            else
                                ( { model
                                    | sessions = Dict.insert ev.sessionId updated model.sessions
                                  }
                                , statusRunnerCmd
                                )

                        Nothing ->
                            let
                                ( model1, cmds1 ) =
                                    bufferPendingEvent model ev.sessionId raw
                            in
                            ( model1, Cmd.batch [ cmds1, statusRunnerCmd ] )

                Err _ ->
                    ( model, Cmd.none )

        -- User Actions
        SendPrompt ->
            case getActiveSession model of
                Just s ->
                    let
                        text =
                            String.trim s.input

                        mediaItems =
                            List.map
                                (\m ->
                                    E.object
                                        [ ( "media_type", E.string (T.mediaTypeToString m.mediaType) )
                                        , ( "uri", E.string m.uri )
                                        ]
                                )
                                s.staged
                    in
                    if text == "" && List.isEmpty s.staged then
                        ( model, Cmd.none )

                    else
                        ( { model
                            | inputRows = 1
                            , sessions = Dict.insert s.id
                                { s
                                    | input = ""
                                    , staged = []
                                    , statusMsg = "Sending…"
                                    , sendPending = True
                                }
                                model.sessions
                          }
                        , Ports.sendPrompt
                            { sessionId = s.id
                            , text = text
                            , media = mediaItems
                            }
                        )

                Nothing ->
                    ( model, Cmd.none )

        CancelTask ->
            case model.activeId of
                Just id ->
                    ( model
                    , Ports.cancelTask { sessionId = id }
                    )

                Nothing ->
                    ( model, Cmd.none )

        SetModel modelId ->
            case model.activeId of
                Just id ->
                    ( model, Ports.setModel { sessionId = id, modelId = modelId } )

                Nothing ->
                    ( model, Cmd.none )

        ConfirmTool sid id allowed ->
            case Dict.get sid model.sessions of
                Just _ ->
                    ( updateAfterConfirm model sid
                    , Ports.confirmTool { sessionId = sid, id = id, allowed = allowed }
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthConfirm sid server ->
            case Dict.get sid model.sessions of
                Just s ->
                    case List.filter (\a -> a.server == server) s.pendingMcpAuths |> List.head of
                        Just auth ->
                            ( { model | sessions = Dict.insert sid { s | mcpAuthRunning = Just server } model.sessions }
                            , Ports.startMcpAuthFlow
                                { sessionId = sid
                                , serverName = server
                                , authUrl = auth.url
                                }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthDeny sid server ->
            case Dict.get sid model.sessions of
                Just sess ->
                    ( { model
                        | sessions = Dict.insert sid
                            { sess
                                | pendingMcpAuths = List.filter (\a -> a.server /= server) sess.pendingMcpAuths
                                , mcpAuthRunning =
                                    if sess.mcpAuthRunning == Just server then
                                        Nothing

                                    else
                                        sess.mcpAuthRunning
                            }
                            model.sessions
                      }
                    , Cmd.batch
                        [ Ports.sendMcpDecline { sessionId = sid, server = server }
                        , focusInput model
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseMcpAuthOverlay sid ->
            case Dict.get sid model.sessions of
                Just _ ->
                    ( { model | sessions = Dict.update sid
                        (Maybe.map (\sess ->
                            { sess
                                | mcpStatus = Nothing
                                , pendingMcpAuths = []
                                , mcpAuthRunning = Nothing
                            }
                        ))
                        model.sessions
                      }
                    , Cmd.batch
                        [ Ports.sendMcpCancel { sessionId = sid }
                        , focusInput model
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpCancelAll sid ->
            case Dict.get sid model.sessions of
                Just sess ->
                    ( { model
                        | sessions = Dict.insert sid
                            { sess
                                | pendingMcpAuths = []
                                , mcpAuthRunning = Nothing
                                , mcpStatus = Nothing
                            }
                            model.sessions
                      }
                    , Cmd.batch
                        [ Ports.sendMcpCancel { sessionId = sid }
                        , focusInput model
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseConfirm sid ->
            case Dict.get sid model.sessions of
                Just sess ->
                    ( { model
                        | sessions = Dict.insert sid
                            { sess | pendingConfirm = [] }
                            model.sessions
                      }
                    , focusInput model
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseMcpInit sid ->
            update (McpCancelAll sid) model

        ForkMessage historyId ->
            case model.activeId of
                Just sid ->
                    ( model
                    , Ports.forkSession { sourceSessionId = sid, historyId = historyId }
                    )

                Nothing ->
                    ( model, Cmd.none )

        ShowCtxMenu x y historyId sessionId ->
            ( { model
                | ctxVisible = True
                , ctxX = x
                , ctxY = y
                , ctxHistoryId = historyId
                , ctxSessionId = sessionId
              }
            , Cmd.none
            )

        HideCtxMenu ->
            ( { model | ctxVisible = False }, Cmd.none )

        ToggleMsgCollapse sid msgId ->
            ( updateSession model sid (\sess ->
                case List.filter (\m -> m.id == msgId) sess.messages |> List.head of
                    Just m ->
                        { sess | msgCollapsed = T.toggleMsgCollapsed sess.msgCollapsed m }

                    Nothing ->
                        sess
              )
            , Cmd.none
            )

        ForkFromCtx ->
            if model.ctxHistoryId /= "" && model.ctxSessionId /= "" then
                ( { model | ctxVisible = False, pendingSwitchOnCreate = True }
                , Ports.forkSession { sourceSessionId = model.ctxSessionId, historyId = model.ctxHistoryId }
                )

            else
                ( { model | ctxVisible = False }, Cmd.none )

        RemoveStaged stagedId ->
            case model.activeId of
                Just sid ->
                    case Dict.get sid model.sessions of
                        Just s ->
                            let
                                newStaged =
                                    List.filter (\m -> m.id /= stagedId) s.staged
                            in
                            ( { model | sessions = Dict.insert sid { s | staged = newStaged } model.sessions }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ConfirmFilePickerUrl ->
            case getActiveSession model of
                Just s ->
                    let
                        url =
                            String.trim s.filePicker.input
                    in
                    if url == "" then
                        ( model, Cmd.none )

                    else
                        let
                            detectedType =
                                FP.detectMediaType url

                            newItem =
                                { id = "url-" ++ String.fromInt (List.length s.staged)
                                , mediaType = detectedType
                                , uri = url
                                , name = Just (String.left 60 url)
                                }
                        in
                        ( updateActiveSession model (\sess ->
                            let
                                fp =
                                    sess.filePicker
                            in
                            { sess
                                | staged = sess.staged ++ [ newItem ]
                                , filePicker = { fp | show = False, input = "" }
                            }
                          )
                        , focusInput model
                        )

                Nothing ->
                    ( model, Cmd.none )

        SetInput val ->
            case model.activeId of
                Just sid ->
                    let
                        s =
                            Dict.get sid model.sessions
                    in
                    case s of
                        Just sess ->
                            ( { model
                                | sessions = Dict.insert sid { sess | input = val } model.sessions
                                , inputRows = clamp 1 3 (List.length (String.lines val))
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )
        SwitchSession id ->
            if model.activeId == Just id then
                -- Already active: clicking inside the window again must
                -- NOT steal focus (it clears the user's text selection).
                ( model, Cmd.none )
            else
                let
                    ( m, c ) =
                        activateSessionModel model id
                in
                ( m
                , Cmd.batch
                    [ c
                    , Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ id))
                    ]
                )

        -- File Picker
        OpenFilePicker ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        let
                            fp =
                                sess.filePicker
                        in
                        { sess
                            | filePicker =
                                { fp
                                    | show = True
                                    , mode = T.Local
                                    , input = ""
                                    , filter = ""
                                    , selected = 0
                                    , loading = True
                                }
                        }
                      )
                    , Cmd.batch
                        [ Ports.fsHomeDir {}
                        , focusAfterDelay ("fp-page-input-" ++ s.id)
                        , Ports.setCursorPos ("fp-page-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseFilePicker ->
            ( updateActiveSession model (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s | filePicker = { fp | show = False, savedLocalPath = "", savedUrlPath = "" } }
              )
            , focusInput model
            )

        SetFilePickerInput val ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker
                    in
                    if fp.mode == T.Url then
                        -- URL mode: just update input, no path parsing
                        ( updateActiveSession model (\sess ->
                            { sess | filePicker = { fp | input = val } }
                          )
                        , Cmd.none
                        )

                    else
                        -- If input was cleared (select-all + delete, etc.),
                        -- restore to current directory path
                        let
                            safeVal =
                                if val == "" then
                                    "/"
                                else
                                    val
                        in
                        -- Local mode: parse input as path, extract filter text,
                        -- navigate directory if needed
                        let
                            ( needsResolve, resolvePath, filterText ) =
                                FP.parsePathInput safeVal fp.dir fp.baseDir

                            cmd =
                                if needsResolve then
                                    Ports.fsResolvePath { path = resolvePath }
                                else
                                    Cmd.none

                            -- Clamp selection to filtered list length
                            previewFp =
                                { fp | input = safeVal, filter = filterText }

                            filteredLen =
                                List.length (FP.filterEntries previewFp)

                            clampedIdx =
                                if fp.selected >= filteredLen then
                                    max 0 (filteredLen - 1)
                                else
                                    fp.selected
                        in
                        ( updateActiveSession model (\sess ->
                            { sess
                                | filePicker = { fp | input = safeVal, filter = filterText, selected = clampedIdx }
                            }
                          )
                        , cmd
                        )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerNavigateDir name ->
            -- User clicked a directory in the file list:
            -- append the directory name + "/" to the current input path.
            case getActiveSession model of
                Just s ->
                    let
                        ( newFp, newDir ) =
                            FP.appendDirToInput s.filePicker name
                    in
                    ( updateActiveSession model (\sess ->
                        { sess | filePicker = newFp }
                      )
                    , Ports.fsResolvePath { path = newDir }
                    )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerSelectItem idx ->
            let
                scrollCmd =
                    case getActiveSession model of
                        Just s ->
                            let
                                entries =
                                    FP.filterEntries s.filePicker
                            in
                            case List.head (List.drop idx entries) of
                                Just e ->
                                    Ports.scrollIntoView ("fp-item-" ++ s.id ++ "-" ++ e.name)

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none
            in
            ( updateActiveSession model (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s | filePicker = { fp | selected = idx } }
              )
            , scrollCmd
            )

        FilePickerConfirmItem ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker

                        entries =
                            FP.filterEntries fp
                    in
                    case List.head (List.drop fp.selected entries) of
                        Just entry ->
                            if entry.isDir then
                                -- Directory: autocomplete its name into the input path
                                let
                                    ( newFp, newDir ) =
                                        FP.appendDirToInput fp entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess | filePicker = newFp }
                                  )
                                , Ports.fsResolvePath { path = newDir }
                                )

                            else
                                -- File: select it
                                let
                                    fullPath =
                                        if fp.dir == "" then
                                            entry.name
                                        else
                                            fp.dir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePicker = { fp | loading = True, pendingFileName = entry.name }
                                    }
                                  )
                                , Ports.fsReadFileDataUri { path = fullPath }
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerPickItem idx ->
            -- Pick an item by index (from click). Same logic as ConfirmItem but uses
            -- the explicit clicked index instead of keyboard-selected index.
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker

                        entries =
                            FP.filterEntries fp
                    in
                    case List.head (List.drop idx entries) of
                        Just entry ->
                            if entry.isDir then
                                let
                                    ( newFp, newDir ) =
                                        FP.appendDirToInput fp entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess | filePicker = { newFp | selected = idx } }
                                  )
                                , Ports.fsResolvePath { path = newDir }
                                )

                            else
                                let
                                    fullPath =
                                        if fp.dir == "" then
                                            entry.name
                                        else
                                            fp.dir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePicker = { fp | loading = True, selected = idx, pendingFileName = entry.name }
                                    }
                                  )
                                , Ports.fsReadFileDataUri { path = fullPath }
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerToggleMode ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker

                        ( newMode, newInput ) =
                            case fp.mode of
                                T.Local ->
                                    -- Switching FROM local TO URL: save local path, restore saved URL
                                    ( T.Url
                                    , fp.savedUrlPath
                                    )

                                T.Url ->
                                    -- Switching FROM URL TO local: save URL, restore saved local path
                                    let
                                        restoredLocal =
                                            if fp.savedLocalPath /= "" then
                                                fp.savedLocalPath
                                            else if fp.dir /= "" then
                                                fp.dir ++ "/"
                                            else
                                                ""
                                    in
                                    ( T.Local
                                    , restoredLocal
                                    )

                        ( savedLocal, savedUrl ) =
                            case fp.mode of
                                T.Local ->
                                    ( fp.input
                                    , ""
                                    )

                                T.Url ->
                                    ( ""
                                    , fp.input
                                    )
                    in
                    ( updateActiveSession model (\oldS ->
                        { oldS
                            | filePicker =
                                { fp
                                    | mode = newMode
                                    , input = newInput
                                    , filter = ""
                                    , savedLocalPath = savedLocal
                                    , savedUrlPath = savedUrl
                                }
                        }
                      )
                    , Cmd.batch
                        [ focusAfterDelay ("fp-page-input-" ++ s.id)
                        , Ports.setCursorPos ("fp-page-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerNavigateUp ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker
                    in
                    if fp.dir /= "" && fp.baseDir /= "" then
                        let
                            cleanPath =
                                if String.endsWith "/" fp.dir then
                                    String.dropRight 1 fp.dir
                                else
                                    fp.dir

                            parts =
                                String.split "/" cleanPath

                            parentDir =
                                case List.reverse parts of
                                    _ :: rest ->
                                        String.join "/" (List.reverse rest)

                                    [] ->
                                        "/"
                        in
                        ( updateActiveSession model (\sess ->
                            { sess
                                | filePicker = { fp | loading = True, input = parentDir ++ "/", filter = "" }
                            }
                          )
                        , Ports.fsResolvePath { path = parentDir }
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FsListDirResult entries ->
            if model.planMetaLoading then
                -- R3: dedicated listing for meta.json files (planMetas
                -- index rebuild). Collect *.meta.json paths, then read
                -- them one at a time via the meta read queue.
                let
                    metaFiles =
                        List.filterMap (\v -> D.decodeValue planDirEntryDecoder v |> Result.toMaybe) entries
                            |> List.filter (\e -> not e.isDir)
                            |> List.map .name
                            |> List.filter (\n -> String.endsWith ".meta.json" n)
                            |> List.sort

                    paths =
                        List.map (\n -> plansDir model.homeDir ++ "/" ++ n) metaFiles

                    queue =
                        paths

                    ( m1, c1 ) =
                        case queue of
                            next :: rest ->
                                ( { model | planMetaLoading = False, planMetaReading = Just next, planMetaReadQueue = rest }
                                , Ports.fsReadFileText { path = next }
                                )

                            [] ->
                                ( { model | planMetaLoading = False }, Cmd.none )
                in
                ( m1, c1 )

            else
                let
                    pm =
                        model.planManager
                in
                if pm.show && pm.tab == PlanTabBrowse then
                -- Browse tab: directory listing for plan import.
                let
                    parsed =
                        List.filterMap FP.decodeDirEntry entries
                            |> List.filter (\e -> e.name /= "..")
                in
                case pm.browser of
                    Just fp ->
                        ( { model
                            | planManager =
                                { pm
                                    | browser = Just { fp | entries = parsed, loading = False, error = Nothing }
                                }
                          }
                        , Cmd.none
                        )

                    Nothing ->
                        ( model, Cmd.none )

            else if pm.show then
                -- Plan manager is listing ~/.alayaface/plans: keep only
                -- *.json files (skip *.run.json run-state files).
                let
                    parsed =
                        List.filterMap (\v -> D.decodeValue planDirEntryDecoder v |> Result.toMaybe) entries
                            |> List.filter (\e -> not e.isDir)
                            |> List.map .name
                            |> List.filter (\n -> String.endsWith ".json" n && not (String.endsWith ".run.json" n))
                            |> List.sort

                    files =
                        List.map
                            (\n -> { name = n, path = plansDir model.homeDir ++ "/" ++ n })
                            parsed
                in
                ( { model
                    | planManager = { pm | loading = False, plans = files, error = Nothing }
                  }
                , Cmd.none
                )

            else
                let
                    parsed =
                        List.filterMap FP.decodeDirEntry entries

                    -- Filter out ".." (parent directory entry) — not useful in UI
                    noDotDot =
                        List.filter (\e -> e.name /= "..") parsed
                in
                ( updateActiveSession model (\s ->
                    let
                        fp =
                            s.filePicker
                    in
                    { s
                        | filePicker = { fp | entries = noDotDot, loading = False, error = Nothing }
                    }
                  )
                , Cmd.none
                )

        FsHomeDirResult home ->
            let
                model2 =
                    { model | homeDir = home }

                pm0 =
                    model2.planManager

                -- If the Plans manager's Browse tab is active and its
                -- browser is still waiting for a home dir, initialize it.
                needsBrowserInit =
                    pm0.show
                        && pm0.tab == PlanTabBrowse
                        && (case pm0.browser of
                                Just fp ->
                                    fp.dir == ""

                                Nothing ->
                                    False
                           )

                model3 =
                    if needsBrowserInit then
                        { model2 | planManager = { pm0 | browser = Just (initPlanBrowser home) } }
                    else
                        model2
            in
            ( updateActiveSession model3 (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s
                    | filePicker =
                        { fp
                            | baseDir = home
                            , dir = home
                            , input = home ++ "/"
                            , filter = ""
                            , loading = True
                        }
                }
              )
            , Cmd.batch
                [ Ports.fsListDir { path = home }
                , if model3.planManager.show then
                    case model3.planManager.tab of
                        PlanTabSaved ->
                            Ports.fsListDir { path = plansDir home }

                        PlanTabBrowse ->
                            Ports.fsListDir { path = home }

                  else
                    Cmd.none
                , -- R3: rebuild the planMetas index from meta.json files
                  -- (status bars / feedback routing survive restarts).
                  Ports.fsListDir { path = plansDir home }
                , case model.activeId of
                    Just sid ->
                        Cmd.batch
                            [ focusAfterDelay ("fp-page-input-" ++ sid)
                            , Ports.setCursorPos ("fp-page-input-" ++ sid)
                            ]

                    Nothing ->
                        Cmd.none
                ]
            )
            |> (\( m, c ) -> ( { m | planMetaLoading = True }, c ))

        FsReadFileResult uri ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker

                        name =
                            if fp.pendingFileName /= "" then
                                Just fp.pendingFileName
                            else
                                Nothing

                        detectedType =
                            case name of
                                Just n -> FP.detectMediaType n
                                Nothing -> T.Document

                        newItem =
                            { id = "file-" ++ String.fromInt (List.length s.staged)
                            , mediaType = detectedType
                            , uri = uri
                            , name = name
                            }
                    in
                    ( updateActiveSession model (\sess ->
                        { sess
                            | filePicker = { fp | show = False, input = "", pendingFileName = "" }
                            , staged = sess.staged ++ [ newItem ]
                        }
                      )
                    , focusInput model
                    )

                Nothing ->
                    ( model, Cmd.none )

        -- Text file write result: Plan Mode plan save (only writer so far).
        FsWriteResult raw ->
            case D.decodeValue fsOkDecoder raw of
                Ok { ok, error } ->
                    if ok then
                        let
                            model2 =
                                updateActivePlanWin model
                                    (\w ->
                                        let
                                            wv =
                                                w.view
                                        in
                                        { w | view = { wv | saving = False } }
                                    )

                            pm =
                                model2.planManager
                        in
                        ( { model2 | planManager = { pm | loading = False, error = Nothing } }
                        -- Refresh the manager list only while it is open:
                        -- run.json writes happen on every runner step and
                        -- a stray fs_list_dir (plans dir) would otherwise
                        -- land in the file picker branch of FsListDirResult.
                        , if model2.planManager.show then
                            refreshPlanList model2

                          else
                            Cmd.none
                        )

                    else
                        ( setPlanErrors [ error ] model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        -- Text file read result: Plan Mode open/import (target.isResume =
        -- False), Load run (isResume=True + continueRun=True) or a silent
        -- best-effort run-state restore when a plan window opens
        -- (isResume=True + continueRun=False).
        FsReadResult raw ->
            case model.planMetaReading of
                Just path ->
                    -- R3: the read belongs to the meta.json rebuild chain.
                    let
                        decoded =
                            D.decodeValue fsReadOkDecoder raw

                        m1 =
                            case decoded of
                                Ok { ok, content } ->
                                    if ok then
                                        case D.decodeString PM.decodeMeta content of
                                            Ok meta ->
                                                let
                                                    planId =
                                                        String.dropRight (String.length ".meta.json") (String.dropLeft (String.length (plansDir model.homeDir) + 1) path)
                                                in
                                                { model | planMetas = Dict.insert planId meta model.planMetas }

                                            Err _ ->
                                                model

                                    else
                                        model

                                Err _ ->
                                    model
                    in
                    case m1.planMetaReadQueue of
                        next :: rest ->
                            ( { m1 | planMetaReading = Just next, planMetaReadQueue = rest }
                            , Ports.fsReadFileText { path = next }
                            )

                        [] ->
                            ( { m1 | planMetaReading = Nothing }, Cmd.none )

                Nothing ->
                    case model.planReadTarget of
                        Just target ->
                            if target.isResume then
                                -- Read <plan>.run.json → restore run state in the
                                -- target plan window (and optionally continue).
                                case D.decodeValue fsReadOkDecoder raw of
                                    Ok { ok, content, error } ->
                                        if ok then
                                            let
                                                win0 =
                                                    Dict.get target.planId model.planWindows
                                                        |> Maybe.withDefault emptyPlanWindow
                                            in
                                            case ( D.decodeString PT.decodeRunStateOverlay content, win0.view.plan ) of
                                                ( Ok overlay, Just plan ) ->
                                                    if target.continueRun then
                                                        -- Load run: unfinished nodes
                                                        -- re-run; restore then continue.
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
                                                        runStepIn target.planId 0 R.ContinueRun m1

                                                    else
                                                        -- Silent restore: only when
                                                        -- the window has no run yet
                                                        -- (a Run clicked in between
                                                        -- must not be overwritten).
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
                                                        -- silent restore: ignore a
                                                        -- corrupt run file
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

                                    Err _ ->
                                        ( { model | planReadTarget = Nothing }, Cmd.none )

                            else
                                -- Open/import: parse the plan file and open (or
                                -- focus) its window; then best-effort restore the
                                -- saved run state so node→session bindings come back.
                                case D.decodeValue fsReadOkDecoder raw of
                                    Ok { ok, content, error } ->
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

                                                        pm =
                                                            model.planManager

                                                        m1 =
                                                            { model
                                                                | planReadTarget = Nothing
                                                                , planManager =
                                                                    { pm
                                                                        | show = False
                                                                        , loading = False
                                                                        , filter = ""
                                                                        , tab = PlanTabSaved
                                                                        , browser = Nothing
                                                                    }
                                                            }

                                                        m2 =
                                                            addPlanWindow target.planId win1 m1
                                                    in
                                                    if win0.run == Nothing then
                                                        -- Fresh window: chain a silent
                                                        -- read of <plan>.run.json to
                                                        -- restore statuses/bindings.
                                                        let
                                                            runPath =
                                                                runPathFor target.path
                                                        in
                                                        ( { m2
                                                            | planReadTarget =
                                                                Just
                                                                    { planId = target.planId
                                                                    , path = runPath
                                                                    , isResume = True
                                                                    , continueRun = False
                                                                    }
                                                          }
                                                        , Ports.fsReadFileText { path = runPath }
                                                        )

                                                    else
                                                        ( m2, Cmd.none )

                                                Err errs ->
                                                    -- Invalid plan file: report in
                                                    -- the Plans manager (not a window)
                                                    let
                                                        pm =
                                                            model.planManager
                                                    in
                                                    ( { model
                                                        | planReadTarget = Nothing
                                                        , planManager =
                                                            { pm
                                                                | show = True
                                                                , loading = False
                                                                , error = Just (String.join "\n" errs)
                                                            }
                                                      }
                                                    , Cmd.none
                                                    )

                                        else
                                            let
                                                pm =
                                                    model.planManager
                                            in
                                            ( { model
                                                | planReadTarget = Nothing
                                                , planManager =
                                                    { pm
                                                        | show = True
                                                        , loading = False
                                                        , error = Just error
                                                    }
                                              }
                                            , Cmd.none
                                            )

                                    Err _ ->
                                        ( { model | planReadTarget = Nothing }, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

        FsDeleteResult raw ->
            case D.decodeValue fsOkDecoder raw of
                Ok { ok, error } ->
                    if ok then
                        let
                            pm =
                                model.planManager
                        in
                        ( { model | planManager = { pm | error = Nothing } }
                        , refreshPlanList model
                        )

                    else
                        let
                            pm =
                                model.planManager
                        in
                        ( { model | planManager = { pm | error = Just error } }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        FsResolvePathResult result ->
            let
                pm =
                    model.planManager
            in
            if pm.show && pm.tab == PlanTabBrowse then
                -- Plans Browse tab: navigation happens in the import browser.
                case pm.browser of
                    Just fp ->
                        case D.decodeValue resolvePathResultDecoder result of
                            Ok rp ->
                                if rp.exists && rp.isDir then
                                    let
                                        sameDir =
                                            rp.resolved == fp.dir
                                    in
                                    ( { model
                                        | planManager =
                                            { pm
                                                | browser = Just { fp | dir = rp.resolved, selected = 0 }
                                            }
                                      }
                                    , if sameDir then
                                        Cmd.none
                                      else
                                        Ports.fsListDir { path = rp.resolved }
                                    )

                                else
                                    ( model, Cmd.none )

                            Err _ ->
                                ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

            else
                case getActiveSession model of
                    Just s ->
                        case D.decodeValue resolvePathResultDecoder result of
                            Ok rp ->
                                if rp.exists && rp.isDir then
                                    let
                                        fp =
                                            s.filePicker

                                        sameDir =
                                            rp.resolved == fp.dir
                                    in
                                    ( updateActiveSession model (\sess ->
                                        { sess
                                            | filePicker = { fp | dir = rp.resolved, selected = 0 }
                                        }
                                      )
                                    , if sameDir then
                                        Cmd.none
                                      else
                                        Ports.fsListDir { path = rp.resolved }
                                    )

                                else
                                    ( model, Cmd.none )

                            Err _ ->
                                ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

        -- Session Manager
        OpenSessionManager ->
            ( { model | showSessionManager = True, showGlobalMenu = False, sessionManagerError = Nothing }
            , Ports.listSessionDirs {}
            )

        CloseSessionManager ->
            ( { model | showSessionManager = False }
            , focusInput model
            )

        -- Plan Mode
        OpenPlanManager ->
            let
                pm =
                    model.planManager
            in
            ( { model
                | showGlobalMenu = False
                , planManager =
                    { pm
                        | show = True
                        , loading = True
                        , error = Nothing
                        , filter = ""
                        , tab = PlanTabSaved
                        , browser = Nothing
                    }
              }
            , if model.homeDir == "" then
                Ports.fsHomeDir {}

              else
                Ports.fsListDir { path = plansDir model.homeDir }
            )

        ClosePlanManager ->
            let
                pm =
                    model.planManager
            in
            ( { model
                | planManager =
                    { pm
                        | show = False
                        , filter = ""
                        , tab = PlanTabSaved
                        , browser = Nothing
                    }
              }
            , Cmd.none
            )

        PlanManagerOpen path ->
            openPlanFile path model

        PlanManagerDelete path ->
            ( model, Ports.fsDeleteFile { path = path } )

        PlanManagerSetFilter text ->
            let
                pm =
                    model.planManager
            in
            ( { model | planManager = { pm | filter = text } }
            , Cmd.none
            )

        PlanManagerSwitchTab tab ->
            let
                pm =
                    model.planManager
            in
            case tab of
                PlanTabSaved ->
                    ( { model | planManager = { pm | tab = PlanTabSaved, browser = Nothing } }
                    , refreshPlanList model
                    )

                PlanTabBrowse ->
                    case pm.browser of
                        Just _ ->
                            ( { model | planManager = { pm | tab = PlanTabBrowse } }
                            , Cmd.none
                            )

                        Nothing ->
                            if model.homeDir == "" then
                                ( { model
                                    | planManager =
                                        { pm | tab = PlanTabBrowse, browser = Just emptyPlanBrowser }
                                  }
                                , Ports.fsHomeDir {}
                                )

                            else
                                ( { model
                                    | planManager =
                                        { pm
                                            | tab = PlanTabBrowse
                                            , browser = Just (initPlanBrowser model.homeDir)
                                        }
                                  }
                                , Ports.fsListDir { path = model.homeDir }
                                )

        PlanManagerBrowserInput val ->
            let
                pm =
                    model.planManager
            in
            case pm.browser of
                Just fp ->
                    -- Input cleared → restore to current directory path
                    let
                        safeVal =
                            if val == "" then
                                "/"
                            else
                                val

                        ( needsResolve, resolvePath, filterText ) =
                            FP.parsePathInput safeVal fp.dir fp.baseDir

                        cmd =
                            if needsResolve then
                                Ports.fsResolvePath { path = resolvePath }
                            else
                                Cmd.none

                        previewFp =
                            { fp | input = safeVal, filter = filterText }

                        filteredLen =
                            List.length (FP.filterEntries previewFp)

                        clampedIdx =
                            if fp.selected >= filteredLen then
                                max 0 (filteredLen - 1)
                            else
                                fp.selected
                    in
                    ( { model
                        | planManager =
                            { pm
                                | browser =
                                    Just { fp | input = safeVal, filter = filterText, selected = clampedIdx }
                            }
                      }
                    , cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanManagerBrowserNavigate name ->
            let
                pm =
                    model.planManager
            in
            case pm.browser of
                Just fp ->
                    let
                        ( newFp, newDir ) =
                            FP.appendDirToInput fp name
                    in
                    ( { model | planManager = { pm | browser = Just newFp } }
                    , Ports.fsResolvePath { path = newDir }
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanManagerBrowserSelect idx ->
            let
                pm =
                    model.planManager

                scrollCmd =
                    case pm.browser of
                        Just fp ->
                            case List.head (List.drop idx (FP.filterEntries fp)) of
                                Just e ->
                                    Ports.scrollIntoView ("fp-item-plan-" ++ e.name)

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none
            in
            ( { model
                | planManager = { pm | browser = Maybe.map (\fp -> { fp | selected = idx }) pm.browser }
              }
            , scrollCmd
            )

        PlanManagerBrowserConfirm ->
            planBrowserPick model Nothing

        PlanManagerBrowserPick idx ->
            planBrowserPick model (Just idx)

        PlanOfferSettle sid planIndex ->
            -- Delayed auto-open confirmation: the plan window only
            -- auto-opens if this plan message is STILL the session's last
            -- message (a history replay feeding plan frames mid-session
            -- must not pop windows), and the binding is still absent (the
            -- planMetas index may have been rebuilt from disk since the
            -- detection ran — a replay of an already-bound plan must not
            -- create a duplicate).
            case Dict.get ( sid, planIndex ) model.pendingPlanOffers of
                Nothing ->
                    ( model, Cmd.none )

                Just _ ->
                    if messageBoundToPlan model sid planIndex then
                        -- Already bound (meta index caught up): drop the offer.
                        ( { model | pendingPlanOffers = Dict.remove ( sid, planIndex ) model.pendingPlanOffers }
                        , Cmd.none
                        )

                    else if isPlanMessageStillLast model sid planIndex then
                        update (PlanCreateOffer sid planIndex) model

                    else
                        -- A later message arrived (replay continues / the
                        -- user moved on): do NOT auto-open. The offer is
                        -- dropped; the user can open it from the status bar
                        -- if it ever got created.
                        ( { model | pendingPlanOffers = Dict.remove ( sid, planIndex ) model.pendingPlanOffers }
                        , Cmd.none
                        )

        PlanOpenFromMessage sid planIndex ->
            -- Manual open of a detected-but-suppressed plan message: find
            -- the raw plan JSON, queue it as an offer, and run the normal
            -- create flow (PlanCreateOffer consumes the offer).
            case findPlanMessageRaw model sid planIndex of
                Just raw ->
                    let
                        m1 =
                            { model | pendingPlanOffers = Dict.insert ( sid, planIndex ) raw model.pendingPlanOffers }
                    in
                    update (PlanCreateOffer sid planIndex) m1

                Nothing ->
                    ( model, Cmd.none )

        PlanCreateOffer sid planIndex ->
            case Dict.get ( sid, planIndex ) model.pendingPlanOffers of
                Just rawJson ->
                    let
                        -- consume the offer immediately (single-use)
                        model2 =
                            { model | pendingPlanOffers = Dict.remove ( sid, planIndex ) model.pendingPlanOffers }
                    in
                    case PT.parsePlan rawJson of
                        Ok plan ->
                            let
                                -- R3: record the origin session + plan index
                                -- so feedback can route results back and the
                                -- status bar can bind to this message. The
                                -- index is counted with the same predicate as
                                -- detection, so rendering can find it back
                                -- without relying on message ids.
                                origin =
                                    Just (PM.Origin sid planIndex Nothing)
                            in
                            ( model2
                            , Task.perform (PlanSaveReady plan origin) (Task.map Time.posixToMillis Time.now)
                            )

                        Err errs ->
                            -- R2: invalid detected plan — report inline in
                            -- the originating session (no window is created).
                            ( injectPlanErrorIntoSession errs sid model2, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PlanSaveReady plan maybeOrigin timestamp ->
            let
                planId =
                    PT.slugify plan.name ++ "-" ++ String.fromInt timestamp

                path =
                    plansDir model.homeDir ++ "/" ++ planId ++ ".json"

                content =
                    E.encode 2 (PT.encodePlan plan)

                win0 =
                    Dict.get planId model.planWindows
                        |> Maybe.withDefault emptyPlanWindow

                wv =
                    win0.view

                win1 =
                    { win0
                        | view =
                            { wv
                                | plan = Just plan
                                , path = Just path
                                , errors = []
                                , saving = True
                            }
                    }

                -- R3: write runtime metadata next to the plan file (origin
                -- binding + feedbacks); planMetas is kept in memory for the
                -- status bar and feedback routing.
                meta =
                    { origin = maybeOrigin
                    , feedbacks = []
                    , createdAt = timestamp
                    }

                metaPath =
                    PM.metaPathFor (plansDir model.homeDir) planId

                m1 =
                    { model
                        | planMetas = Dict.insert planId meta model.planMetas
                    }
            in
            ( addPlanWindow planId win1 m1
            , Cmd.batch
                [ Ports.fsWriteFileText { path = path, content = content, createParents = True }
                , Ports.fsWriteFileText { path = metaPath, content = E.encode 2 (PM.encodeMeta meta), createParents = True }
                ]
            )

        PlanStatusOpen planId ->
            -- The plan window is already open (auto-create) → focus it;
            -- otherwise (restart) open from disk like the manager does.
            if Dict.member planId model.planWindows then
                ( { model | planActiveId = Just planId, showGlobalMenu = False }
                , Cmd.none
                )

            else
                openPlanFile (plansDir model.homeDir ++ "/" ++ planId ++ ".json") model

        PlanActivate planId ->
            if model.planActiveId == Just planId then
                ( { model | showGlobalMenu = False }, Cmd.none )

            else
                let
                    newPositions =
                        Dict.update planId
                            (Maybe.map (\pos -> { pos | z = model.nextZIndex }))
                            model.windowPositions
                in
                ( { model
                    | planActiveId = Just planId
                    , windowPositions = newPositions
                    , nextZIndex = model.nextZIndex + 1
                    , showGlobalMenu = False
                    , nodeConnection = Nothing
                  }
                , Ports.setNodeConnection Nothing
                )

        PlanClose planId ->
            -- Drop queued creates for this plan too: their sessions would
            -- only be created and immediately orphan-closed.
            ( { model
                | planWindows = Dict.remove planId model.planWindows
                , planOrder = List.filter (\k -> k /= planId) model.planOrder
                , windowPositions = Dict.remove planId model.windowPositions
                , planCreateQueue =
                    List.filter
                        (\task ->
                            case task of
                                RunnerCreate qpid _ ->
                                    qpid /= planId

                                UserCreate _ ->
                                    True
                        )
                        model.planCreateQueue
                , planActiveId =
                    if model.planActiveId == Just planId then
                        List.head (List.reverse (List.filter (\k -> k /= planId) model.planOrder))

                    else
                        model.planActiveId
                , nodeConnection =
                    if (model.nodeConnection |> Maybe.map (\c -> c.planId)) == Just planId then
                        Nothing

                    else
                        model.nodeConnection
              }
            , if (model.nodeConnection |> Maybe.map (\c -> c.planId)) == Just planId then
                Ports.setNodeConnection Nothing

              else
                Cmd.none
            )

        -- ─── Plan runner ────────────────────────────────────────────

        PlanRunStart ->
            case getPlanWin model of
                Just win ->
                    case win.view.plan of
                        Just _ ->
                            case win.run of
                                Just run ->
                                    -- re-run only from a finished/stopped state
                                    if List.member run.status [ PT.Completed, PT.FailedRun, PT.Stopped, PT.NotStarted ] then
                                        ( model
                                        , Task.perform (\t -> PlanRunStartAt (Time.posixToMillis t)) Time.now
                                        )

                                    else
                                        ( model, Cmd.none )

                                Nothing ->
                                    ( model
                                    , Task.perform (\t -> PlanRunStartAt (Time.posixToMillis t)) Time.now
                                    )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PlanRunStartAt ts ->
            let
                m1 =
                    case ( model.planActiveId, getPlanWin model ) of
                        ( Just pid, Just win ) ->
                            case win.view.plan of
                                Just plan ->
                                    let
                                        -- Fresh run state on first Run; for a
                                        -- re-run keep the existing state (its
                                        -- node statuses are reset by StartRun).
                                        baseRun =
                                            Maybe.withDefault
                                                (PT.emptyRunState (PT.slugify plan.name ++ "-" ++ String.fromInt ts) plan)
                                                win.run

                                        -- Header concurrency override wins over
                                        -- the plan JSON (empty/invalid → plan).
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
                                    { model | planWindows = Dict.insert pid win2 model.planWindows }

                                Nothing ->
                                    model

                        _ ->
                            model
            in
            case model.planActiveId of
                Just pid ->
                    runStepIn pid ts R.StartRun m1

                Nothing ->
                    ( model, Cmd.none )

        PlanRunPause ->
            case model.planActiveId of
                Just pid ->
                    runStepIn pid 0 R.PauseRun model

                Nothing ->
                    ( model, Cmd.none )

        PlanRunResume ->
            case model.planActiveId of
                Just pid ->
                    runStepIn pid 0 R.ResumeRun model

                Nothing ->
                    ( model, Cmd.none )

        PlanRunRestart planId ->
            -- R4 (D9): skip succeeded nodes; reset the rest and cascade
            -- to sub-plans of waiting (delegated) nodes.
            restartPlanCascade planId model

        PlanRunStop ->
            case model.planActiveId of
                Just pid ->
                    let
                        ( m1, c1 ) =
                            runStepIn pid 0 R.StopRun model
                    in
                    -- Cancel queued creates for this plan: their nodes are
                    -- Canceled now, so creating the sessions would only
                    -- produce orphans (closed right after by PlanBindSession).
                    ( { m1
                        | planCreateQueue =
                            List.filter
                                (\task ->
                                    case task of
                                        RunnerCreate qpid _ ->
                                            qpid /= pid

                                        UserCreate _ ->
                                            True
                                )
                                m1.planCreateQueue
                      }
                    , c1
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanRunRetryNode nodeId ->
            case model.planActiveId of
                Just pid ->
                    runStepIn pid 0 (R.RetryNode nodeId) model

                Nothing ->
                    ( model, Cmd.none )

        PlanRunnerTick planId nodeId ->
            runStepIn planId 0 (R.RetryTick nodeId) model

        PlanRunFrame ts ev ->
            case eventSessionId ev of
                Just sid ->
                    case findPlanIdBySession model sid of
                        Just pid ->
                            runStepIn pid ts ev model

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PlanBindSession ts planId nodeId sid ->
            let
                m0 =
                    { model | planCreating = Nothing }

                ( m1, c1 ) =
                    runStepIn planId ts (R.SessionCreatedFor nodeId sid) m0

                ( m2, c2 ) =
                    startNextCreateIn m1

                -- Keep the node→session binding visible: the session bar
                -- shows "[Plan · planId/nodeId]".
                m3 =
                    { m2
                        | planNodeSessions =
                            Dict.insert sid (planId ++ "/" ++ nodeId) m2.planNodeSessions
                    }

                -- Orphan cleanup: if the bind did NOT take (node no longer
                -- Starting — e.g. Stop/close raced the create, or the plan
                -- window is gone), the just-created session is unwanted:
                -- close its window and process.
                ( m4, c3 ) =
                    case Dict.get planId m3.planWindows of
                        Just win ->
                            case win.run of
                                Just run ->
                                    case Dict.get nodeId run.nodes of
                                        Just n ->
                                            if n.status == PT.Running && n.sessionId == Just sid then
                                                ( m3, Cmd.none )

                                            else
                                                update (CloseSession sid) m3

                                        Nothing ->
                                            update (CloseSession sid) m3

                                Nothing ->
                                    update (CloseSession sid) m3

                        Nothing ->
                            update (CloseSession sid) m3
            in
            ( m4, Cmd.batch [ c1, c2, c3 ] )

        PlanResume ->
            case ( model.planActiveId, getPlanWin model ) of
                ( Just pid, Just win ) ->
                    case win.view.path of
                        Just planPath ->
                            let
                                runPath =
                                    runPathFor planPath

                                win1 =
                                    { win | resumePath = Just runPath }
                            in
                            ( { model
                                | planWindows = Dict.insert pid win1 model.planWindows
                                , planReadTarget =
                                    Just
                                        { planId = pid
                                        , path = runPath
                                        , isResume = True
                                        , continueRun = True
                                        }
                              }
                            , Ports.fsReadFileText { path = runPath }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        PlanSelectNode nodeId ->
            ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId })
            , Cmd.none
            )

        PlanOpenNodeSession planId nodeId ->
            -- Node → session binding: click a node to open its session.
            -- Priority: live sessionId (focus it) → live session resumed
            -- from the same dir (focus it) → resume from disk → detail.
            case Dict.get planId model.planWindows of
                Just win ->
                    case win.run of
                        Just run ->
                            case Dict.get nodeId run.nodes of
                                Just n ->
                                    case n.sessionId of
                                        Just sid ->
                                            if Dict.member sid model.sessions then
                                                update (ActivateSession sid) model

                                            else
                                                case findResumedLive sid model of
                                                    Just liveId ->
                                                        update (ActivateSession liveId) model

                                                    Nothing ->
                                                        -- dead live-binding
                                                        -- (e.g. restart):
                                                        -- resume from disk.
                                                        -- The node STAYS
                                                        -- bound to sid (the
                                                        -- dir name); the
                                                        -- resumed window gets
                                                        -- a fresh id tracked
                                                        -- via planResumedFrom.
                                                        ( { model
                                                            | pendingSwitchOnCreate = True
                                                            , planResumeOwner = Just planId
                                                            , planResumeFrom = Just sid
                                                            , planNodeSessions =
                                                                Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                                                          }
                                                        , Ports.resumeSession { sessionId = sid, workDir = planWorkDir planId model }
                                                        )

                                        Nothing ->
                                            case n.lastSessionId of
                                                Just sid ->
                                                    -- failed/canceled node:
                                                    -- its session was closed,
                                                    -- reopen it from disk
                                                    if Dict.member sid model.sessions then
                                                        update (ActivateSession sid) model

                                                    else
                                                        case findResumedLive sid model of
                                                            Just liveId ->
                                                                update (ActivateSession liveId) model

                                                            Nothing ->
                                                                ( { model
                                                                    | pendingSwitchOnCreate = True
                                                                    , planResumeOwner = Just planId
                                                                    , planResumeFrom = Just sid
                                                                    , planNodeSessions =
                                                                        Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                                                                  }
                                                                , Ports.resumeSession { sessionId = sid, workDir = planWorkDir planId model }
                                                                )

                                                Nothing ->
                                                    ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId })
                                                    , Cmd.none
                                                    )

                                Nothing ->
                                    ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId })
                                    , Cmd.none
                                    )

                        Nothing ->
                            ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId })
                            , Cmd.none
                            )

                Nothing ->
                    ( model, Cmd.none )

        PlanOpenAttemptSession planId nodeId sid ->
            -- Open a HISTORICAL attempt session (from the node's
            -- attemptSessions list): focus it if alive, otherwise resume
            -- it from disk. Never rebinds the node — the current live
            -- binding (if any) stays untouched.
            if Dict.member sid model.sessions then
                update (ActivateSession sid) model

            else
                case findResumedLive sid model of
                    Just liveId ->
                        update (ActivateSession liveId) model

                    Nothing ->
                        ( { model
                            | pendingSwitchOnCreate = True
                            , planResumeOwner = Just planId
                            , planResumeFrom = Just sid
                            , planNodeSessions =
                                Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                          }
                        , Ports.resumeSession { sessionId = sid, workDir = planWorkDir planId model }
                        )

        PlanSetConcurrency text ->
            ( updateActivePlanWin model
                (\w ->
                    let
                        wv =
                            w.view
                    in
                    { w | view = { wv | concurrencyInput = text } }
                )
            , Cmd.none
            )

        PlanSetExportPath text ->
            ( updateActivePlanWin model
                (\w ->
                    let
                        wv =
                            w.view
                    in
                    { w | view = { wv | exportPath = text } }
                )
            , Cmd.none
            )

        PlanExport ->
            case getPlanWin model of
                Just win ->
                    case win.view.plan of
                        Just plan ->
                            let
                                path =
                                    String.trim win.view.exportPath
                            in
                            if path == "" then
                                ( updateActivePlanWin model
                                    (\w ->
                                        let
                                            wv =
                                                w.view
                                        in
                                        { w | view = { wv | errors = [ "Enter an export path" ] } }
                                    )
                                , Cmd.none
                                )

                            else
                                ( model
                                , Ports.fsWriteFileText
                                    { path = path
                                    , content = E.encode 2 (PT.encodePlan plan)
                                    , createParents = True
                                    }
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ToggleGlobalMenu ->
            ( { model | showGlobalMenu = not model.showGlobalMenu }, Cmd.none )

        CloseGlobalMenu ->
            ( { model | showGlobalMenu = False }, Cmd.none )

        SessionDirsResult dirs ->
            ( { model | sessionDirs = dirs }, Cmd.none )

        SessionActionResult raw ->
            case D.decodeValue sessionActionResultDecoder raw of
                Ok res ->
                    if res.ok && res.kind == "resume" then
                        -- Resume succeeded: reveal the resumed session
                        ( { model
                            | showSessionManager = False
                            , sessionManagerError = Nothing
                            , planResumeOwner = Nothing
                            , planResumeFrom = Nothing
                          }
                        , Cmd.none
                        )

                    else if res.ok then
                        ( { model | sessionManagerError = Nothing }, Cmd.none )

                    else
                        -- A plan-node session resume failed: surface the
                        -- error in the owning plan window instead of the
                        -- (possibly closed) session manager. Also clear
                        -- planResumeFrom so a later SessionCreated does
                        -- not treat some unrelated session as the resume.
                        case model.planResumeOwner of
                            Just pid ->
                                ( setPlanWin pid
                                    (\w ->
                                        let
                                            wv =
                                                w.view
                                        in
                                        { w | view = { wv | errors = [ res.error ] } }
                                    )
                                    { model | planResumeOwner = Nothing, planResumeFrom = Nothing }
                                , Cmd.none
                                )

                            Nothing ->
                                ( { model | sessionManagerError = Just res.error }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        ResumeSession id ->
            -- pendingSwitchOnCreate makes SessionCreated switch to the
            -- resumed session once it appears (mirrors the original UX).
            ( { model | pendingSwitchOnCreate = True, sessionManagerError = Nothing }
            , Ports.resumeSession { sessionId = id, workDir = Nothing }
            )

        DeleteSession id ->
            let
                -- If the deleted dir belongs to a running session, drop
                -- its window too (delete_session_dir closes the process).
                cleaned =
                    if Dict.member id model.sessions then
                        { model
                            | sessions = Dict.remove id model.sessions
                            , sessionOrder = List.filter (\k -> k /= id) model.sessionOrder
                            , sessionNums = Dict.remove id model.sessionNums
                            , windowPositions = Dict.remove id model.windowPositions
                            , planNodeSessions = Dict.remove id model.planNodeSessions
                            , planResumedFrom = Dict.remove id model.planResumedFrom
                            , nodeConnection =
                                if (model.nodeConnection |> Maybe.map (\c -> c.sessionId)) == Just id then
                                    Nothing

                                else
                                    model.nodeConnection
                            , activeId =
                                if model.activeId == Just id then
                                    List.head (List.reverse (List.filter (\k -> k /= id) model.sessionOrder))
                                else
                                    model.activeId
                        }
                    else
                        model
            in
            ( { cleaned | sessionManagerError = Nothing }
            , Cmd.batch
                [ Ports.deleteSessionDir { sessionId = id }
                , if (model.nodeConnection |> Maybe.map (\c -> c.sessionId)) == Just id then
                    Ports.setNodeConnection Nothing

                  else
                    Cmd.none
                ]
            )

        -- Window
        WindowMaximized v ->
            ( { model | isMaximized = v }, Cmd.none )

        GotContainerSize result ->
            case result of
                Ok el ->
                    ( { model
                        | appWidth = round el.element.width
                        , appHeight = round el.element.height
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( model, Cmd.none )

        RequerySize ->
            ( model, Task.attempt GotContainerSize (Dom.getElement "main-content") )

        -- Model Selector (per-session)
        OpenModelSelector ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | showModelSelector = True, modelSelector = Sel.open sess.models sess.modelSelector })
                    , Cmd.batch
                        [ focusAfterDelay ("model-selector-input-" ++ s.id)
                        , Ports.setCursorPos ("model-selector-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseModelSelector ->
            case getActiveSession model of
                Just s ->
                    case Sel.closeRequest s.modelSelector of
                        Nothing ->
                            -- Sync in flight: do not allow closing
                            ( model, Cmd.none )

                        Just True ->
                            -- Unsaved edits: ask before closing
                            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.askSync sess.modelSelector })
                            , Cmd.none
                            )

                        Just False ->
                            ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
                            , focusInput model
                            )

                Nothing ->
                    ( model, Cmd.none )

        SetModelSelectorInput val ->
            Kit.setInput sessionModelKit val model

        ModelSelectorSelectItem idx ->
            Kit.selectItem sessionModelKit idx model

        ModelSelectorConfirmItem ->
            Kit.confirmItem sessionModelKit model

        ModelSelectorEditModel id ->
            Kit.editItem sessionModelKit id model

        ModelSelectorAddModel ->
            Kit.addItem sessionModelKit model

        ModelSelectorEditBack ->
            Kit.editBack sessionModelKit model

        ModelSelectorEditSave ->
            Kit.editSave sessionModelKit model

        ModelSelectorEditField field value ->
            Kit.editField sessionModelKit field value model

        ModelSelectorDeleteModel id ->
            Kit.deleteItem sessionModelKit id model

        ModelSelectorConfirmDelete id ->
            Kit.confirmDelete sessionModelKit id model

        ModelSelectorCancelDelete ->
            Kit.cancelDelete sessionModelKit model

        ModelSelectorConfirmSync ->
            Kit.confirmSync sessionModelKit model

        ModelSelectorDiscardClose ->
            Kit.discardClose sessionModelKit model

        ModelSelectorCancelSyncPrompt ->
            Kit.cancelSyncPrompt sessionModelKit model

        ModelSelectorSyncResult isError message ->
            case getActiveSession model of
                Just s ->
                    if s.modelSelector.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if isError then
                        Kit.syncFailed sessionModelKit message model

                    else
                        Kit.syncSuccess sessionModelKit model

                Nothing ->
                    ( model, Cmd.none )

        -- Default (global) Model List Editor (targets a specific preset)
        EditPresetModels preset ->
            ( { model
                | defaultModelsEditor =
                    { emptyDefaultModelsEditor
                        | show = True
                        , preset = preset
                        , state = Sel.setLoading Sel.empty
                    }
                , showGlobalMenu = False
              }
            , Ports.listDefaultModels { preset = preset }
            )

        CloseDefaultModelsEditor ->
            let
                ed =
                    model.defaultModelsEditor
            in
            case Sel.closeRequest ed.state of
                Nothing ->
                    -- Sync in flight: do not allow closing
                    ( model, Cmd.none )

                Just True ->
                    -- Unsaved edits: ask before closing
                    ( { model | defaultModelsEditor = { ed | state = Sel.askSync ed.state } }
                    , Cmd.none
                    )

                Just False ->
                    ( { model | defaultModelsEditor = emptyDefaultModelsEditor }
                    , Cmd.none
                    )

        DefaultModelsListResult raw ->
            case D.decodeValue defaultModelsListResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.defaultModelsEditor
                    in
                    if res.ok then
                        ( { model
                            | defaultModelsEditor =
                                { ed | state = Sel.setList res.models ed.state }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "model-selector-input-default"
                            , Ports.setCursorPos "model-selector-input-default"
                            ]
                        )

                    else
                        ( { model
                            | defaultModelsEditor =
                                { ed | state = Sel.setLoadError (Just res.error) ed.state }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SetDefaultModelsInput val ->
            Kit.setInput defaultModelsKit val model

        DefaultModelsSelectItem idx ->
            Kit.selectItem defaultModelsKit idx model

        DefaultModelsConfirmItem ->
            Kit.confirmItem defaultModelsKit model

        DefaultModelsEditModel id ->
            Kit.editItem defaultModelsKit id model

        DefaultModelsAddModel ->
            Kit.addItem defaultModelsKit model

        DefaultModelsEditBack ->
            Kit.editBack defaultModelsKit model

        DefaultModelsEditSave ->
            Kit.editSave defaultModelsKit model

        DefaultModelsEditField field value ->
            Kit.editField defaultModelsKit field value model

        DefaultModelsDeleteModel id ->
            Kit.deleteItem defaultModelsKit id model

        DefaultModelsConfirmDelete id ->
            Kit.confirmDelete defaultModelsKit id model

        DefaultModelsCancelDelete ->
            Kit.cancelDelete defaultModelsKit model

        DefaultModelsConfirmSync ->
            Kit.confirmSync defaultModelsKit model

        DefaultModelsDiscardClose ->
            Kit.discardClose defaultModelsKit model

        DefaultModelsCancelSyncPrompt ->
            Kit.cancelSyncPrompt defaultModelsKit model

        DefaultModelsSyncResult raw ->
            case D.decodeValue defaultModelsSyncResultDecoder raw of
                Ok res ->
                    if model.defaultModelsEditor.state.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if res.ok then
                        Kit.syncSuccess defaultModelsKit model

                    else
                        Kit.syncFailed defaultModelsKit res.error model

                Err _ ->
                    ( model, Cmd.none )

        EditPresetMcp preset ->
            ( { model
                | mcpEditor =
                    { emptyMcpEditor
                        | show = True
                        , preset = preset
                        , state = Sel.setLoading Sel.empty
                    }
                , showGlobalMenu = False
              }
            , Ports.listDefaultMcp { preset = preset }
            )

        CloseMcpEditor ->
            let
                ed =
                    model.mcpEditor
            in
            case Sel.closeRequest ed.state of
                Nothing ->
                    -- Sync in flight: do not allow closing
                    ( model, Cmd.none )

                Just True ->
                    -- Unsaved edits: ask before closing
                    ( { model | mcpEditor = { ed | state = Sel.askSync ed.state } }
                    , Cmd.none
                    )

                Just False ->
                    ( { model | mcpEditor = emptyMcpEditor }
                    , Cmd.none
                    )

        McpListResult raw ->
            case D.decodeValue mcpListResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.mcpEditor

                        -- mcp.conf has no id field; assign stable unique ids here
                        servers =
                            List.indexedMap (\i s -> { s | id = i + 1 }) res.servers
                    in
                    if res.ok then
                        ( { model
                            | mcpEditor =
                                { ed | state = Sel.setList servers ed.state }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "mcp-selector-input-default"
                            , Ports.setCursorPos "mcp-selector-input-default"
                            ]
                        )

                    else
                        ( { model
                            | mcpEditor =
                                { ed | state = Sel.setLoadError (Just res.error) ed.state }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SetMcpInput val ->
            Kit.setInput mcpKit val model

        McpSelectItem idx ->
            Kit.selectItem mcpKit idx model

        McpConfirmItem ->
            Kit.confirmItem mcpKit model

        McpEditServer id ->
            Kit.editItem mcpKit id model

        McpAddServer ->
            Kit.addItem mcpKit model

        McpEditBack ->
            Kit.editBack mcpKit model

        McpEditSave ->
            Kit.editSave mcpKit model

        McpEditField field value ->
            Kit.editField mcpKit field value model

        McpDeleteServer id ->
            Kit.deleteItem mcpKit id model

        McpConfirmDelete id ->
            Kit.confirmDelete mcpKit id model

        McpCancelDelete ->
            Kit.cancelDelete mcpKit model

        McpConfirmSync ->
            Kit.confirmSync mcpKit model

        McpDiscardClose ->
            Kit.discardClose mcpKit model

        McpCancelSyncPrompt ->
            Kit.cancelSyncPrompt mcpKit model

        McpSyncResult raw ->
            case D.decodeValue mcpSyncResultDecoder raw of
                Ok res ->
                    if model.mcpEditor.state.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if res.ok then
                        Kit.syncSuccess mcpKit model

                    else
                        Kit.syncFailed mcpKit res.error model

                Err _ ->
                    ( model, Cmd.none )

        -- Global Settings (targets a specific preset)
        EditPresetSettings preset ->
            ( { model
                | settingsEditor =
                    { emptySettingsEditor
                        | show = True
                        , loading = True
                        , preset = preset
                    }
                , showGlobalMenu = False
              }
            , Ports.listGlobalSettings { preset = preset }
            )

        CloseSettingsEditor ->
            let
                ed =
                    model.settingsEditor
            in
            if ed.syncing then
                -- Do not allow closing while a sync is in flight
                ( model, Cmd.none )

            else
                ( { model | settingsEditor = emptySettingsEditor }
                , Cmd.none
                )

        SetToolConfirm val ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor =
                    { ed
                        | toolConfirm = val
                        , error = Nothing
                    }
              }
            , Cmd.none
            )

        SetBuiltinTools val ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor =
                    { ed
                        | builtinTools = val
                        , error = Nothing
                    }
              }
            , Cmd.none
            )

        SettingsSave ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor = { ed | syncing = True, error = Nothing }
              }
            , Ports.syncGlobalSettings
                { preset = ed.preset
                , toolConfirm = ed.toolConfirm
                , builtinTools = ed.builtinTools
                }
            )

        SettingsListResult raw ->
            case D.decodeValue settingsListResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.settingsEditor
                    in
                    if res.ok then
                        ( { model
                            | settingsEditor =
                                { ed
                                    | loading = False
                                    , toolConfirm = res.toolConfirm
                                    , builtinTools = res.builtinTools
                                    , error = Nothing
                                }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "settings-tool-confirm"
                            , Ports.setCursorPos "settings-tool-confirm"
                            ]
                        )

                    else
                        ( { model
                            | settingsEditor =
                                { ed
                                    | loading = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SettingsSyncResult raw ->
            case D.decodeValue settingsSyncResultDecoder raw of
                Ok res ->
                    if res.ok then
                        ( { model | settingsEditor = emptySettingsEditor }
                        , Cmd.none
                        )

                    else
                        let
                            ed =
                                model.settingsEditor
                        in
                        ( { model
                            | settingsEditor =
                                { ed
                                    | syncing = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        -- Presets
        OpenPresetManager ->
            ( { model
                | presetManager =
                    { emptyPresetManager
                        | show = True
                        , loading = True
                    }
                , showGlobalMenu = False
              }
            , Ports.listPresets {}
            )

        ClosePresetManager ->
            let
                pm =
                    model.presetManager
            in
            if pm.busy then
                -- Do not allow closing while an action is in flight
                ( model, Cmd.none )

            else
                ( { model | presetManager = emptyPresetManager }
                , Cmd.none
                )

        PresetCopy source ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing }
              }
            , Ports.copyPreset
                { source = source
                , name = nextCopyName source model.presets
                }
            )

        PresetSetActive name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing }
              }
            , Ports.setActivePreset { name = name }
            )

        PresetRenameStart name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | renaming = Just name, renameInput = name }
              }
            , Cmd.none
            )

        SetPresetRenameInput val ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | renameInput = val, error = Nothing }
              }
            , Cmd.none
            )

        PresetRenameSave oldName ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing }
              }
            , Ports.renamePreset { oldName = oldName, newName = pm.renameInput }
            )

        PresetRenameCancel ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | renaming = Nothing, renameInput = "" }
              }
            , Cmd.none
            )

        PresetToggleEdit name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager =
                    { pm
                        | editing =
                            if pm.editing == Just name then
                                Nothing
                            else
                                Just name
                    }
              }
            , Cmd.none
            )

        PresetDelete name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | confirmDelete = Just name }
              }
            , Cmd.none
            )

        PresetConfirmDelete name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing, confirmDelete = Nothing }
              }
            , Ports.deletePreset { name = name }
            )

        PresetCancelDelete ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | confirmDelete = Nothing }
              }
            , Cmd.none
            )

        PresetsListResult raw ->
            case D.decodeValue presetsListResultDecoder raw of
                Ok res ->
                    if res.ok then
                        let
                            pm =
                                model.presetManager

                            active =
                                List.filterMap
                                    (\p -> if p.isActive then Just p.name else Nothing)
                                    res.presets
                                    |> List.head
                                    |> Maybe.withDefault ""
                        in
                        ( { model
                            | presets = res.presets
                            , activePreset = active
                            , presetManager = { pm | loading = False, error = Nothing }
                          }
                        , Cmd.none
                        )

                    else
                        let
                            pm =
                                model.presetManager
                        in
                        ( { model
                            | presetManager = { pm | loading = False, error = Just res.error }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        PresetActionResult raw ->
            case D.decodeValue presetActionResultDecoder raw of
                Ok res ->
                    let
                        pm =
                            model.presetManager
                    in
                    if res.ok then
                        ( { model
                            | presetManager =
                                { pm
                                    | busy = False
                                    , renaming = Nothing
                                    , renameInput = ""
                                    , confirmDelete = Nothing
                                }
                          }
                        , Ports.listPresets {}
                        )

                    else
                        ( { model
                            | presetManager = { pm | busy = False, error = Just res.error }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        -- Help Window
        OpenHelpWindow ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        { sess
                            | showHelpWindow = True
                            , helpFilter = ""
                            , helpSelected = 0
                            , helpScroll = 0
                        }
                      )
                    , Cmd.batch
                        [ focusAfterDelay ("help-filter-input-" ++ s.id)
                        , Ports.setCursorPos ("help-filter-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseHelpWindow ->
            ( updateActiveSession model (\s -> { s | showHelpWindow = False })
            , focusInput model
            )

        SetHelpFilter val ->
            ( updateActiveSession model (\s ->
                let
                    filtered =
                        filterHelpItems val helpItems

                    clampedSelected =
                        if List.length filtered <= s.helpSelected then
                            max 0 (List.length filtered - 1)
                        else
                            s.helpSelected
                in
                { s
                    | helpFilter = val
                    , helpSelected = clampedSelected
                }
              )
            , Cmd.none
            )

        HelpSelectItem idx ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | helpSelected = idx })
                    , Ports.scrollIntoView ("help-item-" ++ s.id ++ "-" ++ String.fromInt idx)
                    )

                Nothing ->
                    ( model, Cmd.none )

        HelpCmdMsg cmd ->
            case model.activeId of
                Just sid ->
                    let
                        -- Focus input and insert the command prefix
                        newSessions =
                            Dict.update sid
                                (\maybeS ->
                                    case maybeS of
                                        Just s ->
                                            Just
                                                { s
                                                    | showHelpWindow = False
                                                    , input = cmd ++ " "
                                                }

                                        Nothing ->
                                            maybeS
                                )
                                model.sessions
                    in
                    ( { model | sessions = newSessions }
                    , Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ sid))
                    )

                Nothing ->
                    ( model, Cmd.none )

        FillMcpAuthUrl server url ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        { sess | mcpAuthRunning = Just server }
                      )
                    , Ports.fillMcpAuthUrl
                        { sessionId = s.id
                        , serverName = server
                        , authUrl = url
                        }
                    )

                Nothing ->
                    ( model, Cmd.none )

        OpenMediaPreview item ->
            ( updateActiveSession model (\sess -> { sess | mediaPreview = Just item })
            , Cmd.none
            )

        CloseMediaPreview ->
            ( updateActiveSession model (\sess -> { sess | mediaPreview = Nothing })
            , Cmd.none
            )

        ScrollPosition sid scrollTop scrollHeight clientHeight ->
            let
                atBottom =
                    scrollTop + clientHeight >= scrollHeight - 5
            in
            ( updateSession model sid (\s -> { s | atBottom = atBottom })
            , Cmd.none
            )

        KeyDown key ctrl alt defaultPrevented ->
            -- If another handler already processed this key (e.g. textarea), skip
            if defaultPrevented then
                ( model, Cmd.none )

            -- Escape or Ctrl+[ dismisses the context menu and the media
            -- preview. Other overlays are closed via their close buttons
            -- only (no Escape).
            else if key == "Escape" || (key == "[" && ctrl) then
                if model.ctxVisible then
                    ( { model | ctxVisible = False }, Cmd.none )

                else
                    ( updateActiveSession model (\sess -> { sess | mediaPreview = Nothing })
                    , Cmd.none
                    )

            -- Ctrl+W closes the active session window; with no active
            -- session it closes the active plan window instead
            else if key == "w" && ctrl then
                case model.activeId of
                    Just sid ->
                        update (CloseSession sid) model

                    Nothing ->
                        case model.planActiveId of
                            Just pid ->
                                update (PlanClose pid) model

                            Nothing ->
                                ( model, Cmd.none )

            else
                ( model, Cmd.none )

        ForSession sid innerMsg ->
            update innerMsg { model | activeId = Just sid }

        ResizeStart id handle mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    ( { model
                        | resizeInfo =
                            Just
                                { sessionId = id
                                , handle = handle
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                , startWinW = pos.w
                                , startWinH = pos.h
                                }
                        , windowPositions = Dict.insert id { pos | z = model.nextZIndex } model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        , activeId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanResizeStart id handle mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    ( { model
                        | resizeInfo =
                            Just
                                { sessionId = id
                                , handle = handle
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                , startWinW = pos.w
                                , startWinH = pos.h
                                }
                        , windowPositions = Dict.insert id { pos | z = model.nextZIndex } model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        , planActiveId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        WindowDragStart id mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    ( { model
                        | dragInfo =
                            Just
                                { sessionId = id
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                }
                        , windowPositions = Dict.insert id { pos | z = model.nextZIndex } model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        , activeId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanWindowDragStart id mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    ( { model
                        | dragInfo =
                            Just
                                { sessionId = id
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                }
                        , windowPositions = Dict.insert id { pos | z = model.nextZIndex } model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        , planActiveId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        WindowDragMove mouseX mouseY ->
            case model.dragInfo of
                Just info ->
                    let
                        dx =
                            round mouseX - round info.startMouseX

                        dy =
                            round mouseY - round info.startMouseY

                        newRawX =
                            info.startWinX + dx

                        newRawY =
                            info.startWinY + dy

                        -- Look up current window size for right/bottom clamping
                        winSize =
                            Dict.get info.sessionId model.windowPositions

                        winW =
                            Maybe.map .w winSize |> Maybe.withDefault defaultWinW

                        winH =
                            Maybe.map .h winSize |> Maybe.withDefault defaultWinH

                        maxX =
                            max 0 (model.appWidth - winW)

                        maxY =
                            max 0 (model.appHeight - winH)

                        newX =
                            clamp 0 maxX newRawX

                        newY =
                            clamp 0 maxY newRawY
                    in
                    ( { model
                        | windowPositions =
                            Dict.update info.sessionId
                                (Maybe.map (\pos -> { pos | x = newX, y = newY }))
                                model.windowPositions
                      }
                    , Cmd.none
                    )

                Nothing ->
                    handleResizeMove model mouseX mouseY

        WindowDragEnd ->
            ( { model | dragInfo = Nothing, resizeInfo = Nothing }, Cmd.none )

        ActivateSession id ->
            if model.activeId == Just id then
                -- Already focused: (re)assert the connection — it may have
                -- been cleared by focusing the plan window in between.
                let
                    conn =
                        connectionForSession id model
                in
                ( { model | nodeConnection = conn }
                , Ports.setNodeConnection conn
                )

            else
                activateSessionModel model id

        NoOp ->
            ( model, Cmd.none )


-- ─── Helpers ──────────────────────────────────────────────────────────

updateAfterConfirm : Model -> String -> Model
updateAfterConfirm model sid =
    case Dict.get sid model.sessions of
        Just s ->
            let
                newQueue =
                    case s.pendingConfirm of
                        [] -> []
                        _ :: rest -> rest
            in
            { model | sessions = Dict.insert sid { s | pendingConfirm = newQueue } model.sessions }

        Nothing ->
            model


handleResizeMove : Model -> Float -> Float -> ( Model, Cmd Msg )
handleResizeMove model mouseX mouseY =
    case model.resizeInfo of
        Just info ->
            let
                dx =
                    round mouseX - round info.startMouseX

                dy =
                    round mouseY - round info.startMouseY
            in
            let
                config =
                    { handle = info.handle
                    , dx = dx
                    , dy = dy
                    , startX = info.startWinX
                    , startY = info.startWinY
                    , startW = info.startWinW
                    , startH = info.startWinH
                    , minW = minWinW
                    , minH = minWinH
                    }

                r =
                    resizeDimensions config

                -- Clamp so window stays within viewport
                clampedX =
                    max 0 (min (max 0 (model.appWidth - r.w)) r.x)

                clampedY =
                    max 0 (min (max 0 (model.appHeight - r.h)) r.y)

                -- If x/y was clamped, adjust w/h so right/bottom edge stays put
                adjustW =
                    if clampedX /= r.x then
                        r.w + (r.x - clampedX)
                    else
                        r.w

                adjustH =
                    if clampedY /= r.y then
                        r.h + (r.y - clampedY)
                    else
                        r.h

                finalW =
                    max minWinW adjustW

                finalH =
                    max minWinH adjustH
            in
            ( { model
                | windowPositions =
                    Dict.update info.sessionId
                        (Maybe.map (\pos -> { pos | x = clampedX, y = clampedY, w = finalW, h = finalH }))
                        model.windowPositions
              }
            , Cmd.none
            )

        Nothing ->
            ( model, Cmd.none )


-- Apply a buffered transport event to the sessions dict.
-- Returns the updated sessions dict unchanged if the event can't be decoded or session not found.
applyPendingEvent : E.Value -> Dict String T.SessionState -> Dict String T.SessionState
applyPendingEvent raw sessions =
    -- Try FrameEvent first (most common for initial messages)
    case D.decodeValue P.frameEventDecoder raw of
        Ok ev ->
            case Dict.get ev.sessionId sessions of
                Just session ->
                    Dict.insert ev.sessionId (H.handleFrameEvent session ev) sessions

                Nothing ->
                    sessions

        Err _ ->
            -- Try DeltaEvent
            case D.decodeValue P.deltaEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId sessions of
                        Just session ->
                            Dict.insert ev.sessionId (H.handleDeltaEvent session ev) sessions

                        Nothing ->
                            sessions

                Err _ ->
                    -- Try StatusEvent
                    case D.decodeValue P.statusEventDecoder raw of
                        Ok ev ->
                            case Dict.get ev.sessionId sessions of
                                Just session ->
                                    Dict.insert ev.sessionId
                                        { session
                                            | connected = ev.connected
                                            , statusMsg = ev.message
                                        }
                                        sessions

                                Nothing ->
                                    sessions

                        Err _ ->
                            sessions


type alias SessionDir =
    { id : String
    , hasSessionFile : Bool
    , createdAt : String
    }


sessionDirDecoder : D.Decoder SessionDir
sessionDirDecoder =
    D.map3 SessionDir
        (D.field "id" D.string)
        (D.field "has_session_file" D.bool)
        (D.field "created_at" D.string)


decodeSessionDir : E.Value -> Maybe SessionDir
decodeSessionDir val =
    case D.decodeValue sessionDirDecoder val of
        Ok dir -> Just dir
        Err _ -> Nothing


-- File Picker Helpers

type alias ResolvedPathResult =
    { resolved : String
    , exists : Bool
    , isDir : Bool
    }


resolvePathResultDecoder : D.Decoder ResolvedPathResult
resolvePathResultDecoder =
    D.map3 ResolvedPathResult
        (D.field "resolved" D.string)
        (D.field "exists" D.bool)
        (D.field "isDir" D.bool)


-- ─── Selector Search Keys ────────────────────────────────────────────
-- Passed to Session.Selector.filterItems (and the overlay list view)
-- to fuzzy-match the selector's search input.

modelName : T.ModelInfo -> String
modelName m =
    m.name


mcpServerName : T.McpInfo -> String
mcpServerName s =
    s.server


draftFromMcp : T.McpInfo -> T.McpDraft
draftFromMcp s =
    { id = s.id
    , type_ = s.type_
    , server = s.server
    , url = s.url
    , command = s.command
    , args = s.args
    , env = s.env
    , authType = s.authType
    , authToken = s.authToken
    , authClientId = s.authClientId
    , authClientSecret = s.authClientSecret
    , protoVersion =
        -- Old configs may lack proto-version; default it to the latest so
        -- the dropdown shows the real value instead of silently selecting
        -- the first option while the draft stays empty.
        if String.isEmpty (String.trim s.protoVersion) then
            T.latestMcpProtoVersion

        else
            s.protoVersion
    }


mcpFromDraft : T.McpDraft -> T.McpInfo
mcpFromDraft d =
    { id = d.id
    , type_ = d.type_
    , server = String.trim d.server
    , url = String.trim d.url
    , command = String.trim d.command
    , args = String.trim d.args
    , env = String.trim d.env
    , authType = String.trim d.authType
    , authToken = String.trim d.authToken
    , authClientId = String.trim d.authClientId
    , authClientSecret = String.trim d.authClientSecret
    , protoVersion = String.trim d.protoVersion
    }


updateMcpDraftField : String -> String -> T.McpDraft -> T.McpDraft
updateMcpDraftField field value draft =
    case field of
        "type" ->
            -- Switching kind clears the other kind's fields to avoid residue
            if value == "http" then
                { draft | type_ = value, command = "", args = "", env = "" }

            else
                { draft | type_ = value, url = "" }

        "server" ->
            { draft | server = value }

        "url" ->
            { draft | url = value }

        "command" ->
            { draft | command = value }

        "args" ->
            { draft | args = value }

        "env" ->
            { draft | env = value }

        "auth-type" ->
            { draft | authType = value }

        "auth-token" ->
            { draft | authToken = value }

        "auth-client-id" ->
            { draft | authClientId = value }

        "auth-client-secret" ->
            { draft | authClientSecret = value }

        "proto-version" ->
            { draft | protoVersion = value }

        _ ->
            draft


encodeMcpServers : List T.McpInfo -> String
encodeMcpServers servers =
    E.encode 0 (E.list encodeMcpServer servers)


encodeMcpServer : T.McpInfo -> E.Value
encodeMcpServer s =
    E.object
        [ ( "server", E.string s.server )
        , ( "url", E.string s.url )
        , ( "command", E.string s.command )
        , ( "args", E.string s.args )
        , ( "env", E.string s.env )
        , ( "auth_type", E.string s.authType )
        , ( "auth_token", E.string s.authToken )
        , ( "auth_client_id", E.string s.authClientId )
        , ( "auth_client_secret", E.string s.authClientSecret )
        , ( "proto_version", E.string s.protoVersion )
        ]


draftFromModel : T.ModelInfo -> T.ModelDraft
draftFromModel m =
    { id = m.id
    , name = m.name
    , protocolType = m.protocolType
    , baseUrl = m.baseUrl
    , apiKey = m.apiKey
    , modelName = m.modelName
    , contextLimit = String.fromInt m.contextLimit
    , maxTokens = String.fromInt m.maxTokens
    }


modelFromDraft : T.ModelDraft -> T.ModelInfo
modelFromDraft d =
    { id = d.id
    , name = String.trim d.name
    , protocolType = String.trim d.protocolType
    , baseUrl = String.trim d.baseUrl
    , apiKey = d.apiKey
    , modelName = String.trim d.modelName
    , contextLimit = String.toInt d.contextLimit |> Maybe.withDefault 0
    , maxTokens = String.toInt d.maxTokens |> Maybe.withDefault 0
    }


updateDraftField : String -> String -> T.ModelDraft -> T.ModelDraft
updateDraftField field value draft =
    case field of
        "name" ->
            { draft | name = value }

        "protocol_type" ->
            { draft | protocolType = value }

        "base_url" ->
            { draft | baseUrl = value }

        "api_key" ->
            { draft | apiKey = value }

        "model_name" ->
            { draft | modelName = value }

        "context_limit" ->
            { draft | contextLimit = value }

        "max_tokens" ->
            { draft | maxTokens = value }

        _ ->
            draft


encodeModels : List T.ModelInfo -> String
encodeModels models =
    E.encode 0 (E.list encodeModel models)


encodeModel : T.ModelInfo -> E.Value
encodeModel m =
    E.object
        [ ( "id", E.int m.id )
        , ( "name", E.string m.name )
        , ( "protocol_type", E.string m.protocolType )
        , ( "base_url", E.string m.baseUrl )
        , ( "api_key", E.string m.apiKey )
        , ( "model_name", E.string m.modelName )
        , ( "context_limit", E.int m.contextLimit )
        , ( "max_tokens", E.int m.maxTokens )
        ]


-- Decode a model_sync CO result: Just ( isError, message ) when the frame
-- is a CO for the model_sync command, Nothing otherwise.
decodeSyncOutcome : E.Value -> Maybe ( Bool, String )
decodeSyncOutcome raw =
    case D.decodeValue P.frameEventDecoder raw of
        Ok ev ->
            if ev.tag == "CO" then
                case ev.json of
                    Just json ->
                        let
                            name =
                                D.decodeValue (D.field "name" D.string) json
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""

                            isError =
                                D.decodeValue (D.field "is_error" D.bool) json
                                    |> Result.toMaybe
                                    |> Maybe.withDefault False

                            message =
                                D.decodeValue (D.field "output" (D.field "message" D.string)) json
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""
                        in
                        if name == "model_sync" then
                            Just ( isError, message )

                        else
                            Nothing

                    Nothing ->
                        Nothing

            else
                Nothing

        Err _ ->
            Nothing


defaultModelsListResultDecoder : D.Decoder { ok : Bool, models : List T.ModelInfo, error : String }
defaultModelsListResultDecoder =
    D.map3
        (\ok models error -> { ok = ok, models = models, error = error })
        (D.field "ok" D.bool)
        (D.field "models" (D.list H.modelInfoDecoder))
        (D.field "error" D.string)


defaultModelsSyncResultDecoder : D.Decoder { ok : Bool, error : String }
defaultModelsSyncResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


mcpInfoDecoder : D.Decoder T.McpInfo
mcpInfoDecoder =
    D.succeed T.McpInfo
        |> andMap (D.succeed 0)
        |> andMap (optionalString "type")
        |> andMap (D.field "server" D.string)
        |> andMap (optionalString "url")
        |> andMap (optionalString "command")
        |> andMap (optionalString "args")
        |> andMap (optionalString "env")
        |> andMap (optionalString "auth_type")
        |> andMap (optionalString "auth_token")
        |> andMap (optionalString "auth_client_id")
        |> andMap (optionalString "auth_client_secret")
        |> andMap (optionalString "proto_version")


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap dx df =
    D.map2 (\f x -> f x) df dx


optionalString : String -> D.Decoder String
optionalString key =
    D.oneOf [ D.field key D.string, D.succeed "" ]


mcpListResultDecoder : D.Decoder { ok : Bool, servers : List T.McpInfo, error : String }
mcpListResultDecoder =
    D.map3
        (\ok servers error -> { ok = ok, servers = servers, error = error })
        (D.field "ok" D.bool)
        (D.field "servers" (D.list mcpInfoDecoder))
        (D.field "error" D.string)


mcpSyncResultDecoder : D.Decoder { ok : Bool, error : String }
mcpSyncResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


settingsListResultDecoder : D.Decoder { ok : Bool, toolConfirm : String, builtinTools : String, error : String }
settingsListResultDecoder =
    D.map4
        (\ok toolConfirm builtinTools error -> { ok = ok, toolConfirm = toolConfirm, builtinTools = builtinTools, error = error })
        (D.field "ok" D.bool)
        (D.field "tool_confirm" D.string)
        (D.field "builtin_tools" D.string)
        (D.field "error" D.string)


settingsSyncResultDecoder : D.Decoder { ok : Bool, error : String }
settingsSyncResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


presetInfoDecoder : D.Decoder PresetInfo
presetInfoDecoder =
    D.map2 PresetInfo
        (D.field "name" D.string)
        (D.field "is_active" D.bool)


presetsListResultDecoder : D.Decoder { ok : Bool, presets : List PresetInfo, error : String }
presetsListResultDecoder =
    D.map3
        (\ok presets error -> { ok = ok, presets = presets, error = error })
        (D.field "ok" D.bool)
        (D.field "presets" (D.list presetInfoDecoder))
        (D.field "error" D.string)


presetActionResultDecoder : D.Decoder { ok : Bool, error : String }
presetActionResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


sessionActionResultDecoder : D.Decoder { ok : Bool, error : String, kind : String }
sessionActionResultDecoder =
    D.map3
        (\ok error kind -> { ok = ok, error = error, kind = kind })
        (D.field "ok" D.bool)
        (D.field "error" D.string)
        (D.field "kind" D.string)


type alias ResizeResult =
    { x : Int, y : Int, w : Int, h : Int }


type alias ResizeConfig =
    { handle : ResizeHandle
    , dx : Int
    , dy : Int
    , startX : Int
    , startY : Int
    , startW : Int
    , startH : Int
    , minW : Int
    , minH : Int
    }


resizeDimensions : ResizeConfig -> ResizeResult
resizeDimensions config =
    case config.handle of
        E ->
            { x = config.startX, y = config.startY, w = max config.minW (config.startW + config.dx), h = config.startH }

        W ->
            { x = config.startX + config.dx, y = config.startY, w = max config.minW (config.startW - config.dx), h = config.startH }

        S ->
            { x = config.startX, y = config.startY, w = config.startW, h = max config.minH (config.startH + config.dy) }

        N ->
            { x = config.startX, y = config.startY + config.dy, w = config.startW, h = max config.minH (config.startH - config.dy) }

        NE ->
            { x = config.startX, y = config.startY + config.dy, w = max config.minW (config.startW + config.dx), h = max config.minH (config.startH - config.dy) }

        NW ->
            { x = config.startX + config.dx, y = config.startY + config.dy, w = max config.minW (config.startW - config.dx), h = max config.minH (config.startH - config.dy) }

        SE ->
            { x = config.startX, y = config.startY, w = max config.minW (config.startW + config.dx), h = max config.minH (config.startH + config.dy) }

        SW ->
            { x = config.startX + config.dx, y = config.startY, w = max config.minW (config.startW - config.dx), h = max config.minH (config.startH + config.dy) }


-- ─── Overlay ──────────────────────────────────────────────────────────


-- ─── Help Items ──────────────────────────────────────────────────────

helpItems : List HelpItem
helpItems =
    [ { id = 1, key = "Commands", desc = "", isSection = True, isCommand = False }
    , { id = 2, key = ":tool_confirm <id>", desc = "Confirm pending tool", isSection = False, isCommand = True }
    , { id = 3, key = ":tool_decline <id>", desc = "Decline pending tool", isSection = False, isCommand = True }
    , { id = 4, key = ":mcp_confirm <server> <code> <redirect_uri>", desc = "Confirm OAuth authorization", isSection = False, isCommand = True }
    , { id = 5, key = ":mcp_decline <server>", desc = "Decline OAuth authorization", isSection = False, isCommand = True }
    , { id = 6, key = ":continue", desc = "Retry last prompt", isSection = False, isCommand = True }
    , { id = 7, key = ":reason <0|1|2>", desc = "Set reasoning level", isSection = False, isCommand = True }
    , { id = 8, key = ":cancel", desc = "Cancel current task", isSection = False, isCommand = True }
    , { id = 9, key = ":summarize", desc = "Summarize & compress history", isSection = False, isCommand = True }
    , { id = 10, key = ":theme_set <name>", desc = "Switch theme by name", isSection = False, isCommand = True }
    , { id = 11, key = ":model_set <id>", desc = "Switch model by ID", isSection = False, isCommand = True }
    , { id = 12, key = ":model_load", desc = "Reload model config", isSection = False, isCommand = True }
    , { id = 13, key = ":model_sync", desc = "Apply edited model config", isSection = False, isCommand = True }
    , { id = 14, key = ":save [filename]", desc = "Save session", isSection = False, isCommand = True }
    , { id = 15, key = ":fork <id> <filename>", desc = "Fork session up to content", isSection = False, isCommand = True }
    , { id = 16, key = ":video_config <fps> <0|1>", desc = "Set video FPS and resolution", isSection = False, isCommand = True }
    , { id = 17, key = ":suspend", desc = "Suspend process", isSection = False, isCommand = True }
    , { id = 18, key = ":quit", desc = "Exit application", isSection = False, isCommand = True }
    , { id = 19, key = ":help", desc = "Open help window", isSection = False, isCommand = True }
    ]


nextCopyName : String -> List PresetInfo -> String
nextCopyName source presets =
    let
        taken =
            List.map .name presets |> Set.fromList

        base =
            source ++ "-copy"

        find n =
            let
                cand =
                    base ++ "-" ++ String.fromInt n
            in
            if Set.member cand taken then
                find (n + 1)

            else
                cand
    in
    if Set.member base taken then
        find 2

    else
        base


-- ─── Selector kits ──────────────────────────────────────────────────
--
-- Parameterized update glue for the three list-based selectors. The
-- state machine (Session.Selector) and the view (Overlay.Selector) are
-- shared; these kits supply the per-feature accessors and behaviors so
-- the App.Update handlers can delegate to App.SelectorKit.

sessionModelKit : Kit.Kit T.ModelInfo T.ModelDraft
sessionModelKit =
    { get = \model ->
        case getActiveSession model of
            Just s ->
                s.modelSelector

            Nothing ->
                Sel.empty
    , set = \st model ->
        updateActiveSession model (\s -> { s | modelSelector = st })
    , setShow = \v model ->
        updateActiveSession model (\s -> { s | showModelSelector = v })
    , nameOf = modelName
    , idOf = \m -> m.id
    , setIdOf = \newId m -> { m | id = newId }
    , draftOf = draftFromModel
    , emptyDraft = T.emptyDraft
    , draftIdOf = \d -> d.id
    , itemOfDraft = modelFromDraft
    , updateDraftField = updateDraftField
    , inputId = \model ->
        case model.activeId of
            Just sid ->
                "model-selector-input-" ++ sid

            Nothing ->
                ""
    , editorId = \model ->
        case model.activeId of
            Just sid ->
                "model-editor-name-" ++ sid

            Nothing ->
                ""
    , scrollItemId = \model id ->
        case model.activeId of
            Just sid ->
                "model-selector-item-" ++ sid ++ "-" ++ String.fromInt id

            Nothing ->
                ""
    , confirm = \model ->
        case getActiveSession model of
            Just s ->
                case Sel.selectedItem modelName s.modelSelector of
                    Just m ->
                        if Sel.isDirty s.modelSelector then
                            -- Unsaved edits: ask to sync before leaving
                            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.askSync sess.modelSelector })
                            , Cmd.none
                            )

                        else
                            ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
                            , Cmd.batch
                                [ Ports.setModel { sessionId = s.id, modelId = m.id }
                                , focusInput model
                                ]
                            )

                    Nothing ->
                        ( model, Cmd.none )

            Nothing ->
                ( model, Cmd.none )
    , syncCmd = \model ->
        case getActiveSession model of
            Just s ->
                Ports.modelSync
                    { sessionId = s.id
                    , config = encodeModels s.modelSelector.working
                    }

            Nothing ->
                Cmd.none
    , syncSuccess = \model ->
        ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
        , focusInput model
        )
    , afterClose = \model -> focusInput model
    }


defaultModelsKit : Kit.Kit T.ModelInfo T.ModelDraft
defaultModelsKit =
    { get = \model -> model.defaultModelsEditor.state
    , set = \st model ->
        let
            ed =
                model.defaultModelsEditor
        in
        { model | defaultModelsEditor = { ed | state = st } }
    , setShow = \v model ->
        let
            ed =
                model.defaultModelsEditor
        in
        { model | defaultModelsEditor = { ed | show = v } }
    , nameOf = modelName
    , idOf = \m -> m.id
    , setIdOf = \newId m -> { m | id = newId }
    , draftOf = draftFromModel
    , emptyDraft = T.emptyDraft
    , draftIdOf = \d -> d.id
    , itemOfDraft = modelFromDraft
    , updateDraftField = updateDraftField
    , inputId = \_ -> "model-selector-input-default"
    , editorId = \_ -> "model-editor-name-default"
    , scrollItemId = \_ id -> "model-selector-item-default-" ++ String.fromInt id
    , confirm = \model ->
        let
            ed =
                model.defaultModelsEditor
        in
        case Sel.selectedItem modelName ed.state of
            Just m ->
                ( { model | defaultModelsEditor = { ed | state = Sel.openEdit (draftFromModel m) ed.state } }
                , Kit.focusAndCursor "model-editor-name-default"
                )

            Nothing ->
                ( model, Cmd.none )
    , syncCmd = \model ->
        Ports.syncDefaultModels
            { preset = model.defaultModelsEditor.preset
            , config = encodeModels model.defaultModelsEditor.state.working
            }
    , syncSuccess = \model ->
        ( { model | defaultModelsEditor = emptyDefaultModelsEditor }
        , Cmd.none
        )
    , afterClose = \_ -> Cmd.none
    }


mcpKit : Kit.Kit T.McpInfo T.McpDraft
mcpKit =
    { get = \model -> model.mcpEditor.state
    , set = \st model ->
        let
            ed =
                model.mcpEditor
        in
        { model | mcpEditor = { ed | state = st } }
    , setShow = \v model ->
        let
            ed =
                model.mcpEditor
        in
        { model | mcpEditor = { ed | show = v } }
    , nameOf = mcpServerName
    , idOf = \s -> s.id
    , setIdOf = \newId s -> { s | id = newId }
    , draftOf = draftFromMcp
    , emptyDraft = T.emptyMcpDraft
    , draftIdOf = \d -> d.id
    , itemOfDraft = mcpFromDraft
    , updateDraftField = updateMcpDraftField
    , inputId = \_ -> "mcp-selector-input-default"
    , editorId = \_ -> "mcp-editor-server-default"
    , scrollItemId = \_ id -> "mcp-selector-item-default-" ++ String.fromInt id
    , confirm = \model ->
        let
            ed =
                model.mcpEditor
        in
        case Sel.selectedItem mcpServerName ed.state of
            Just s ->
                ( { model | mcpEditor = { ed | state = Sel.openEdit (draftFromMcp s) ed.state } }
                , Kit.focusAndCursor "mcp-editor-server-default"
                )

            Nothing ->
                ( model, Cmd.none )
    , syncCmd = \model ->
        Ports.syncDefaultMcp
            { preset = model.mcpEditor.preset
            , config = encodeMcpServers model.mcpEditor.state.working
            }
    , syncSuccess = \model ->
        ( { model | mcpEditor = emptyMcpEditor }
        , Cmd.none
        )
    , afterClose = \_ -> Cmd.none
    }
