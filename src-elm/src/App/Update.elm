module App.Update exposing
    ( update
    , SessionDir
    , decodeSessionDir
    , helpItems
    , nextCopyName
    , planFocusAboveSession
    )

{-| Application update logic. Message dispatch plus session/overlay
handling (M2): Plan Mode logic lives in Plan/Update, window/canvas/zoom
management in App/Windows — this module wires them together. The types
live in App.Types; Main only forwards messages here.
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
import App.Windows as Win exposing (..)
import App.NodeConnection as NC
import App.SelectorKit as Kit
import Plan.Update as PU exposing (..)
import Session.Types as T
import Session.Meta as SM
import Session.Protocol as P
import Session.Handlers as H
import Session.Selector as Sel exposing (Page(..))
import Session.FilePicker as FP
import Plan.Types as PT
import Plan.Runner as R
import Plan.Meta as PM
import Plan.Cascade as PC
import Plan.Detect
import Plan.Frames
import Overlay.HelpWindow exposing (HelpItem, filterHelpItems)
import Ports


-- Constants (window/canvas/zoom constants moved to App/Windows)


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


{-| Inputs for the P38 impact-scope walk: metas (ancestry), runs (node
bindings / branch / summaries), sessions (insertion points / user
message counts). -}
scopeCtx : Model -> { planMetas : Dict String PM.PlanMeta, runs : Dict String (Maybe PT.RunState), sessions : Dict String T.SessionState, sessionLineage : Dict String SM.SessionMeta, planResumedFrom : Dict String String }
scopeCtx model =
    { planMetas = model.planMetas
    , runs = Dict.map (\_ w -> w.run) model.planWindows
    , sessions = model.sessions
    , sessionLineage = model.sessionLineage
    , planResumedFrom = model.planResumedFrom
    }


{-| P38 fork result: { ok, sessionId, error } — the new (truncated)
session created by a cascade fork.
-}
cascadeForkResultDecoder : D.Decoder { ok : Bool, sessionId : String, error : String }
cascadeForkResultDecoder =
    D.map3
        (\ok sessionId error -> { ok = ok, sessionId = sessionId, error = error })
        (D.field "ok" D.bool)
        (D.field "sessionId" D.string)
        (D.field "error" D.string)


{-| Which window the user is actually focused on (Ctrl+W close target):
the active PLAN when its window is on top of the active session's
window, or when no session is focused; Nothing when a session is focused
(or neither — fall back to activeId/planActiveId in the caller).
-}
planFocusAboveSession : Model -> Maybe String
planFocusAboveSession model =
    case ( model.planActiveId, model.activeId ) of
        ( Just pid, Just sid ) ->
            let
                pz =
                    Dict.get pid model.windowPositions |> Maybe.map .z

                sz =
                    Dict.get sid model.windowPositions |> Maybe.map .z
            in
            case ( pz, sz ) of
                ( Just p, Just s ) ->
                    if p > s then
                        Just pid

                    else
                        Nothing

                _ ->
                    Nothing

        ( Just pid, Nothing ) ->
            Just pid

        ( Nothing, _ ) ->
            Nothing


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


-- Session dir root: ~/.alayaface/sessions. Plans live INSIDE their
-- owning session's dir (sessions/<originSessionId>/plans/<planId>/), so
-- there is no top-level plans/ root anymore. (sessionsDir itself moved
-- to Plan/Update — plan dirs and the plan-meta scan need it.)
activateSessionModel : Model -> String -> ( Model, Cmd Msg )
activateSessionModel model id =
    let
        chain =
            connectionChainForSession model id
    in
    if List.isEmpty chain then
        let
            -- Raise the session window (D6): end of sessionOrder + next
            -- bounded z. A fresh plain session is not part of any chain.
            m1 =
                raiseWindow model id
                    |> (\m -> { m | activeId = Just id, connectionChain = [] })
        in
        ( m1
        , Ports.setConnectionChain (chainPayload m1 [])
        )

    else
        let
            ( raisedPositions, nextZ ) =
                raiseChainWindows model chain

            m1 =
                { model
                    | activeId = Just id
                    , windowPositions = raisedPositions
                    , nextZIndex = nextZ
                    , connectionChain = chain
                }
        in
        ( m1
        , Ports.setConnectionChain (chainPayload m1 chain)
        )


-- ─── Cascade close (P34/P39-D) ────────────────────────────────────

{-| The MINIMAL close branch, taken while the session is inside the
ownership-graph close set (`closeSet`): tear down THIS window/process
and fail its runner node if any — never re-collect, never recurse
(P39/D1 — the initiating CloseSession already collected the whole set).
-}
minimalCloseSession : String -> Model -> ( Model, Cmd Msg )
minimalCloseSession id model =
    let
        -- If the closed window belongs to a plan run, fail its node
        -- so the runner retries/continues instead of hanging.
        -- (Cascade-closed node sessions are already Canceled by
        -- StopRun, so they do NOT emit a spurious disconnect.)
        -- The event carries the CONVERSATION id (resolved like every
        -- other session-bearing event): a closed RESUME of a node
        -- session has a fresh live id, and passing it raw would miss
        -- the node binding — the node would stay Running forever.
        runnerFailCmd =
            case findPlanIdBySession model id of
                Just _ ->
                    Task.perform
                        (\t ->
                            PlanRunFrame (Time.posixToMillis t)
                                (R.SessionDisconnected (PU.resolveEventSessionId model id) "Session window closed")
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
        , connectionChain = dropChainSession model.connectionChain id
        , activeId =
            if model.activeId == Just id then
                List.head (List.reverse (List.filter (\k -> k /= id) model.sessionOrder))

            else
                model.activeId
      }
    , Cmd.batch
        [ Ports.closeSession { sessionId = id }
        , runnerFailCmd
        , Ports.setConnectionChain (chainPayload model model.connectionChain)
        ]
    )


{-| The MINIMAL close branch for a plan, taken while the plan is inside
the ownership-graph close set: stop its active run (nodes Canceled →
closeAndClear closes the sessions it knows — all inside closeSet, so
those dispatches are minimal too), close the node-session windows under
ANY run status, drop queued creates, remove the window. Never
re-collects (P39/D1).
-}
minimalPlanClose : String -> Model -> ( Model, Cmd Msg )
minimalPlanClose planId model =
    let
        -- 1. If the run is still active (InProgress/Paused), stop it
        --    first: StopRun → nodes Canceled → closeAndClear closes the
        --    sessions it knows (all inside closeSet → minimal) and the
        --    run cannot respawn. Terminal runs are NOT re-stopped: it
        --    would overwrite planRunStatuses (e.g. Completed → Stopped)
        --    and break the status bar.
        ( m1, stopCmd ) =
            case Dict.get planId model.planWindows of
                Just win ->
                    case win.run of
                        Just run ->
                            if List.member run.status [ PT.InProgress, PT.Paused ] then
                                runStepIn update planId 0 R.StopRun model

                            else
                                ( model, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        -- 2. Close every remaining live session bound to this plan's
        --    nodes (direct + resumed ids) — catches windows open under
        --    terminal runs and resumed windows that StopRun's
        --    closeAndClear could not reach.
        nodeSids =
            PU.nodeSessionIdsForPlan planId m1

        ( m2, closeNodeCmds ) =
            List.foldl
                (\sid ( m, cmds ) ->
                    let
                        ( m2a, c2a ) =
                            update (CloseSession sid) m
                    in
                    ( m2a, Cmd.batch [ cmds, c2a ] )
                )
                ( m1, Cmd.none )
                nodeSids
    in
    -- 3. Drop queued creates for this plan too (their sessions would
    --    only be created and immediately orphan-closed), remove the
    --    plan window.
    ( { m2
        | planWindows = Dict.remove planId m2.planWindows
        , planOrder = List.filter (\k -> k /= planId) m2.planOrder
        , windowPositions = Dict.remove planId m2.windowPositions
        , planCreateQueue =
            List.filter
                (\task ->
                    case task of
                        RunnerCreate qpid _ ->
                            qpid /= planId

                        UserCreate _ ->
                            True
                )
                m2.planCreateQueue
        , planActiveId =
            if m2.planActiveId == Just planId then
                List.head (List.reverse (List.filter (\k -> k /= planId) m2.planOrder))

            else
                m2.planActiveId
        , connectionChain =
            List.filter (\seg -> seg.planId /= planId) m2.connectionChain
      }
    , Cmd.batch
        [ stopCmd
        , closeNodeCmds
        , Ports.setConnectionChain (chainPayload m2 m2.connectionChain)
        ]
    )


{-| Fixed plan mode (D2, R2): the planner hint injected via `--system`
into EVERY session (user sessions and plan node sessions alike). No role
lock — the model keeps its tools and may execute directly. For complex
or multi-step tasks it should first emit a fenced ```json plan block
(the framework auto-creates the plan); after outputting a plan it stops
and waits for the plan to be executed and its result fed back.
-}
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
                    , Ports.createSession { toolConfirm = Nothing, preset = Nothing, builtinTools = Nothing, systemPrompt = Just planSystemPrompt, workDir = Nothing, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
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

                -- P38: a cascade FORK replaces the parent conversation —
                -- it must take focus so the user follows the continuation
                -- (otherwise the fork streams deltas "behind" while the
                -- closed plan's spot stays empty).
                isCascadeFork =
                    model.planCascadeFork /= Nothing

                takeFocus =
                    not isRunnerCreate
                        && (isCascadeFork || model.pendingSwitchOnCreate || model.activeId == Nothing)

                newActiveId =
                    if takeFocus then
                        Just id
                    else
                        model.activeId

                cmds =
                    if takeFocus then
                        Cmd.batch [ Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ id)), Ports.scrollToBottom { sessionId = id } ]
                    else
                        Cmd.none

                baseModel0 =
                    { model
                        | sessions = sessionsAfterBuffer
                        , activeId = newActiveId
                        , sessionOrder = model.sessionOrder ++ [ id ]
                        , sessionNums = Dict.insert id model.nextSessionNum model.sessionNums
                        , nextSessionNum = model.nextSessionNum + 1
                        -- M3/D4: seed the incremental plan counter from
                        -- the session's final messages (buffered replay
                        -- included). O(n) ONCE at creation; per-frame
                        -- bumps after that are O(1).
                        , planMessageCounts =
                            case Dict.get id sessionsAfterBuffer of
                                Just s ->
                                    Dict.insert id (planIndexForMessage s.messages) model.planMessageCounts

                                Nothing ->
                                    model.planMessageCounts
                        , windowPositions =
                            if Dict.member id model.windowPositions then
                                model.windowPositions
                            else
                                let
                                    -- Rule 2: a runner-created / resumed
                                    -- node session opens beside its plan
                                    -- window (stacking with an offset);
                                    -- plain creates center on the viewport.
                                    pos =
                                        case pendingNodePlanId model of
                                            Just planId ->
                                                nodeSessionPositionBesidePlan model planId

                                            Nothing ->
                                                centeredSessionPos model
                                in
                                Dict.insert id pos model.windowPositions
                        -- The z bump is applied by raiseWindow below
                        -- (D6: bounded nextZIndex + order-list focus).
                        -- Only consume pendingSwitchOnCreate when this
                        -- session actually consumed it (non-runner). A
                        -- runner session arriving in between must not
                        -- steal a user/resume focus request.
                        , pendingSwitchOnCreate =
                            if isRunnerCreate then
                                model.pendingSwitchOnCreate

                            else
                                False
                        -- A (user/resume) session taking focus yields any
                        -- previous curves (mirrors ActivateSession: a
                        -- fresh session is not part of the old chain);
                        -- runner sessions don't take focus, so the chain
                        -- stays while the plan runs.
                        , connectionChain =
                            if isRunnerCreate then
                                model.connectionChain

                            else
                                []
                        -- P38: a cascade FORK replays its (truncated)
                        -- history — plan messages inside it must not
                        -- auto-create duplicate windows.
                        , planReplaySessions =
                            if model.planCascadeFork /= Nothing then
                                Set.insert id model.planReplaySessions

                            else
                                model.planReplaySessions
                        -- P39/Phase B: a genuinely NEW top-level instance
                        -- registers as the ROOT of its conversation
                        -- (instance → conversation = itself). Resumed
                        -- live handles (planResumeFrom) are ephemeral
                        -- windows over an existing instance; runner-
                        -- created node sessions and cascade forks get
                        -- their lineage from the plan machinery instead.
                        , sessionLineage =
                            if model.planResumeFrom == Nothing && model.planCascadeFork == Nothing && not isRunnerCreate then
                                Dict.insert id (SM.empty id) model.sessionLineage

                            else
                                model.sessionLineage
                        -- P28 layout fix: record this session's REAL
                        -- on-disk directory (top-level for plain
                        -- sessions, the nested node-session dir for plan
                        -- children) so plans created by it live in the
                        -- right subtree.
                        , sessionDirMap =
                            Dict.insert id
                                (sessionDirForCreate model id)
                                model.sessionDirMap
                        , pendingEvents = Dict.remove id model.pendingEvents
                    }

                -- Pan the canvas so the fresh window is visible (its
                -- source window may be far off-screen).
                baseModel =
                    case Dict.get id baseModel0.windowPositions of
                        Just p ->
                            bringIntoView baseModel0 p

                        Nothing ->
                            baseModel0

                -- Raise the fresh session window (D6): end of
                -- sessionOrder + next bounded z (rebase when the z
                -- counter crosses the threshold). The resume branch
                -- below re-raises the whole chain when this session
                -- belongs to a plan node.
                raisedModel =
                    raiseWindow baseModel id

                -- A session resumed for a plan node gets a FRESH id from
                -- resume_session while keeping the ORIGINAL on-disk dir.
                -- The node stays bound to the original id (the dir name)
                -- so it can be resumed again after this window closes;
                -- record the live→orig mapping so node clicks can find
                -- this live window and CloseSession can attribute it back
                -- to the plan node. Never consumed by a runner-created
                -- session.
                resumedModel =
                    case ( model.planResumeFrom, isRunnerCreate ) of
                        ( Just origId, False ) ->
                            let
                                label =
                                    Dict.get origId raisedModel.planNodeSessions

                                -- The resumed session's FULL connection
                                -- chain: its own node↔session segment plus
                                -- every ancestor plan↔session segment up
                                -- to the top-level session. Built with the
                                -- fresh id already mapped back to the
                                -- original dir id (and the binding label
                                -- carried over), so the curve draws from
                                -- the moment the window appears.
                                chain =
                                    connectionChainForSession
                                        { raisedModel
                                            | planResumedFrom = Dict.insert id origId raisedModel.planResumedFrom
                                            , planNodeSessions =
                                                case label of
                                                    Just l ->
                                                        Dict.insert id l raisedModel.planNodeSessions

                                                    Nothing ->
                                                        raisedModel.planNodeSessions
                                        }
                                        id

                                -- The new session is focused; raise the
                                -- whole chain like activateSessionModel
                                -- does (session top, its plan second
                                -- layer, the plan's owning session below,
                                -- … up to the top-level session).
                                ( raisedPositions, raisedNextZ ) =
                                    raiseChainWindows raisedModel chain

                                positions =
                                    if List.isEmpty chain then
                                        -- raiseWindow already raised the
                                        -- session (empty chain = no plan
                                        -- binding to lift).
                                        raisedModel.windowPositions

                                    else
                                        raisedPositions

                                zBump =
                                    if List.isEmpty chain then
                                        0

                                    else
                                        raisedNextZ - raisedModel.nextZIndex
                            in
                            { raisedModel
                                | planResumeFrom = Nothing
                                , planResumeOwner = Nothing
                                , planResumedFrom = Dict.insert id origId raisedModel.planResumedFrom
                                -- The replay-suppression marker is keyed by
                                -- the ORIGINAL id at resume-click time, but
                                -- replayed history frames carry the FRESH
                                -- id — move it old→new so a plan message
                                -- inside the replayed history is suppressed
                                -- (otherwise it auto-creates a duplicate
                                -- plan window with all tasks Pending).
                                , planReplaySessions =
                                    Set.insert id (Set.remove origId raisedModel.planReplaySessions)
                                , connectionChain = chain
                                , windowPositions = positions
                                , nextZIndex = raisedModel.nextZIndex + zBump
                                , planNodeSessions =
                                    case label of
                                        Just l ->
                                            Dict.insert id l raisedModel.planNodeSessions

                                        Nothing ->
                                            raisedModel.planNodeSessions
                            }

                        _ ->
                            raisedModel

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
                -- Draw whatever chain the new session state implies: the
                -- resumed session's full ancestor path, or [] for a
                -- plain/runner-created session (runner keeps the
                -- existing chain, which is already in the model).
                , Ports.setConnectionChain (chainPayload drainedModel drainedModel.connectionChain)
                -- P39/Phase B: persist the root lineage meta for a
                -- genuinely NEW top-level instance (sessions/<id>/
                -- session.meta.json). Resume / runner / fork instances
                -- register through their own paths.
                , if model.planResumeFrom == Nothing && model.planCascadeFork == Nothing && not isRunnerCreate then
                    Ports.fsWriteFileText
                        { path = sessionsDir model.homeDir ++ "/" ++ id ++ "/session.meta.json"
                        , content = E.encode 2 (SM.encode (SM.empty id))
                        , createParents = True
                        }

                  else
                    Cmd.none
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
                            runStepIn update planId 0 (R.SessionCreateFailed nodeId text) m0

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
            -- P39/D1: ownership-graph close. The FIRST close of a
            -- session collects the WHOLE owned set (this session's plans
            -- → their node sessions → their sub-plans → …, one
            -- traversal) and marks it in `closeSet`; every nested
            -- dispatch (a plan's node sessions, StopRun's
            -- closeAndClear) then takes the MINIMAL branch below — no
            -- re-collection, no `PlanClose ⇄ CloseSession` mutual
            -- recursion. The set is cleared before this update returns.
            if Set.member id model.closeSet then
                minimalCloseSession id model

            else
                let
                    ( plans, sessions ) =
                        PU.collectCloseSetFromSession model id

                    m1 =
                        { model | closeSet = Set.fromList (plans ++ sessions) }

                    -- Close every plan first (StopRun stops respawn; each
                    -- plan's node sessions close via minimal dispatches),
                    -- then every session window.
                    ( m2, planCmds ) =
                        List.foldl
                            (\pid ( m, c ) ->
                                let
                                    ( m2a, c2a ) =
                                        update (PlanClose pid) m
                                in
                                ( m2a, Cmd.batch [ c, c2a ] )
                            )
                            ( m1, Cmd.none )
                            plans

                    ( m3, sessionCmds ) =
                        List.foldl
                            (\sid ( m, c ) ->
                                let
                                    ( m2b, c2b ) =
                                        update (CloseSession sid) m
                                in
                                ( m2b, Cmd.batch [ c, c2b ] )
                            )
                            ( m2, Cmd.none )
                            sessions
                in
                ( { m3 | closeSet = Set.empty }
                , Cmd.batch [ planCmds, sessionCmds ]
                )

        -- Transport Events
        DeltaEvent raw ->
            case D.decodeValue P.deltaEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                -- M3/D4: incremental plan count — the delta
                                -- accumulator for this tag:historyId before
                                -- and after; crossing the ```json fence
                                -- bumps the counter exactly once per plan
                                -- message (replaces the per-frame O(n)
                                -- planIndexForMessage scan).
                                prevContent =
                                    Dict.get (ev.tag ++ ":" ++ ev.historyId) session.historyContents
                                        |> Maybe.withDefault ""

                                becamePlan =
                                    becamePlanMessage prevContent (prevContent ++ ev.content)

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
                                , planMessageCounts = bumpPlanCount model.planMessageCounts ev.sessionId becamePlan
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
                                -- M3/D4: incremental plan count — the
                                -- accumulated content for this
                                -- tag:historyId BEFORE the frame; if the
                                -- frame's content crosses the fence for
                                -- the first time, bump the counter.
                                -- AT with empty content (delta-mode
                                -- terminator) or already-plan accumulated
                                -- content never double-counts.
                                prevAccum =
                                    case ev.historyId of
                                        Just hid ->
                                            Dict.get (ev.tag ++ ":" ++ hid) session.historyContents
                                                |> Maybe.withDefault ""

                                        Nothing ->
                                            ""

                                becamePlan =
                                    becamePlanMessage prevAccum (Maybe.withDefault "" ev.content)

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
                                        , planMessageCounts = bumpPlanCount model.planMessageCounts ev.sessionId becamePlan
                                        -- Replay suppression: the marker is
                                        -- removed by the core's explicit
                                        -- readiness signal — SM
                                        -- {"type":"session","data":
                                        -- {"state":"ready"}} arrives AFTER
                                        -- all replayed history content
                                        -- (alayacore v0.62.4+, verified
                                        -- against the binary). No fallback:
                                        -- older cores without the ready SM
                                        -- are not supported.
                                        , planReplaySessions =
                                            if isSessionReady ev then
                                                Set.remove ev.sessionId model.planReplaySessions

                                            else
                                                model.planReplaySessions
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
                                                        planCountOf updatedModel.planMessageCounts ev.sessionId
                                                in
                                                if m.role == T.Assistant
                                                    && not (Set.member ev.sessionId updatedModel.planReplaySessions)
                                                    && not (Dict.member ( ev.sessionId, planIdx ) updatedModel.pendingPlanOffers)
                                                    && not (messageBoundToPlan updatedModel ev.sessionId planIdx) then
                                                    case Plan.Detect.extractPlanJson m.content of
                                                        Just offerRaw ->
                                                            if Plan.Detect.hasPlanTypeMarker offerRaw then
                                                                -- Live plan message: create + auto-open immediately. History
                                                                -- replays (resumed sessions) are suppressed via
                                                                -- planReplaySessions — their plan messages show the manual
                                                                -- "Open plan" button instead.
                                                                Task.perform (\_ -> PlanCreateOffer ev.sessionId planIdx) Time.now

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
                                                        planCountOf updatedModel.planMessageCounts ev.sessionId
                                                in
                                                if m.role == T.Assistant
                                                    && not (Set.member ev.sessionId updatedModel.planReplaySessions)
                                                    && not (Dict.member ( ev.sessionId, planIdx ) updatedModel.pendingPlanOffers)
                                                    && not (messageBoundToPlan updatedModel ev.sessionId planIdx) then
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
                                        -- P39/Phase B: route by CONVERSATION
                                        -- id (root sessions: identity). Must
                                        -- resolve through planResumedFrom too:
                                        -- a resumed node session disconnects
                                        -- under its fresh live id, and the
                                        -- node binds the original
                                        -- conversation id — a raw resolve
                                        -- would drop the failure and leave
                                        -- the node Running forever.
                                        Task.perform
                                            (\t ->
                                                PlanRunFrame (Time.posixToMillis t)
                                                    (R.SessionDisconnected (PU.resolveEventSessionId model ev.sessionId) ev.message)
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
                                        -- A disconnect means any in-flight
                                        -- prompt can never be echoed back —
                                        -- clear the stuck "Sending…" state.
                                        , sendPending = if ev.connected then session.sendPending else False
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

        -- Backend RPC failure (bridge.js catches invoke rejections and
        -- forwards {kind, sessionId, message} via onRpcError). The
        -- critical case is send_prompt: the RPC can be rejected after
        -- the UI set sendPending=True (e.g. the session disconnected
        -- between the click and the write), which would otherwise leave
        -- the prompt stuck in "Sending…" forever with no error shown.
        RpcError raw ->
            case D.decodeValue rpcErrorDecoder raw of
                Ok err ->
                    case Dict.get err.sessionId model.sessions of
                        Just s ->
                            -- An MCP auth failure (start/fill rejected, e.g.
                            -- the session died) must release the running-auth
                            -- marker — otherwise mcpAuthRunning stays set
                            -- forever (only an SM status clears it, and a
                            -- dead session never sends one).
                            let
                                s1 =
                                    if err.kind == "mcp_auth" then
                                        { s | mcpAuthRunning = Nothing }

                                    else
                                        s
                            in
                            ( { model
                                | sessions =
                                    Dict.insert err.sessionId
                                        { s1
                                            | sendPending = False
                                            , statusMsg = err.kind ++ " failed: " ++ err.message
                                        }
                                        model.sessions
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

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

        FsListDirResult raw ->
            case D.decodeValue fsListDirTaggedDecoder raw of
                Ok res ->
                    -- Route by reqId, never by global state: a result
                    -- whose id matches the scan's in-flight listing
                    -- belongs to the planMetas rebuild; everything else
                    -- (picker listings, failed scan listings) falls
                    -- through to the file picker — so the scan can
                    -- neither swallow a user listing that races it nor
                    -- be corrupted by one.
                    if model.planMetaScanReqId == Just res.reqId then
                        if not res.ok then
                            -- Scan listing failed (backend error): abandon
                            -- the rebuild rather than stalling. planMetas
                            -- stays empty this session; plan links still
                            -- resolve from the on-disk files.
                            ( { model
                                | planMetaScanReqId = Nothing
                                , planMetaDirListing = Nothing
                                , planMetaLoading = False
                              }
                            , Cmd.none
                            )

                        else
                            let
                                parsed =
                                    List.filterMap (\v -> D.decodeValue planDirEntryDecoder v |> Result.toMaybe) res.entries
                            in
                            case model.planMetaDirListing of
                                Just dir ->
                                    -- Directory levels (each listed in
                                    -- turn via planMetaDirQueue):
                                    --   sessions/<origin>/plans          → subdirs are PLANS
                                    --   sessions/<origin>/plans/<planId> → subdirs are NODE dirs (+ work/)
                                    --   .../plans/<planId>/<nodeId>      → subdirs are node SESSION dirs (<uuid>/)
                                    -- The plans level queues each plan's
                                    -- meta read AND lists the plan dir;
                                    -- the plan level queues its node dirs;
                                    -- the node level queues the nested
                                    -- session.meta.json reads (P39/Phase B
                                    -- — forked node sessions' lineage must
                                    -- survive restart).
                                    let
                                        dirsIn =
                                            parsed
                                                |> List.filter (\e -> e.isDir && e.name /= ".." && e.name /= ".")
                                                |> List.map .name

                                        segs =
                                            String.split "/" dir |> List.filter ((/=) "")

                                        listNext m =
                                            case m.planMetaDirQueue of
                                                next :: rest ->
                                                    let
                                                        ( reqId, m1 ) =
                                                            nextFsReq m
                                                    in
                                                    ( { m1
                                                        | planMetaDirQueue = rest
                                                        , planMetaDirListing = Just next
                                                        , planMetaScanReqId = Just reqId
                                                      }
                                                    , Ports.fsListDir { reqId = reqId, path = next }
                                                    )

                                                [] ->
                                                    -- All directories
                                                    -- listed: start reading
                                                    -- — top-level lineage
                                                    -- metas, then nested
                                                    -- node-session lineage,
                                                    -- then every plan meta.
                                                    let
                                                        readQueue =
                                                            m.planMetaSessionQueue
                                                                ++ m.planMetaNodeMetaQueue
                                                                ++ m.planMetaReadQueue
                                                    in
                                                    case readQueue of
                                                        r :: rs ->
                                                            let
                                                                ( reqId, m1 ) =
                                                                    nextFsReq m
                                                            in
                                                            ( { m1
                                                                | planMetaDirListing = Nothing
                                                                , planMetaScanReqId = Nothing
                                                                , planMetaReading = Just r
                                                                , planMetaReadReqId = Just reqId
                                                                , planMetaSessionQueue = []
                                                                , planMetaNodeMetaQueue = []
                                                                , planMetaReadQueue = rs
                                                                , planMetaLoading = False
                                                              }
                                                            , Ports.fsReadFileText { reqId = reqId, path = r }
                                                            )

                                                        [] ->
                                                            ( { m | planMetaDirListing = Nothing, planMetaScanReqId = Nothing, planMetaLoading = False }
                                                            , Cmd.none
                                                            )
                                    in
                                    case List.reverse segs of
                                        "plans" :: _ ->
                                            -- A sessions/<uuid>/plans
                                            -- listing: each subdir is a
                                            -- plan (P28 nests plan files in
                                            -- their own dir), so queue the
                                            -- plan meta read AND the plan
                                            -- dir listing (to reach nested
                                            -- node sessions).
                                            let
                                                newReadQueue =
                                                    model.planMetaReadQueue
                                                        ++ List.map (\p -> dir ++ "/" ++ p ++ "/" ++ p ++ ".meta.json") dirsIn

                                                newDirQueue =
                                                    model.planMetaDirQueue
                                                        ++ List.map (\p -> dir ++ "/" ++ p) dirsIn
                                            in
                                            listNext { model | planMetaReadQueue = newReadQueue, planMetaDirQueue = newDirQueue }

                                        _ :: "plans" :: _ ->
                                            -- A plan dir listing: subdirs
                                            -- are node dirs (and work/) —
                                            -- queue them for listing (the
                                            -- node level yields the nested
                                            -- session.meta.json paths).
                                            listNext
                                                { model
                                                    | planMetaDirQueue =
                                                        model.planMetaDirQueue
                                                            ++ List.map (\n -> dir ++ "/" ++ n) (List.filter ((/=) "work") dirsIn)
                                                }

                                        _ ->
                                            -- A node dir listing: subdirs
                                            -- are node session dirs (<uuid>)
                                            -- — queue their lineage metas AND
                                            -- record each session's REAL
                                            -- (nested) directory so plans it
                                            -- creates stay in this subtree
                                            -- (P28 layout fix).
                                            listNext
                                                { model
                                                    | planMetaNodeMetaQueue =
                                                        model.planMetaNodeMetaQueue
                                                            ++ List.map (\n -> dir ++ "/" ++ n ++ "/session.meta.json") dirsIn
                                                    , sessionDirMap =
                                                        List.foldl
                                                            (\n acc -> Dict.insert n (dir ++ "/" ++ n) acc)
                                                            model.sessionDirMap
                                                            dirsIn
                                                }

                                Nothing ->
                                    -- The sessions/ listing: queue every
                                    -- session's plans/ subdir (missing
                                    -- plans dirs list empty; ".." from
                                    -- the listing is skipped) AND every
                                    -- session's lineage meta
                                    -- (sessions/<uuid>/session.meta.json,
                                    -- P39/Phase B — read BEFORE the plan
                                    -- metas so plan origins can resolve
                                    -- against the registry).
                                    let
                                        sessionDirs =
                                            parsed
                                                |> List.filter (\e -> e.isDir && e.name /= ".." && e.name /= ".")
                                                |> List.map .name

                                        planDirs =
                                            List.map (\n -> sessionsDir model.homeDir ++ "/" ++ n ++ "/plans") sessionDirs

                                        sessionMetaQueue =
                                            List.map (\n -> sessionsDir model.homeDir ++ "/" ++ n ++ "/session.meta.json") sessionDirs
                                    in
                                    case planDirs of
                                        next :: rest ->
                                            let
                                                ( reqId, m1 ) =
                                                    nextFsReq model
                                            in
                                            ( { m1
                                                | planMetaDirQueue = rest
                                                , planMetaDirListing = Just next
                                                , planMetaSessionQueue = sessionMetaQueue
                                                , planMetaScanReqId = Just reqId
                                                -- P28 layout fix: record the
                                                -- top-level session dirs.
                                                , sessionDirMap =
                                                    List.foldl
                                                        (\n acc -> Dict.insert n (sessionsDir model.homeDir ++ "/" ++ n) acc)
                                                        model.sessionDirMap
                                                        sessionDirs
                                              }
                                            , Ports.fsListDir { reqId = reqId, path = next }
                                            )

                                        [] ->
                                            -- No plans dirs anywhere: go
                                            -- straight to reading the
                                            -- session lineage metas.
                                            case sessionMetaQueue of
                                                r :: rs ->
                                                    let
                                                        ( reqId2, m2 ) =
                                                            nextFsReq model
                                                    in
                                                    ( { m2
                                                        | planMetaScanReqId = Nothing
                                                        , planMetaReading = Just r
                                                        , planMetaReadReqId = Just reqId2
                                                        , planMetaSessionQueue = rs
                                                        , planMetaReadQueue = []
                                                        , planMetaLoading = False
                                                      }
                                                    , Ports.fsReadFileText { reqId = reqId2, path = r }
                                                    )

                                                [] ->
                                                    ( { model | planMetaScanReqId = Nothing, planMetaLoading = False }
                                                    , Cmd.none
                                                    )

                    else
                        -- File picker listing (or any other non-scan
                        -- listing). The planMetas index rebuild starts
                        -- HERE, after the session file-picker's home
                        -- listing has been consumed.
                        let
                            parsed =
                                List.filterMap FP.decodeDirEntry res.entries

                            noDotDot =
                                List.filter (\e -> e.name /= "..") parsed

                            ( m0, scanCmd ) =
                                if model.planMetaScanPending then
                                    let
                                        ( reqId, m1 ) =
                                            nextFsReq model
                                    in
                                    ( { m1
                                        | planMetaScanPending = False
                                        , planMetaLoading = True
                                        , planMetaScanReqId = Just reqId
                                      }
                                    , Ports.fsListDir { reqId = reqId, path = sessionsDir m1.homeDir }
                                    )

                                else
                                    ( model, Cmd.none )
                        in
                        ( updateActiveSession m0 (\s ->
                            let
                                fp =
                                    s.filePicker
                            in
                            { s
                                | filePicker =
                                    if res.ok then
                                        { fp | entries = noDotDot, loading = False, error = Nothing }

                                    else
                                        -- The listing failed (backend
                                        -- error / dead session): surface
                                        -- it in the picker instead of
                                        -- leaving it stuck in loading.
                                        { fp | entries = [], loading = False, error = Just res.error }
                            }
                          )
                        , scanCmd
                        )

                Err _ ->
                    ( model, Cmd.none )

        FsHomeDirResult raw ->
            case D.decodeValue fsHomeDirDecoder raw of
                Ok { ok, home, error } ->
                    if ok then
                        let
                            model2 =
                                { model | homeDir = home }

                            ( reqId, m1 ) =
                                nextFsReq model2
                        in
                        ( updateActiveSession m1 (\s ->
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
                            [ Ports.fsListDir { reqId = reqId, path = home }
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
                        -- The planMetas index rebuild (fs_list_dir
                        -- sessions/ → each session's plans/ → read every
                        -- *.meta.json) starts ONLY after this home listing
                        -- has been consumed (FsListDirResult's picker
                        -- branch): firing them in the same batch would let
                        -- the home listing be misrouted into the scan and
                        -- desynchronize it — leaving planMetas empty after
                        -- a restart (plans unreachable via the status-bar
                        -- link). The reqId routing makes the two flows
                        -- distinguishable even if they did overlap.
                        |> (\( m, c ) -> ( { m | planMetaScanPending = True }, c ))

                    else
                        -- Home dir could not be resolved (no HOME env /
                        -- backend error): surface it instead of leaving
                        -- the picker stuck in loading with an empty base.
                        let
                            m1 =
                                updateActiveSession model (\s ->
                                    let
                                        fp =
                                            s.filePicker
                                    in
                                    { s | filePicker = { fp | loading = False, error = Just error } }
                                )
                        in
                        ( { m1 | sessionManagerError = Just error }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        FsReadFileResult raw ->
            case D.decodeValue fsReadFileUriDecoder raw of
                Ok { ok, uri, error } ->
                    case getActiveSession model of
                        Just s ->
                            if ok then
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

                            else
                                -- Read failed (oversized / missing file /
                                -- backend error): surface it in the picker
                                -- instead of silently dropping the click.
                                ( updateActiveSession model (\sess ->
                                    let
                                        fp =
                                            sess.filePicker
                                    in
                                    { sess | filePicker = { fp | loading = False, error = Just error } }
                                  )
                                , Cmd.none
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
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
                        in
                        ( model2, Cmd.none )

                    else
                        ( setPlanErrors [ error ] model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        -- Text file read result: Plan Mode open/import (target.isResume =
        -- False), Load run (isResume=True + continueRun=True) or a silent
        -- best-effort run-state restore when a plan window opens
        -- (isResume=True + continueRun=False).
        FsReadResult raw ->
            case D.decodeValue fsReadTaggedDecoder raw of
                Ok res ->
                    -- Route by reqId, never by global state: a read whose
                    -- id matches the scan's in-flight meta.json read
                    -- belongs to the planMetas rebuild; a read matching
                    -- the plan read target belongs to an open/load/
                    -- restore flow; anything else is stale (raced a newer
                    -- request) and is ignored.
                    if model.planMetaReadReqId == Just res.reqId then
                        let
                            path =
                                Maybe.withDefault "" model.planMetaReading

                            m1 =
                                if res.ok then
                                    if String.endsWith "/session.meta.json" path then
                                        -- P39/Phase B: a session lineage
                                        -- meta (sessions/<uuid>/session.meta.json)
                                        -- registers instanceId → SessionMeta.
                                        case D.decodeString SM.decode res.content of
                                            Ok sm ->
                                                let
                                                    instanceId =
                                                        case List.reverse (String.split "/" path) of
                                                            _ :: i :: _ ->
                                                                i

                                                            _ ->
                                                                path
                                                in
                                                { model | sessionLineage = Dict.insert instanceId sm model.sessionLineage }

                                            Err _ ->
                                                model

                                    else
                                        case D.decodeString PM.decodeMeta res.content of
                                            Ok meta ->
                                                let
                                                    -- planId = the meta
                                                    -- file name minus
                                                    -- ".meta.json" (paths
                                                    -- are
                                                    -- sessions/<origin>/plans/<planId>/<planId>.meta.json).
                                                    planId =
                                                        String.split "/" path
                                                            |> List.reverse
                                                            |> List.head
                                                            |> Maybe.withDefault path
                                                            |> String.dropRight (String.length ".meta.json")
                                                in
                                                { model | planMetas = Dict.insert planId meta model.planMetas }

                                            Err _ ->
                                                model

                                else
                                    -- A failed meta read (missing/corrupt
                                    -- file): skip it, keep the chain going.
                                    model
                        in
                        case m1.planMetaReadQueue of
                            next :: rest ->
                                let
                                    ( reqId2, m2 ) =
                                        nextFsReq m1
                                in
                                ( { m2
                                    | planMetaReading = Just next
                                    , planMetaReadQueue = rest
                                    , planMetaReadReqId = Just reqId2
                                  }
                                , Ports.fsReadFileText { reqId = reqId2, path = next }
                                )

                            [] ->
                                ( { m1 | planMetaReading = Nothing, planMetaReadReqId = Nothing }, Cmd.none )

                    else
                        case model.planReadTarget of
                            Just target ->
                                if target.reqId == res.reqId then
                                    let
                                        ( m1, c1 ) =
                                            handlePlanReadTarget update model target res.ok res.content res.error
                                    in
                                    -- P38: the open/restore flow finished
                                    -- (planReadTarget cleared) → reopen the
                                    -- next queued ancestor or start the
                                    -- confirmed cascade run.
                                    if m1.planReadTarget == Nothing && m1.planCascadeOpenQueue /= [] then
                                        let
                                            ( m2, c2 ) =
                                                openNextOrStart m1
                                        in
                                        ( m2, Cmd.batch [ c1, c2 ] )

                                    else
                                        ( m1, c1 )

                                else
                                    -- A newer read replaced this target
                                    -- before the response arrived: ignore.
                                    ( model, Cmd.none )

                            Nothing ->
                                -- No read pending: stale/foreign response.
                                ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        FsResolvePathResult result ->
            case getActiveSession model of
                Just s ->
                    case D.decodeValue resolvePathResultDecoder result of
                        Ok rp ->
                            if rp.ok && rp.exists && rp.isDir then
                                let
                                    fp =
                                        s.filePicker

                                    sameDir =
                                        rp.resolved == fp.dir

                                    ( reqId, m1 ) =
                                        nextFsReq model
                                in
                                ( updateActiveSession m1 (\sess ->
                                    { sess
                                        | filePicker = { fp | dir = rp.resolved, selected = 0 }
                                    }
                                  )
                                , if sameDir then
                                    Cmd.none
                                  else
                                    Ports.fsListDir { reqId = reqId, path = rp.resolved }
                                )

                            else
                                -- Resolve failed or the path is not a
                                -- directory: release the picker's loading
                                -- state so it never hangs waiting for a
                                -- listing, and show why.
                                let
                                    errMsg =
                                        if rp.ok then
                                            "Not a directory: " ++ rp.resolved

                                        else
                                            rp.error
                                in
                                ( updateActiveSession model (\sess ->
                                    let
                                        fp =
                                            sess.filePicker
                                    in
                                    { sess
                                        | filePicker =
                                            { fp | loading = False, error = Just errMsg }
                                    }
                                  )
                                , Cmd.none
                                )

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
                                -- so feedback can route results back, the
                                -- status bar can bind to this message, and the
                                -- plan's on-disk dir can be found. The index
                                -- is counted with the same predicate as
                                -- detection, so rendering can find it back
                                -- without relying on message ids.
                                origin =
                                    PM.Origin sid planIndex
                            in
                            ( model2
                            , Task.perform (PlanSaveReady plan origin) (Task.map Time.posixToMillis Time.now)
                            )

                        Err errs ->
                            -- R2: invalid detected plan — report inline in
                            -- the originating session (no window is created).
                            -- The marker check is lenient, so this also fires
                            -- for models whose plan JSON could not be repaired:
                            -- show the reason AND, if the origin session is a
                            -- plan NODE (already marked WaitingForPlan by the
                            -- lenient delegation judgment), complete the node —
                            -- otherwise the run hangs waiting for a feedback
                            -- that never comes.
                            let
                                m1 =
                                    injectPlanErrorIntoSession errs sid model2
                            in
                            case findPlanIdBySession m1 sid of
                                Just pid ->
                                    ( m1
                                    , Task.perform
                                        (\t -> PlanRunFrame t (R.TaskDone sid False (lastAssistantOutput m1 sid) False))
                                        (Task.map Time.posixToMillis Time.now)
                                    )

                                Nothing ->
                                    ( m1, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PlanSaveReady plan origin0 timestamp ->
            let
                planId =
                    PT.slugify plan.name ++ "-" ++ String.fromInt timestamp

                -- The plan lives under its owning session's ON-DISK dir:
                -- sessions/<originSessionId>/plans/<planId>/ (resumes
                -- hand out fresh live ids whose dirs don't exist — the
                -- origin must be the original dir id).
                originDiskId =
                    onDiskSessionId model origin0.sessionId

                origin =
                    { origin0 | sessionId = originDiskId }

                planDir =
                    planDirIn model.homeDir model.sessionDirMap originDiskId planId

                path =
                    planDir ++ "/" ++ planId ++ ".json"

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
                -- binding + feedbacks + recursion depth); planMetas is kept
                -- in memory for the status bar, feedback routing and the
                -- recursion checks. depth = parent.depth + 1 when the origin
                -- session is a plan node's session, else 1 (top-level).
                depth =
                    PM.depthForOrigin model.planMetas (runStatesOf model) originDiskId

                meta =
                    { origin = origin
                    , feedbacks = []
                    , depth = depth
                    , createdAt = timestamp
                    , name = plan.name
                    , lastStatus = PT.runStatusToString PT.NotStarted
                    -- P38: persist the parent linkage so the re-run
                    -- cascade can walk the ancestry from the meta index
                    -- alone (ancestor windows may be closed).
                    , parentPlanId = PM.parentPlanIdOfSession (runStatesOf model) originDiskId
                    }

                metaPath =
                    PM.metaPathFor planDir planId

                m1 =
                    { model
                        | planMetas = Dict.insert planId meta model.planMetas
                    }
            in
            let
                m2 =
                    addPlanWindow planId win1 m1

                -- Sub-plans (depth > 1) run immediately: the parent node
                -- is WaitingForPlan and the R-series design is model-
                -- autonomous recursion. Only the top-level plan waits for
                -- the user's Run click.
                autoRunCmd =
                    if PM.shouldAutoRun depth then
                        Task.perform (\t -> PlanAutoRunStart planId t) (Task.map Time.posixToMillis Time.now)

                    else
                        Cmd.none
            in
            ( m2
            , Cmd.batch
                [ Ports.fsWriteFileText { path = path, content = content, createParents = True }
                , Ports.fsWriteFileText { path = metaPath, content = E.encode 2 (PM.encodeMeta meta), createParents = True }
                , Ports.setConnectionChain (chainPayload m2 m2.connectionChain)
                , autoRunCmd
                ]
            )

        PlanStatusOpen planId ->
            -- The plan window is already open (auto-create) → focus it;
            -- otherwise (restart) open from disk like the manager does.
            if Dict.member planId model.planWindows then
                let
                    chain =
                        connectionChainForPlan model planId

                    -- Raise the plan's ancestor path too, so the whole
                    -- chain up to the top-level session is visible.
                    ( raisedPositions, raisedNextZ ) =
                        raiseChainWindows model chain

                    ( positions, nextZ ) =
                        if List.isEmpty chain then
                            ( model.windowPositions, model.nextZIndex )

                        else
                            ( raisedPositions, raisedNextZ )

                    m1 =
                        { model
                            | planActiveId = Just planId
                            , showGlobalMenu = False
                            , windowPositions = positions
                            , nextZIndex = nextZ
                            , connectionChain = chain
                        }
                in
                ( m1
                , Ports.setConnectionChain (chainPayload m1 chain)
                )

            else
                case planFilePathOf model planId of
                    Just path ->
                        openPlanFile path model

                    Nothing ->
                        ( model, Cmd.none )

        PlanActivate planId ->
            -- Always rebuild + raise + emit, even when this plan is
            -- already `planActiveId` (it stays set from auto-creation,
            -- while focusing a session switches the chain away — so
            -- clicking the (sub-)plan must switch the chain back to the
            -- plan's own ancestor path).
            let
                chain =
                    connectionChainForPlan model planId
            in
            if List.isEmpty chain then
                -- Empty chain (owning session closed / no meta): still
                -- raise the plan window itself (D6: raiseWindow).
                let
                    m1 =
                        raiseWindow model planId
                            |> (\m -> { m | planActiveId = Just planId, showGlobalMenu = False, connectionChain = chain })
                in
                ( m1
                , Ports.setConnectionChain (chainPayload m1 chain)
                )

            else
                let
                    ( raisedPositions, raisedNextZ ) =
                        raiseChainWindows model chain

                    m1 =
                        { model
                            | planActiveId = Just planId
                            , windowPositions = raisedPositions
                            , nextZIndex = raisedNextZ
                            , showGlobalMenu = False
                            , connectionChain = chain
                        }
                in
                ( m1
                , Ports.setConnectionChain (chainPayload m1 chain)
                )

        PlanClose planId ->
            -- P39/D1: ownership-graph close, mirroring CloseSession —
            -- the FIRST close of a plan collects the whole owned set
            -- (its node sessions → their sub-plans → …) in ONE
            -- traversal and marks it in `closeSet`; nested dispatches
            -- (node sessions, StopRun's closeAndClear) take the minimal
            -- branch. No `PlanClose ⇄ CloseSession` mutual recursion.
            if Set.member planId model.closeSet then
                minimalPlanClose planId model

            else
                let
                    ( plans, sessions ) =
                        PU.collectCloseSetFromPlan model planId

                    m1 =
                        { model | closeSet = Set.fromList (plans ++ sessions) }

                    ( m2, planCmds ) =
                        List.foldl
                            (\pid ( m, c ) ->
                                let
                                    ( m2a, c2a ) =
                                        update (PlanClose pid) m
                                in
                                ( m2a, Cmd.batch [ c, c2a ] )
                            )
                            ( m1, Cmd.none )
                            plans

                    ( m3, sessionCmds ) =
                        List.foldl
                            (\sid ( m, c ) ->
                                let
                                    ( m2b, c2b ) =
                                        update (CloseSession sid) m
                                in
                                ( m2b, Cmd.batch [ c, c2b ] )
                            )
                            ( m2, Cmd.none )
                            sessions
                in
                ( { m3 | closeSet = Set.empty }
                , Cmd.batch [ planCmds, sessionCmds ]
                )

        -- ─── Plan runner ────────────────────────────────────────────

        PlanRunStart ->
            case getPlanWin model of
                Just win ->
                    case win.view.plan of
                        Just _ ->
                            let
                                canStart =
                                    case win.run of
                                        Just run ->
                                            List.member run.status [ PT.Completed, PT.FailedRun, PT.Stopped, PT.NotStarted ]

                                        Nothing ->
                                            True
                            in
                            if canStart then
                                -- P38: a re-run that would truncate parent
                                -- sessions / cascade upward needs the
                                -- impact-scope confirmation first.
                                case model.planActiveId of
                                    Just pid ->
                                        let
                                            scope =
                                                PC.impactScope (scopeCtx model) pid
                                        in
                                        if PC.needsConfirm scope then
                                            ( { model | planCascadePreview = Just scope }, Cmd.none )

                                        else
                                            ( model
                                            , Task.perform (\t -> PlanRunStartAt (Time.posixToMillis t)) Time.now
                                            )

                                    Nothing ->
                                        ( model, Cmd.none )

                            else
                                ( model, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PlanCascadeConfirm ->
            -- P38: user authorized the re-run cascade. Close (and stop)
            -- child plans living inside the truncated region (their
            -- feedback is suppressed), then reopen any closed ancestors
            -- (their runs are needed), then start the root run.
            case model.planCascadePreview of
                Just scope ->
                    let
                        m0 =
                            { model
                                | planSuppressFeedback =
                                    Set.union model.planSuppressFeedback (Set.fromList scope.closePlanIds)
                            }

                        ( m1, closeCmd ) =
                            List.foldl
                                (\pid ( m, c ) ->
                                    let
                                        ( m2, c2 ) =
                                            update (PlanClose pid) m
                                    in
                                    ( m2, Cmd.batch [ c, c2 ] )
                                )
                                ( m0, Cmd.none )
                                scope.closePlanIds

                        queue =
                            List.filter (\lvl -> not (Dict.member lvl.planId m1.planWindows)) scope.levels
                                |> List.map .planId

                        ( m3, openCmd ) =
                            openNextOrStart { m1 | planCascadeOpenQueue = queue }
                    in
                    ( m3, Cmd.batch [ closeCmd, openCmd ] )

                Nothing ->
                    ( model, Cmd.none )

        PlanCascadeCancel ->
            ( { model
                | planCascadePreview = Nothing
                , planCascade = Nothing
                , planCascadeOpenQueue = []
                , planCascadeFork = Nothing
              }
            , Cmd.none
            )

        PlanCascadeForkResult raw ->
            -- P38/P39: the cascade fork finished. A SUCCESS is registered
            -- and adopted in ONE update: SessionCreated (nested,
            -- synchronous) opens the fork window exactly like any new
            -- session, then the machine's InstanceReady effect list runs
            -- (RegisterFork + InsertResult + ResumeNode) — all before the
            -- outer update returns, so the fork session's first render
            -- already sees the fork binding (no stale "Open plan" flash).
            -- Because the adoption is driven by THIS event — the only one
            -- that carries the real fork id — a user-created session
            -- racing the fork can never be mistaken for it.
            -- A FAILURE means nothing was truncated and no ancestor node
            -- was reset, so the cascade must END, not linger. Leaving
            -- planCascade armed is a latent mis-trigger: its head level
            -- still points at the live source session, so a later
            -- TaskDone from that session would run the machine's
            -- BranchRerun — re-running downstream branches WITHOUT any
            -- truncation. The completed plan window stays open (user can
            -- inspect / re-run / close).
            case D.decodeValue cascadeForkResultDecoder raw of
                Ok r ->
                    if r.ok then
                        -- P39/Phase C: register the fork window exactly
                        -- like any new session (nested, synchronous), then
                        -- feed InstanceReady to the cascade machine — the
                        -- adoption (lineage registration + close old
                        -- instance + insert result + resume node) is now
                        -- driven by the machine's effects, in this same
                        -- outer update, so the fork session's first render
                        -- already sees the fork binding (no stale
                        -- "Open plan" flash). Only this event carries the
                        -- real fork id, so a user-created session racing
                        -- the fork can never be mistaken for it.
                        let
                            ( mReg, cReg ) =
                                update (SessionCreated r.sessionId) model

                            ( mAdopt, cAdopt ) =
                                PU.cascadeStepIn update (PC.InstanceReady (Ok r.sessionId)) mReg
                        in
                        ( mAdopt, Cmd.batch [ cReg, cAdopt ] )

                    else
                        ( { model
                            | planCascadeFork = Nothing
                            , planCascade = Nothing
                            , planCascadeOpenQueue = []
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        PlanRunStartAt ts ->
            let
                m1 =
                    case model.planActiveId of
                        Just pid ->
                            startRunIn pid ts model

                        Nothing ->
                            model
            in
            case model.planActiveId of
                Just pid ->
                    runStepIn update pid ts R.StartRun m1

                Nothing ->
                    ( model, Cmd.none )

        -- Sub-plans auto-run right after creation (depth > 1); the
        -- window is fresh (win.run == Nothing), so this is exactly the
        -- same start as a manual Run click on the active window.
        PlanAutoRunStart planId ts ->
            runStepIn update planId ts R.StartRun (startRunIn planId ts model)

        PlanRunPause ->
            case model.planActiveId of
                Just pid ->
                    runStepIn update pid 0 R.PauseRun model

                Nothing ->
                    ( model, Cmd.none )

        PlanRunResume ->
            case model.planActiveId of
                Just pid ->
                    runStepIn update pid 0 R.ResumeRun model

                Nothing ->
                    ( model, Cmd.none )

        PlanRunRestart planId ->
            -- R4 (D9): skip succeeded nodes; reset the rest and cascade
            -- to sub-plans of waiting (delegated) nodes.
            restartPlanCascade update planId model

        PlanRunStop ->
            case model.planActiveId of
                Just pid ->
                    let
                        ( m1, c1 ) =
                            runStepIn update pid 0 R.StopRun model
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
                    runStepIn update pid 0 (R.RetryNode nodeId) model

                Nothing ->
                    ( model, Cmd.none )

        PlanRunnerTick planId nodeId ->
            runStepIn update planId 0 (R.RetryTick nodeId) model

        PlanRunFrame ts ev ->
            case eventSessionId ev of
                Just sid ->
                    case findPlanIdBySession model sid of
                        Just pid ->
                            runStepIn update pid ts ev model

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PlanBindSession ts planId nodeId sid ->
            let
                -- P39/Phase B: the node is bound by its session's
                -- CONVERSATION id (stable across forks; a root session
                -- resolves to itself).
                convId =
                    SM.resolveConversation model.sessionLineage sid

                m0 =
                    { model | planCreating = Nothing }

                ( m1, c1 ) =
                    runStepIn update planId ts (R.SessionCreatedFor nodeId convId) m0

                ( m2, c2 ) =
                    startNextCreateIn m1

                -- Keep the node→session binding visible: the session bar
                -- shows "[Plan · planId/nodeId]" (keyed by the
                -- conversation id so fork instances resolve to it).
                m3 =
                    { m2
                        | planNodeSessions =
                            Dict.insert convId (planId ++ "/" ++ nodeId) m2.planNodeSessions
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
                                            if n.status == PT.Running && n.conversationId == Just convId then
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

                                ( reqId, m1 ) =
                                    nextFsReq model
                            in
                            ( { m1
                                | planWindows = Dict.insert pid win1 m1.planWindows
                                , planReadTarget =
                                    Just
                                        { reqId = reqId
                                        , planId = pid
                                        , path = runPath
                                        , isResume = True
                                        , continueRun = True
                                        }
                              }
                            , Ports.fsReadFileText { reqId = reqId, path = runPath }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        PlanSelectNode nodeId ->
            ( updateActivePlanWin model
                (\w -> { w | selectedNode = Just nodeId, infoOpen = True })
            , Cmd.none
            )

        PlanOpenNodeSession planId nodeId ->
            -- Node → session binding: click a node to open its session.
            -- Priority: live conversation session (focus it) → live
            -- session resumed from the same instance (focus it) →
            -- resume from disk → detail.
            case Dict.get planId model.planWindows of
                Just win ->
                    case win.run of
                        Just run ->
                            case Dict.get nodeId run.nodes of
                                Just n ->
                                    -- P39/Phase B: the node is bound by
                                    -- CONVERSATION id; for a root session
                                    -- that IS the instance/dir id, so
                                    -- resume_session works unchanged.
                                    case n.conversationId of
                                        Just convId ->
                                            if Dict.member convId model.sessions then
                                                update (ActivateSession convId) model

                                            else
                                                case findResumedLive convId model of
                                                    Just liveId ->
                                                        update (ActivateSession liveId) model

                                                    Nothing ->
                                                        -- dead live-binding
                                                        -- (e.g. restart):
                                                        -- resume from disk.
                                                        -- The node STAYS
                                                        -- bound to convId
                                                        -- (the dir name);
                                                        -- the resumed window
                                                        -- gets a fresh id
                                                        -- tracked via
                                                        -- planResumedFrom.
                                                        ( { model
                                                            | pendingSwitchOnCreate = True
                                                            , planResumeOwner = Just planId
                                                            , planResumeFrom = Just convId
                                                            , planReplaySessions = Set.insert convId model.planReplaySessions
                                                            , planNodeSessions =
                                                                Dict.insert convId (planId ++ "/" ++ nodeId) model.planNodeSessions
                                                          }
                                                        , Ports.resumeSession { sessionId = convId, workDir = planWorkDir planId model, planId = Just planId, nodeId = Just nodeId, originSessionId = planOriginSessionDir model planId }
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
                                                                    , planReplaySessions = Set.insert sid model.planReplaySessions
                                                                    , planNodeSessions =
                                                                        Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                                                                  }
                                                                , Ports.resumeSession { sessionId = sid, workDir = planWorkDir planId model, planId = Just planId, nodeId = Just nodeId, originSessionId = planOriginSessionDir model planId }
                                                                )

                                                Nothing ->
                                                    ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId, infoOpen = True })
                                                    , Cmd.none
                                                    )

                                Nothing ->
                                    ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId, infoOpen = True })
                                    , Cmd.none
                                    )

                        Nothing ->
                            ( updateActivePlanWin model (\w -> { w | selectedNode = Just nodeId, infoOpen = True })
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
                            , planReplaySessions = Set.insert sid model.planReplaySessions
                            , planNodeSessions =
                                Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                          }
                        , Ports.resumeSession { sessionId = sid, workDir = planWorkDir planId model, planId = Just planId, nodeId = Just nodeId, originSessionId = planOriginSessionDir model planId }
                        )

        PlanToggleInfo ->
            -- "?" in the plan title bar: open the Plan tab; switch from a
            -- node tab back to the Plan tab; close when already on it.
            ( updateActivePlanWin model
                (\w ->
                    if w.infoOpen then
                        case w.selectedNode of
                            Just _ ->
                                { w | selectedNode = Nothing }

                            Nothing ->
                                { w | infoOpen = False }

                    else
                        { w | infoOpen = True, selectedNode = Nothing }
                )
            , Cmd.none
            )

        PlanCloseInfo ->
            ( updateActivePlanWin model
                (\w -> { w | infoOpen = False, selectedNode = Nothing })
            , Cmd.none
            )

        ToggleGlobalMenu ->
            ( { model | showGlobalMenu = not model.showGlobalMenu }, Cmd.none )

        CloseGlobalMenu ->
            ( { model | showGlobalMenu = False }, Cmd.none )

        SessionDirsResult raw ->
            case D.decodeValue sessionDirsDecoder raw of
                Ok { ok, dirs, error } ->
                    if ok then
                        ( { model | sessionDirs = dirs, sessionManagerError = Nothing }, Cmd.none )

                    else
                        -- list_session_dirs failed: surface the error
                        -- instead of silently showing an empty manager.
                        ( { model | sessionDirs = [], sessionManagerError = Just error }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

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
            -- Mark the session as replaying so plan messages in its
            -- history don't auto-create windows. planResumeFrom lets
            -- SessionCreated move that marker old→new (the replayed
            -- frames carry the fresh resumed id).
            ( { model
                | pendingSwitchOnCreate = True
                , sessionManagerError = Nothing
                , planResumeFrom = Just id
                , planReplaySessions = Set.insert id model.planReplaySessions
              }
            , Ports.resumeSession { sessionId = id, workDir = Nothing, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
            )

        DeleteSession id ->
            -- P39/D1: the deleted dir contains the session's plans +
            -- node sessions on disk, so their windows/processes must go
            -- too — same ownership-graph collection as CloseSession.
            let
                ( plans, sessions ) =
                    PU.collectCloseSetFromSession model id

                m1 =
                    { model | closeSet = Set.fromList (plans ++ sessions) }

                ( m2, planCmds ) =
                    List.foldl
                        (\pid ( m, c ) ->
                            let
                                ( m2a, c2a ) =
                                    update (PlanClose pid) m
                            in
                            ( m2a, Cmd.batch [ c, c2a ] )
                        )
                        ( m1, Cmd.none )
                        plans

                ( m3, sessionCmds ) =
                    List.foldl
                        (\sid ( m, c ) ->
                            let
                                ( m2b, c2b ) =
                                    update (CloseSession sid) m
                            in
                            ( m2b, Cmd.batch [ c, c2b ] )
                        )
                        ( m2, Cmd.none )
                        sessions
            in
            ( { m3 | closeSet = Set.empty, sessionManagerError = Nothing }
            , Cmd.batch
                [ planCmds
                , sessionCmds
                , Ports.deleteSessionDir { sessionId = id, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
                , Ports.setConnectionChain (chainPayload m3 m3.connectionChain)
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

        -- Global config overlay (cross-preset)
        OpenGlobalConfig ->
            ( { model
                | globalConfigEditor =
                    { emptyGlobalConfigEditor
                        | show = True
                        , loading = True
                    }
                , showGlobalMenu = False
              }
            , Ports.getGlobalConfig {}
            )

        CloseGlobalConfig ->
            let
                ed =
                    model.globalConfigEditor
            in
            if ed.syncing then
                -- Do not allow closing while a sync is in flight
                ( model, Cmd.none )

            else
                ( { model | globalConfigEditor = emptyGlobalConfigEditor }
                , Cmd.none
                )

        SetRecursionLimit val ->
            let
                ed =
                    model.globalConfigEditor
            in
            ( { model
                | globalConfigEditor =
                    { ed
                        | input = val
                        , error = Nothing
                    }
              }
            , Cmd.none
            )

        GlobalConfigSave ->
            let
                ed =
                    model.globalConfigEditor
            in
            case String.toInt (String.trim ed.input) of
                Just n ->
                    if n < 1 then
                        ( { model
                            | globalConfigEditor =
                                { ed
                                    | error = Just "Recursion limit must be >= 1"
                                }
                          }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | globalConfigEditor =
                                { ed
                                    | syncing = True
                                    , error = Nothing
                                }
                          }
                        , Ports.syncGlobalConfig { recursionLimit = n }
                        )

                Nothing ->
                    ( { model
                        | globalConfigEditor =
                            { ed
                                | error = Just "Recursion limit must be a positive integer"
                            }
                      }
                    , Cmd.none
                    )

        GlobalConfigGetResult raw ->
            case D.decodeValue globalConfigGetResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.globalConfigEditor
                    in
                    if res.ok then
                        ( { model
                            | globalConfig =
                                { recursionLimit = res.recursionLimit }
                            , globalConfigEditor =
                                { ed
                                    | loading = False
                                    , input = String.fromInt res.recursionLimit
                                    , error = Nothing
                                }
                          }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | globalConfigEditor =
                                { ed
                                    | loading = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        GlobalConfigSyncResult raw ->
            case D.decodeValue globalConfigSyncResultDecoder raw of
                Ok res ->
                    if res.ok then
                        ( { model
                            | globalConfig = { recursionLimit = res.recursionLimit }
                            , globalConfigEditor = emptyGlobalConfigEditor
                          }
                        , Cmd.none
                        )

                    else
                        let
                            ed =
                                model.globalConfigEditor
                        in
                        ( { model
                            | globalConfigEditor =
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

            -- Ctrl+W closes the FOCUSED window. Both a session
            -- (activeId) and a plan (planActiveId) can be "active" at
            -- once — clicking a plan raises it (top z) without clearing
            -- the session focus, so closing must follow the TOPMOST
            -- window. Otherwise "closing the plan" would close the
            -- session still focused below it (its OWNING session —
            -- the one above the plan — closing instead of the plan).
            else if key == "w" && ctrl then
                case planFocusAboveSession model of
                    Just pid ->
                        update (PlanClose pid) model

                    Nothing ->
                        case model.activeId of
                            Just sid ->
                                update (CloseSession sid) model

                            Nothing ->
                                case model.planActiveId of
                                    Just pid2 ->
                                        update (PlanClose pid2) model

                                    Nothing ->
                                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        ForSession sid innerMsg ->
            update innerMsg { model | activeId = Just sid }

        ResizeStart id handle mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    let
                        -- Raise the resized window (D6: bounded z).
                        m1 =
                            raiseWindow model id
                    in
                    ( { m1
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
                        , activeId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanResizeStart id handle mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    let
                        m1 =
                            raiseWindow model id
                    in
                    ( { m1
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
                        , planActiveId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        WindowDragStart id mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    let
                        m1 =
                            raiseWindow model id
                    in
                    ( { m1
                        | dragInfo =
                            Just
                                { sessionId = id
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                }
                        , activeId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        PlanWindowDragStart id mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    let
                        m1 =
                            raiseWindow model id
                    in
                    ( { m1
                        | dragInfo =
                            Just
                                { sessionId = id
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                }
                        , planActiveId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        CanvasDragStart mouseX mouseY ->
            -- Drag on the empty canvas background: pan the infinite
            -- canvas. Window mousedowns never reach here (panels
            -- stopPropagation), so this only fires on true background.
            ( { model
                | canvasDrag =
                    Just
                        { startMouseX = mouseX
                        , startMouseY = mouseY
                        , startOffsetX = model.canvasOffset.x
                        , startOffsetY = model.canvasOffset.y
                        }
              }
            , Cmd.none
            )

        CanvasZoom deltaY mouseX mouseY ->
            -- Wheel over the canvas: zoom centered on the cursor.
            -- Smooth exponential factor (deltaY in screen px; trackpads
            -- emit many small deltas, wheels ~±100 per notch).
            -- Re-emit the chain: curve stroke-width is compensated by
            -- canvasScale (3 / scale), so a zoom changes the drawing.
            let
                m1 =
                    applyZoom (e ^ (-deltaY * 0.0015)) mouseX mouseY model
            in
            ( m1
            , Ports.setConnectionChain (chainPayload m1 m1.connectionChain)
            )

        CanvasZoomReset ->
            -- Reset to 100% keeping the viewport center fixed.
            let
                m1 =
                    applyZoom (1 / model.canvasScale) (toFloat model.appWidth / 2) (toFloat model.appHeight / 2) model
            in
            ( m1
            , Ports.setConnectionChain (chainPayload m1 m1.connectionChain)
            )

        WindowDragMove mouseX mouseY ->
            case model.dragInfo of
                Just info ->
                    let
                        -- Mouse deltas are screen pixels; window coords
                        -- are canvas pixels (canvas layer scaled by
                        -- canvasScale), so divide to keep the window
                        -- glued to the cursor at any zoom level.
                        dx =
                            round ((mouseX - info.startMouseX) / model.canvasScale)

                        dy =
                            round ((mouseY - info.startMouseY) / model.canvasScale)

                        -- No viewport clamp: the canvas is unbounded and
                        -- the user recovers off-screen windows by panning.
                        newX =
                            info.startWinX + dx

                        newY =
                            info.startWinY + dy
                    in
                    ( { model
                        | windowPositions =
                            Dict.update info.sessionId
                                (Maybe.map (\pos -> { pos | x = newX, y = newY }))
                                model.windowPositions
                      }
                    -- Re-emit the chain (discrete redraw, Phase A): the
                    -- dragged window moved — curves follow it live.
                    , Ports.setConnectionChain
                        (chainPayload
                            { model
                                | windowPositions =
                                    Dict.update info.sessionId
                                        (Maybe.map (\pos -> { pos | x = newX, y = newY }))
                                        model.windowPositions
                            }
                            model.connectionChain
                        )
                    )

                Nothing ->
                    case model.canvasDrag of
                        Just cd ->
                            let
                                dx =
                                    round mouseX - round cd.startMouseX

                                dy =
                                    round mouseY - round cd.startMouseY

                                -- Pan offset is in SCREEN pixels (the
                                -- translate part of the transform), so
                                -- deltas need no scale division. The
                                -- safety bound grows with zoom (high zoom
                                -- covers a smaller canvas area).
                                maxPan =
                                    round (toFloat canvasMaxPan * model.canvasScale)

                                newX =
                                    clamp -maxPan maxPan (cd.startOffsetX + dx)

                                newY =
                                    clamp -maxPan maxPan (cd.startOffsetY + dy)
                            in
                            -- Canvas PAN needs no redraw: the connection
                            -- layer lives INSIDE .canvas, so the
                            -- transform carries the curves along.
                            ( { model | canvasOffset = { x = newX, y = newY } }
                            , Cmd.none
                            )

                        Nothing ->
                            let
                                ( m1, _ ) =
                                    handleResizeMove model mouseX mouseY
                            in
                            -- Window RESIZE (drag handle): curves follow
                            -- the resized edge live.
                            ( m1
                            , Ports.setConnectionChain (chainPayload m1 m1.connectionChain)
                            )

        WindowDragEnd ->
            ( { model | dragInfo = Nothing, resizeInfo = Nothing, canvasDrag = Nothing }, Cmd.none )

        ActivateSession id ->
            -- Always re-raise + rebuild the chain, even when this
            -- session is already `activeId`: focusing the plan window in
            -- between switched the chain away (and raised the plan
            -- chain), so clicking the session again must switch the
            -- chain back AND bring its windows back on top.
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
    , createdAt : String
    }


sessionDirDecoder : D.Decoder SessionDir
sessionDirDecoder =
    D.map2 SessionDir
        (D.field "id" D.string)
        (D.field "created_at" D.string)


decodeSessionDir : E.Value -> Maybe SessionDir
decodeSessionDir val =
    case D.decodeValue sessionDirDecoder val of
        Ok dir -> Just dir
        Err _ -> Nothing


-- File Picker Helpers

type alias ResolvedPathResult =
    { ok : Bool
    , resolved : String
    , exists : Bool
    , isDir : Bool
    , error : String
    }


resolvePathResultDecoder : D.Decoder ResolvedPathResult
resolvePathResultDecoder =
    D.map5 ResolvedPathResult
        (D.field "ok" D.bool)
        (D.field "resolved" D.string)
        (D.field "exists" D.bool)
        (D.field "isDir" D.bool)
        (D.field "error" D.string)


-- { ok, home, error } — fs_home_dir response.
fsHomeDirDecoder : D.Decoder { ok : Bool, home : String, error : String }
fsHomeDirDecoder =
    D.map3 (\ok home err -> { ok = ok, home = home, error = err })
        (D.field "ok" D.bool)
        (D.field "home" D.string)
        (D.field "error" D.string)


-- { ok, uri, error } — fs_read_file_data_uri response.
fsReadFileUriDecoder : D.Decoder { ok : Bool, uri : String, error : String }
fsReadFileUriDecoder =
    D.map3 (\ok uri err -> { ok = ok, uri = uri, error = err })
        (D.field "ok" D.bool)
        (D.field "uri" D.string)
        (D.field "error" D.string)


-- { ok, dirs, error } — list_session_dirs response.
sessionDirsDecoder : D.Decoder { ok : Bool, dirs : List D.Value, error : String }
sessionDirsDecoder =
    D.map3 (\ok dirs err -> { ok = ok, dirs = dirs, error = err })
        (D.field "ok" D.bool)
        (D.field "dirs" (D.list D.value))
        (D.field "error" D.string)


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


rpcErrorDecoder : D.Decoder { kind : String, sessionId : String, message : String }
rpcErrorDecoder =
    D.map3
        (\kind sessionId message -> { kind = kind, sessionId = sessionId, message = message })
        (D.field "kind" D.string)
        (D.field "sessionId" D.string)
        (D.field "message" D.string)


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


globalConfigGetResultDecoder : D.Decoder { ok : Bool, recursionLimit : Int, error : String }
globalConfigGetResultDecoder =
    D.map3
        (\ok recursionLimit error -> { ok = ok, recursionLimit = recursionLimit, error = error })
        (D.field "ok" D.bool)
        (D.field "recursion_limit" D.int)
        (D.field "error" D.string)


globalConfigSyncResultDecoder : D.Decoder { ok : Bool, recursionLimit : Int, error : String }
globalConfigSyncResultDecoder =
    D.map3
        (\ok recursionLimit error -> { ok = ok, recursionLimit = recursionLimit, error = error })
        (D.field "ok" D.bool)
        (D.field "recursion_limit" D.int)
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
