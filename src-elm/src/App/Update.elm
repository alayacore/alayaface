module App.Update exposing
    ( update
    , SessionDir
    , decodeSessionDir
    , nextCopyName
    , movePreset
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
import App.Pointer as P
import Plan.Update as PU exposing (..)
import Session.Types as T
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
import Ports
import Arch.Values as AV
import Arch.Freeze as Freeze


{-| Start the next item in the freeze queue (serial: one at a time, reqId
only matches the active item). Empty queue → clear freezeActive.
-}
startNextFreeze : Model -> ( Model, Cmd Msg )
startNextFreeze model =
    case model.freezeQueue of
        next :: rest ->
            let
                putCmds =
                    Freeze.initialPuts next
                        |> List.map
                            (\( reqId, content ) ->
                                Ports.objectPut { reqId = String.fromInt reqId, content = content }
                            )
            in
            ( { model | freezeActive = Just next, freezeQueue = rest }, Cmd.batch putCmds )

        [] ->
            ( { model | freezeActive = Nothing }, Cmd.none )


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
scopeCtx : Model -> { planMetas : Dict String PM.PlanMeta, runs : Dict String (Maybe PT.RunState), sessions : Dict String T.SessionState }
scopeCtx model =
    { planMetas = model.planMetas
    , runs = Dict.map (\_ w -> w.run) model.planWindows
    , sessions = model.sessions
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


{-| C architecture: object_put result ({ reqId, ok, hash, error }).
-}
objectPutResultDecoder : D.Decoder { reqId : String, ok : Bool, hash : String, error : String }
objectPutResultDecoder =
    D.map4
        (\reqId ok hash error -> { reqId = reqId, ok = ok, hash = hash, error = error })
        (D.field "reqId" D.string)
        (D.field "ok" D.bool)
        (D.field "hash" D.string)
        (D.field "error" D.string)


{-| C architecture: object_get result ({ reqId, ok, content, error }).
-}
objectGetResultDecoder : D.Decoder { reqId : String, ok : Bool, content : String, error : String }
objectGetResultDecoder =
    D.map4
        (\reqId ok content error -> { reqId = reqId, ok = ok, content = content, error = error })
        (D.field "reqId" D.string)
        (D.field "ok" D.bool)
        (D.field "content" D.string)
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


{-| Close this session's close-confirmation overlay (per-session state).
Used by the confirm choice (before closing/deleting) and by Cancel.
-}
clearCloseConfirm : String -> Model -> Model
clearCloseConfirm id model =
    { model
        | sessions =
            Dict.update id
                (Maybe.map (\s -> { s | closeConfirm = False }))
                model.sessions
    }


{-| The session whose close-confirmation overlay Escape should dismiss:
the ACTIVE session if its overlay is open, otherwise any session with
one open (a per-session overlay may linger after the user switched to
another window).
-}
pendingCloseConfirmId : Model -> Maybe String
pendingCloseConfirmId model =
    case model.activeId of
        Just sid ->
            case Dict.get sid model.sessions of
                Just s ->
                    if s.closeConfirm then
                        Just sid

                    else
                        firstCloseConfirm model

                Nothing ->
                    firstCloseConfirm model

        Nothing ->
            firstCloseConfirm model


firstCloseConfirm : Model -> Maybe String
firstCloseConfirm model =
    Dict.foldl
        (\sid s acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    if s.closeConfirm then
                        Just sid

                    else
                        Nothing
        )
        Nothing
        model.sessions


{-| Close this session's cancel-task confirmation overlay (per-session
state). Used by the confirm choice (before aborting) and by Dismiss.
-}
clearCancelTaskConfirm : String -> Model -> Model
clearCancelTaskConfirm sid model =
    { model
        | sessions =
            Dict.update sid
                (Maybe.map (\s -> { s | cancelTaskConfirm = False }))
                model.sessions
    }


{-| The session whose cancel-task confirmation overlay Escape should
dismiss: the ACTIVE session if its overlay is open, otherwise any
session with one open.
-}
pendingCancelConfirmId : Model -> Maybe String
pendingCancelConfirmId model =
    case model.activeId of
        Just sid ->
            case Dict.get sid model.sessions of
                Just s ->
                    if s.cancelTaskConfirm then
                        Just sid

                    else
                        firstCancelConfirm model

                Nothing ->
                    firstCancelConfirm model

        Nothing ->
            firstCancelConfirm model


firstCancelConfirm : Model -> Maybe String
firstCancelConfirm model =
    Dict.foldl
        (\sid s acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    if s.cancelTaskConfirm then
                        Just sid

                    else
                        Nothing
        )
        Nothing
        model.sessions


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


{-| Shared send path for SendPrompt and the raw-audio flow: builds the
media list from the session's staged items, clears the input, marks the
prompt pending, and fires the sendPrompt port (the backend packs the
staged URIs into UA/UI/UV/UD frames + UE).
-}
doSendPrompt : Model -> T.SessionState -> ( Model, Cmd Msg )
doSendPrompt model s =
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
            { sessionId = PU.workCopyId model s.id
            , text = text
            , media = mediaItems
            }
        )


{-| Update one field of the ASR config editor (the Msg payload already
carries the new value; only the field selector differs). Clears any
previous error so the user can fix the field without dismissing the
message first.
-}
setAsrEditorField : Model -> (AsrConfigEditor -> AsrConfigEditor) -> ( Model, Cmd Msg )
setAsrEditorField model updateEditor =
    ( { model | asrConfigEditor = updateEditor model.asrConfigEditor }
    , Cmd.none
    )


findAsrProfile : String -> List AsrProfile -> Maybe AsrProfile
findAsrProfile profileId profiles =
    List.filter (\p -> p.id == profileId) profiles |> List.head


asrProfileEncoder : AsrProfile -> E.Value
asrProfileEncoder p =
    E.object
        [ ( "id", E.string p.id )
        , ( "name", E.string p.name )
        , ( "protocol", E.string p.protocol )
        , ( "url", E.string p.url )
        , ( "api_key", E.string p.apiKey )
        , ( "model", E.string p.model )
        , ( "language", E.string p.language )
        ]


{-| Encode the full ASR config (active + profiles) for sync_asr_config.
-}
asrConfigJson : { active : String } -> List AsrProfile -> E.Value
asrConfigJson active profiles =
    E.object
        [ ( "active", E.string active.active )
        , ( "profiles", E.list asrProfileEncoder profiles )
        ]


{-| Append a local error message to the session's message list (same
shape as backend Error frames, id = "err-" + message count so it stays
unique within the session). Used for voice-input failures: the user
asked for errors to appear in the message display, not in a status line.
-}
appendErrorMsg : T.SessionState -> String -> T.SessionState
appendErrorMsg s text =
    { s
        | messages =
            s.messages
                ++ [ { id = "err-" ++ String.fromInt (List.length s.messages)
                     , role = T.Error
                     , content = text
                     , toolId = Nothing
                     , toolName = Nothing
                     , isError = True
                     , historyId = Nothing
                     , media = Nothing
                     }
                   ]
    }


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
                                (R.SessionDisconnected id "Session window closed")
                        )
                        Time.now

                Nothing ->
                    Cmd.none

        -- Bind the updated model so the Cmd below sees the post-drop
        -- chain and post-remove windowPositions (anonymous record updates
        -- don't rebind `model` — the original parameter stays in scope,
        -- so `chainPayload model model.connectionChain` would re-emit
        -- the stale payload containing the closing session's segment).
        m1 =
            { model
                | sessions = Dict.remove id model.sessions
                , sessionOrder = List.filter (\k -> k /= id) model.sessionOrder
                , sessionNums = Dict.remove id model.sessionNums
                , windowPositions = Dict.remove id model.windowPositions
                , planNodeSessions = Dict.remove id model.planNodeSessions
                , planTaskStarted = Set.remove id model.planTaskStarted
                , connectionChain = dropChainSession model.connectionChain id
                , sessionWorkCopies = Dict.remove id model.sessionWorkCopies
                -- C2b: on close, drop the session's temporary resume-live marker (the live is dead).
                , sessionResumedLives =
                    Set.remove (PU.workCopyId model id) (Set.remove id model.sessionResumedLives)
                , activeId =
                    if model.activeId == Just id then
                        List.head (List.reverse (List.filter (\k -> k /= id) model.sessionOrder))

                    else
                        model.activeId
                }
    in
    ( m1
    , Cmd.batch
        [ -- C2b (I-E): close the work-copy process (core id); the frontend
          -- entry by Session.id was already removed in the sessions/… update above.
          Ports.closeSession { sessionId = PU.workCopyId model id }
        , runnerFailCmd
        , Ports.setConnectionChain (chainPayload m1 m1.connectionChain)
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


{-| C2b (I-G): is this core id the **current** work copy of its Session?
Late frames/disconnects from an OLD work copy (replaced by a fork) would
pollute the new entry if routed by Session.id — the "current work copy"
guard drops them. Plain sessions (no mapping) are always True. Node
sessions (no mapping) are likewise always True (behavior unchanged pre-C3).
-}
isCurrentWorkCopy : Model -> String -> Bool
isCurrentWorkCopy model coreId =
    let
        sid =
            PU.sessionIdOfWorkCopy model coreId
    in
    PU.workCopyId model sid == coreId


{-| C2b/C3: an in-flight cascade fork (top-level or node) always goes
through work-copy replacement (forkSessionCreated) — the window key
Session.id (plan origin) is stable, and the forked session is just a
work copy. Node forks no longer create a new window/new identity
(C3-1: "cascade fork handoff" removed).
-}
isCascadeForkActive : Model -> Bool
isCascadeForkActive model =
    model.planCascadeFork /= Nothing


{-| C2b/C3 fork branch (§8.1): a cascade fork takes over the same
Session (top-level or node session, same rules):
- The window key stays Session.id (= plan origin `meta.origin.sessionId`,
  NOT forkSource — that is the old work copy, which may have resume differences).
- sessionWorkCopies[Session.id] = forkId (new work copy); buffered frames
  are routed by it back into sessions[Session.id] (overwriting old content).
- planReplaySessions marks Session.id (replaying history does not
  auto-create plans).
- No sessionOrder / sessionNums / windowPositions entries are created
  (the window did not change, so position is naturally preserved — no
  forkInheritPos needed); no lineage is written.
- The old work-copy process/directory is closed by RegisterFork
  (registerForkInstance).
-}
forkSessionCreated : String -> Model -> ( Model, Cmd Msg )
forkSessionCreated forkId model =
    let
        sessionId =
            case model.planCascadeFork of
                Just target ->
                    Dict.get target.childPlanId model.planMetas
                        |> Maybe.map (.origin >> .sessionId)
                        |> Maybe.withDefault forkId

                Nothing ->
                    forkId

        -- Build the mapping first, then replay the buffer: core id (forkId) → Session.id.
        newWorkCopies =
            Dict.insert sessionId forkId model.sessionWorkCopies

        newSessions =
            Dict.insert sessionId (T.emptySession sessionId) model.sessions

        buffered =
            Dict.get forkId model.pendingEvents |> Maybe.withDefault []

        sessionsAfterBuffer =
            List.foldl
                (applyPendingEvent (PU.sessionIdOfWorkCopyDict newWorkCopies))
                newSessions
                buffered

        m0 =
            { model
                | sessionWorkCopies = newWorkCopies
                , sessions = sessionsAfterBuffer
                , activeId = Just sessionId
                , planMessageCounts =
                    case Dict.get sessionId sessionsAfterBuffer of
                        Just s ->
                            Dict.insert sessionId (planIndexForMessage s.messages) model.planMessageCounts

                        Nothing ->
                            model.planMessageCounts
                , planReplaySessions = Set.insert sessionId model.planReplaySessions
                , pendingEvents = Dict.remove forkId model.pendingEvents
            }

        cmds =
            Cmd.batch
                [ Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ sessionId))
                , Ports.scrollToBottom { sessionId = sessionId }
                ]
    in
    ( m0, cmds )


{-| C2b/C3: the on-disk directory a session resumes from — its current
work-copy directory (refs.workCopy; after fork/resume = the fork
directory; no record = itself = root/original directory). Shared by
top-level and node sessions (ResumeSession / PlanOpenNodeSession).
-}
resumeDirFor : Model -> String -> String
resumeDirFor model sid =
    Dict.get sid model.sessionRefs
        |> Maybe.andThen .workCopy
        |> Maybe.withDefault sid


{-| C3/C5: is this a resume (top-level resume from the session manager
or a DAG node resume)? Resumes uniformly go through work-copy ownership
(resumeSessionCreated) — the window key = Session.id (= the directory id
passed to resume), and the live session is just a work copy; a node
resume's planNodeSessions binding was inserted at request time, and the
chain is built inside resumeSessionCreated.
-}
isResumeActive : Model -> Bool
isResumeActive model =
    model.planResumeFrom /= Nothing


{-| C2b/C5 resume branch (§8.1): a resume does not create a new
identity — the live session returned by the backend is just a new work
copy of the same Session (top-level or node session, same rules):
- Session.id = on-disk directory id (= the dir id passed to resume).
- sessionWorkCopies[Session.id] = liveId; sessions[Session.id] is
  replaced with the live content (buffered frames route via workCopies,
  so liveId frames land on Session.id).
- Window key = Session.id: window closed (the usual resume case) →
  create window entries as usual; still open (defensive) → reuse it.
- Node resume: connection chain built + whole-chain z raise
  (planNodeSessions binding was inserted at request time).
- planReplaySessions is already marked by ResumeSession/
  PlanOpenNodeSession with Session.id; no planResumedFrom is created
  (C2b/C5 eliminate the live→orig map).
-}
resumeSessionCreated : String -> Model -> ( Model, Cmd Msg )
resumeSessionCreated liveId model =
    let
        sessionId =
            Maybe.withDefault liveId model.planResumeFrom

        newWorkCopies =
            Dict.insert sessionId liveId model.sessionWorkCopies

        newSessions =
            Dict.insert sessionId (T.emptySession sessionId) model.sessions

        buffered =
            Dict.get liveId model.pendingEvents |> Maybe.withDefault []

        sessionsAfterBuffer =
            List.foldl
                (applyPendingEvent (PU.sessionIdOfWorkCopyDict newWorkCopies))
                newSessions
                buffered

        planCounts1 =
            case Dict.get sessionId sessionsAfterBuffer of
                Just s ->
                    Dict.insert sessionId (planIndexForMessage s.messages) model.planMessageCounts

                Nothing ->
                    model.planMessageCounts

        base =
            { model
                | sessionWorkCopies = newWorkCopies
                , sessions = sessionsAfterBuffer
                , planMessageCounts = planCounts1
                , planReplaySessions = Set.insert sessionId model.planReplaySessions
                , pendingEvents = Dict.remove liveId model.pendingEvents
                , planResumeFrom = Nothing
                , planResumeOwner = Nothing
                , activeId = Just sessionId
                , pendingSwitchOnCreate = False
                -- C2b: record the temporary resume live (no on-disk
                -- directory; persistableWorkCopy relies on it to not
                -- write the live into refs.workCopy).
                , sessionResumedLives = Set.insert liveId model.sessionResumedLives
            }

        -- Window closed (the usual case): create window entries (key = Session.id).
        m1 =
            if Dict.member sessionId model.windowPositions then
                base

            else
                { base
                    | sessionOrder = base.sessionOrder ++ [ sessionId ]
                    , sessionNums = Dict.insert sessionId base.nextSessionNum base.sessionNums
                    , nextSessionNum = base.nextSessionNum + 1
                    , windowPositions = Dict.insert sessionId (centeredSessionPos base) base.windowPositions
                }

        raised =
            raiseWindow m1 sessionId

        -- C3/C5: the node resume's connection chain (node↔plan segment +
        -- ancestor segments) — sessions are already keyed by Session.id
        -- (= node session id), so the chain builds directly.
        chain =
            connectionChainForSession raised sessionId

        ( raisedPositions, raisedNextZ ) =
            raiseChainWindows raised chain

        positions =
            if List.isEmpty chain then
                raised.windowPositions

            else
                raisedPositions

        zBump =
            if List.isEmpty chain then
                0

            else
                raisedNextZ - raised.nextZIndex

        final =
            { raised
                | connectionChain = chain
                , windowPositions = positions
                , nextZIndex = raised.nextZIndex + zBump
            }

        cmds =
            Cmd.batch
                [ Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ sessionId))
                , Ports.scrollToBottom { sessionId = sessionId }
                , Ports.setConnectionChain (chainPayload final final.connectionChain)
                ]
    in
    ( final, cmds )


{-| Usual creation of a new session window (plain New Session / resume /
runner node session / node cascade fork). After C2b this only handles
those paths — top-level forks go through forkSessionCreated.
-}
createSessionWindow : String -> Model -> ( Model, Cmd Msg )
createSessionWindow id model =
    let
        newSession =
            T.emptySession id

        newSessions =
            Dict.insert id newSession model.sessions

        -- Replay any buffered events that arrived before this session was registered
        buffered =
            Dict.get id model.pendingEvents |> Maybe.withDefault []

        sessionsAfterBuffer =
            List.foldl (applyPendingEvent (\core -> core)) newSessions buffered

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

        -- C2b (§8.1): a plain top-level creation (not runner / resume /
        -- node fork) — initialize the Session root refs (session.refs.json,
        -- empty head): having refs marks a Session root, which is what
        -- the session manager lists and restart recovery relies on.
        isPlainRootCreate =
            model.planResumeFrom == Nothing && model.planCascadeFork == Nothing && not isRunnerCreate

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
                -- C2b: a plain top-level creation registers empty refs
                -- (Session root; the manager's listing basis)
                , sessionRefs =
                    if isPlainRootCreate then
                        Dict.insert id (AV.SessionRefs id "" [] Nothing) model.sessionRefs

                    else
                        model.sessionRefs
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
                            -- C3: cascade forks all go through work-copy
                            -- replacement (window key unchanged) — no
                            -- forkInheritPos. Runner-created /
                            -- resumed node session opens beside its plan
                            -- window (stacking with an offset); plain
                            -- creates center on the viewport.
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
        -- counter crosses the threshold).
        -- C3/C5: resumes (top-level/node) uniformly go through
        -- resumeSessionCreated (window key = Session.id);
        -- createSessionWindow no longer handles resume.
        raisedModel =
            raiseWindow baseModel id

        -- Consume the in-flight marker for user creates (runner
        -- creates are consumed inside PlanBindSession).
        settledModel =
            case model.planCreating of
                Just (UserCreate _) ->
                    { raisedModel | planCreating = Nothing }

                _ ->
                    raisedModel

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
        -- C2b: initialize the Session root refs (session.refs.json,
        -- empty head) — having refs marks a Session root (the manager
        -- listing / restart-recovery basis). The lineage
        -- session.meta.json was removed (C2b-7).
        , if isPlainRootCreate then
            Ports.fsWriteFileText
                { path = sessionsDir model.homeDir ++ "/" ++ id ++ "/session.refs.json"
                , content = AV.refsContent (AV.SessionRefs id "" [] Nothing)
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


{-| Is this message id the last (bottom-most) message of the session?
Used by ToggleMsgCollapse to decide whether an expand should re-pin the
viewport to the bottom.
-}
isLastMessage : String -> T.SessionState -> Bool
isLastMessage msgId s =
    case List.head (List.reverse s.messages) of
        Just m ->
            m.id == msgId

        Nothing ->
            False


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
        -- The user picked a preset from the global menu's hover submenu;
        -- every session runs under an explicit preset (no active preset).
        -- The system prompt is left to the backend: it resolves the
        -- preset's system_prompt from settings.conf.
        CreateSessionWith preset ->
            case model.planCreating of
                -- A session create is in flight: queue the user's create
                -- on the same serialized queue so the runner's
                -- SessionCreated cannot be misbound to it.
                Just _ ->
                    ( { model | planCreateQueue = model.planCreateQueue ++ [ UserCreate preset ], showGlobalMenu = False }
                    , Cmd.none
                    )

                Nothing ->
                    ( { model
                        | pendingSwitchOnCreate = True
                        , showGlobalMenu = False
                        -- Tag the in-flight marker so SessionCreated can
                        -- attribute this create (and queue ordering is
                        -- preserved for every user create, not just the
                        -- plan runner's).
                        , planCreating = Just (UserCreate preset)
                      }
                    , Ports.createSession { toolConfirm = Nothing, preset = Just preset, builtinTools = Nothing, systemPrompt = Nothing, workDir = Nothing, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
                    )

        SessionCreated id ->
            -- C2b/C3 (§8.1): a cascade fork (top-level or node) does
            -- not create a new window — the forked session is just a new
            -- work copy of the same Session (window key = Session.id =
            -- plan origin, unchanged). Top-level resumes likewise.
            -- Node forks also go here (C3-1: "cascade fork handoff" removed);
            -- node resumes / plain creates go through createSessionWindow.
            if isCascadeForkActive model then
                forkSessionCreated id model

            else if isResumeActive model then
                resumeSessionCreated id model

            else
                -- Push-to-talk attribution (hold Ctrl+" to talk): the create
                -- that just finished is the PT one iff the in-flight
                -- marker is a UserCreate "Talk", a PT keydown armed it
                -- (ptCreatePending) and the key is still held — then the
                -- new session auto-starts ASR recording. A plain menu
                -- create of the Talk preset has no ptCreatePending; a
                -- keyup while the create is in flight clears it. (The
                -- marker is read BEFORE createSessionWindow, which
                -- consumes planCreating internally.)
                let
                    isPtCreate =
                        model.ptCreatePending
                            && model.ptHeld
                            && model.planCreating == Just (UserCreate "Talk")

                    ( m1, c1 ) =
                        createSessionWindow id model

                    m2 =
                        { m1
                            | ptCreatePending =
                                if isPtCreate then
                                    False

                                else
                                    m1.ptCreatePending
                            , ptSessionId =
                                if isPtCreate then
                                    Just id

                                else
                                    m1.ptSessionId
                            -- Mirror the VoiceInput start branch: the
                            -- recording state must be visible (red pulse)
                            -- and PushToTalk False checks voiceActive to
                            -- decide whether to stop.
                            , sessions =
                                if isPtCreate then
                                    Dict.update id
                                        (Maybe.map (\s -> { s | voiceActive = True }))
                                        m1.sessions

                                else
                                    m1.sessions
                        }
                in
                ( m2
                , Cmd.batch
                    [ c1
                    , if isPtCreate then
                        Ports.voiceStart { sessionId = id }

                      else
                        Cmd.none
                    ]
                )
        SessionCreateError text ->
            -- create_session failed. Without this the in-flight marker
            -- (planCreating) would stay set forever: every later create
            -- queues behind it and the run deadlocks (e.g. invalid node
            -- preset). Fail the pending node so retry/backoff applies,
            -- then drain the queue.
            --
            -- Also drop the buffered early frames of the failed create:
            -- the backend broadcasts core-status connected:true BEFORE
            -- the RPC reply, so a create whose response was lost buffers
            -- that frame keyed by the never-registered core id — no
            -- SessionCreated will ever arrive to flush it, and it would
            -- leak in pendingEvents forever. With the serialized create
            -- queue every buffered entry belongs to the failed create,
            -- so the whole buffer can go; a concurrent resume or
            -- cascade-fork (rare, and its live id is unknown to us) is
            -- the only case where the buffer is left alone.
            let
                m0 =
                    if model.planResumeFrom == Nothing && model.planCascadeFork == Nothing then
                        { model | pendingEvents = Dict.empty }

                    else
                        model

                -- A failed push-to-talk create: disarm the auto-start so
                -- a LATER SessionCreated (from the next queued create)
                -- is never mistaken for the PT one. A failure of some
                -- other create (e.g. a runner) leaves the PT marker
                -- alone — its own create is still queued behind.
                m0b =
                    case m0.planCreating of
                        Just (UserCreate "Talk") ->
                            { m0
                                | ptCreatePending = False
                                , ptSessionId = Nothing
                            }

                        _ ->
                            m0
            in
            case m0b.planCreating of
                Just (RunnerCreate planId nodeId) ->
                    let
                        m1 =
                            { m0b | planCreating = Nothing }

                        ( m2, c2 ) =
                            runStepIn update planId 0 (R.SessionCreateFailed nodeId text) m1

                        ( m3, c3 ) =
                            startNextCreateIn m2
                    in
                    ( m3, c3 )

                Just (UserCreate _) ->
                    -- A user-initiated create failed: clear the marker and
                    -- continue with the next queued create.
                    let
                        m1 =
                            { m0b | planCreating = Nothing }
                    in
                    startNextCreateIn m1

                Nothing ->
                    ( m0b, Cmd.none )

        RequestCloseSession id ->
            -- User-initiated close (window ✕ or Ctrl+W): show THIS
            -- session's confirm overlay instead of closing — Close
            -- (keep the conversation on disk) / Close and Delete
            -- (remove files) / Cancel. The pending state lives on the
            -- SessionState (per-session overlay, like pendingConfirm);
            -- internal closes (plans, runners) still call CloseSession
            -- directly and never prompt.
            -- Focus the "Close" button (the default): autofocus alone
            -- is blocked when the prompt input already holds focus, so
            -- the Dom.focus command forces it — Enter then confirms the
            -- default instead of sending a message.
            ( { model
                | sessions =
                    Dict.update id
                        (Maybe.map (\s -> { s | closeConfirm = True }))
                        model.sessions
              }
            , Task.attempt (\_ -> NoOp) (Dom.focus "close-confirm-close")
            )

        ConfirmCloseSession id ->
            update (CloseSession id) (clearCloseConfirm id model)

        ConfirmDeleteSession id ->
            update (DeleteSession id) (clearCloseConfirm id model)

        DismissCloseConfirm sid ->
            ( clearCloseConfirm sid model, focusInput model )

        RequestCancelTask sid ->
            -- User-initiated task cancel (send button's Cancel state, or
            -- Ctrl+G): show THIS session's confirm overlay instead of
            -- aborting. Per-session state like closeConfirm. Focus the
            -- default "Cancel task" button (Dom.focus — autofocus is
            -- blocked when the prompt input already holds focus).
            ( { model
                | sessions =
                    Dict.update sid
                        (Maybe.map (\s -> { s | cancelTaskConfirm = True }))
                        model.sessions
              }
            , Task.attempt (\_ -> NoOp) (Dom.focus "cancel-task-confirm")
            )

        ConfirmCancelTask sid ->
            ( clearCancelTaskConfirm sid model
            , Ports.cancelTask { sessionId = PU.workCopyId model sid }
            )

        DismissCancelTask sid ->
            ( clearCancelTaskConfirm sid model, focusInput model )

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
                    -- C2b (I-G): only handle frames from the CURRENT work
                    -- copy — late frames/disconnects from an old work copy
                    -- (replaced by a fork) would pollute the new entry.
                    if not (isCurrentWorkCopy model ev.sessionId) then
                        ( model, Cmd.none )

                    else
                        -- C2b (I-D): frame core id → Session.id (work-copy
                        -- frame; plain session = identity).
                        let
                            sid =
                                PU.sessionIdOfWorkCopy model ev.sessionId
                        in
                            case Dict.get sid model.sessions of
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
    
                                    -- scrollToBottom is frontend DOM scrolling:
                                    -- elements are named by window key
                                    -- (Session.id), so pass sid, not coreId.
                                    cmds =
                                        if session.atBottom then
                                            Ports.scrollToBottom { sessionId = sid }
                                        else
                                            Cmd.none
                                in
                                ( { model
                                    | sessions = Dict.insert sid newSession model.sessions
                                    , planMessageCounts = bumpPlanCount model.planMessageCounts sid becamePlan
                                  }
                                , cmds
                                )
    
                            -- Buffering is still keyed by core id (replayed
                            -- with routing once SessionCreated sets up
                            -- workCopies).
                            Nothing ->
                                bufferPendingEvent model ev.sessionId raw
    
                Err _ ->
                    ( model, Cmd.none )

        FrameEvent raw ->
            case D.decodeValue P.frameEventDecoder raw of
                Ok ev ->
                    -- C2b (I-G): only handle frames from the current work copy.
                    if not (isCurrentWorkCopy model ev.sessionId) then
                        ( model, Cmd.none )

                    else
                        -- C2b（I-D）：core id → Session.id。
                        let
                            sid =
                                PU.sessionIdOfWorkCopy model ev.sessionId
                        in
                            case Dict.get sid model.sessions of
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
    
                                    -- The core's explicit readiness signal
                                    -- (SM {"type":"session","data":
                                    -- {"state":"ready"}}): MCP init done,
                                    -- replay ended, session interactive.
                                    readyNow =
                                        isSessionReady ev
    
                                    newSession =
                                        H.handleFrameEvent session ev
    
                                    -- A user echo (UT/UI/UV/UA/UD) is the
                                    -- user's OWN action — sent from the
                                    -- always-visible input bar, possibly
                                    -- while scrolled up reading history.
                                    -- Always bring it into view: chat UX
                                    -- requires the new user message to be
                                    -- visible regardless of auto-follow
                                    -- state (atBottom).
                                    userEchoNow =
                                        P.isUserEchoTag ev.tag
    
                                    mcpJustCompleted =
                                        session.mcpStatus /= Nothing && newSession.mcpStatus == Nothing
    
                                    -- A node prompt held by the readiness gate
                                    -- (pendingNodePrompts) is flushed the
                                    -- moment the session becomes ready.
                                    flushPendingCmd =
                                        if readyNow then
                                            case Dict.get sid model.pendingNodePrompts of
                                                Just text ->
                                                    Ports.sendPrompt { sessionId = sid, text = text, media = [] }
    
                                                Nothing ->
                                                    Cmd.none
    
                                        else
                                            Cmd.none
    
                                    -- scrollToBottom is frontend DOM scrolling:
                                    -- elements are named by window key
                                    -- (Session.id), so pass sid.
                                    --
                                    -- Auto-follow re-pins on EVERY frame, not
                                    -- just message-count changes: frames that
                                    -- only grow an EXISTING message's content
                                    -- (Af tool-arg deltas, UF tool results, Uf
                                    -- previews, complete AT/AR replacements,
                                    -- media appended to a user echo) also push
                                    -- content below the fold. Gating on
                                    -- msgCountChanged left the viewport stuck
                                    -- until the next assistant-text delta
                                    -- created a new message. State-only frames
                                    -- (SM status, model sync…) are a harmless
                                    -- no-op: at the bottom, scrollTop =
                                    -- scrollHeight changes nothing.
                                    --
                                    -- User echoes are the exception to the
                                    -- atBottom gate: they are the user's own
                                    -- send, so the page always follows them
                                    -- (see userEchoNow above).
                                    cmds =
                                        Cmd.batch
                                            [ flushPendingCmd
                                            , if session.atBottom || userEchoNow then
                                                Ports.scrollToBottom { sessionId = sid }
                                              else
                                                Cmd.none
                                            ]
    
                                    updatedModel =
                                        { model
                                            | sessions = Dict.insert sid { newSession | ready = newSession.ready || readyNow } model.sessions
                                            , pendingNodePrompts =
                                                if readyNow then
                                                    Dict.remove sid model.pendingNodePrompts
    
                                                else
                                                    model.pendingNodePrompts
                                            , planMessageCounts = bumpPlanCount model.planMessageCounts sid becamePlan
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
                                                if readyNow then
                                                    Set.remove sid model.planReplaySessions
    
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
                                                            planCountOf updatedModel.planMessageCounts sid
                                                    in
                                                    if m.role == T.Assistant
                                                        && not (Set.member sid updatedModel.planReplaySessions)
                                                        && not (Dict.member ( sid, planIdx ) updatedModel.pendingPlanOffers)
                                                        && not (messageBoundToPlan updatedModel sid planIdx) then
                                                        case Plan.Detect.extractPlanJson m.content of
                                                            Just offerRaw ->
                                                                if Plan.Detect.hasPlanTypeMarker offerRaw then
                                                                    -- Live plan message: create + auto-open immediately. History
                                                                    -- replays (resumed sessions) are suppressed via
                                                                    -- planReplaySessions — their plan messages show the manual
                                                                    -- "Open plan" button instead.
                                                                    Task.perform (\_ -> PlanCreateOffer sid planIdx) Time.now
    
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
                                                            planCountOf updatedModel.planMessageCounts sid
                                                    in
                                                    if m.role == T.Assistant
                                                        && not (Set.member sid updatedModel.planReplaySessions)
                                                        && not (Dict.member ( sid, planIdx ) updatedModel.pendingPlanOffers)
                                                        && not (messageBoundToPlan updatedModel sid planIdx) then
                                                        case Plan.Detect.extractPlanJson m.content of
                                                            Just offerRaw ->
                                                                if Plan.Detect.hasPlanTypeMarker offerRaw then
                                                                    { updatedModel | pendingPlanOffers = Dict.insert ( sid, planIdx ) offerRaw updatedModel.pendingPlanOffers }
    
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
                                            update (ForSession sid (ModelSelectorSyncResult isError message)) updatedModel3
    
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
                    -- C2b (I-G): only handle status events from the CURRENT
                    -- work copy (a connected:false from an old work copy
                    -- being closed must not pollute the new entry).
                    if not (isCurrentWorkCopy model ev.sessionId) then
                        ( model, Cmd.none )

                    else
                        let
                            -- C2b (I-D): core id → Session.id (sessions update
                            -- by Session.id; runner injection/buffering still
                            -- by core id).
                            sid =
                                PU.sessionIdOfWorkCopy model ev.sessionId

                            -- Runner injection: a node-owned session that
                            -- disconnects before task completion is a failure.
                            -- C3: route by Session.id (node binding =
                            -- Session.id; after fork/resume frames come from
                            -- the work-copy core id).
                            statusRunnerCmd =
                                if not ev.connected then
                                    case findPlanIdBySession model sid of
                                        Just _ ->
                                            Task.perform
                                                (\t ->
                                                    PlanRunFrame (Time.posixToMillis t)
                                                        (R.SessionDisconnected sid ev.message)
                                                )
                                                Time.now

                                        Nothing ->
                                            Cmd.none

                                else
                                    Cmd.none
                        in
                            case Dict.get sid model.sessions of
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
                                        | sessions = Dict.insert sid
                                            { updated
                                                | modelSelector = Sel.syncFailed "Session disconnected during sync" updated.modelSelector
                                            }
                                            model.sessions
                                      }
                                    , statusRunnerCmd
                                    )
    
                                else
                                    ( { model
                                        | sessions = Dict.insert sid updated model.sessions
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
                    -- C2b (I-G): RPC errors sent to an OLD work copy are
                    -- stale — ignore.
                    if not (isCurrentWorkCopy model err.sessionId) then
                        ( model, Cmd.none )

                    else
                        -- C2b: the sessionId on an RPC error is the core id
                        -- we sent the backend (workCopyId) — reverse-look up
                        -- Session.id, then update the session entry.
                        let
                            sid =
                                PU.sessionIdOfWorkCopy model err.sessionId
                        in
                            case Dict.get sid model.sessions of
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
                                        Dict.insert sid
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
                    doSendPrompt model s

                Nothing ->
                    ( model, Cmd.none )

        CancelTask ->
            case model.activeId of
                Just id ->
                    ( model
                    , Ports.cancelTask { sessionId = PU.workCopyId model id }
                    )

                Nothing ->
                    ( model, Cmd.none )

        VoiceInput ->
            -- Toggle voice recording: click starts the mic (recording
            -- state persists), click again stops it and transcribes.
            -- The state is visible on the mic button itself (red pulse
            -- while recording; while transcribing the button turns into
            -- a red cancel — see CancelAsr).
            case getActiveSession model of
                Just s ->
                    if s.asrBusy then
                        -- A transcription is in flight; the mic button
                        -- is a cancel now (CancelAsr), so VoiceInput
                        -- only arrives from the other two states.
                        ( model, Cmd.none )

                    else if s.voiceActive then
                        ( { model
                            | sessions =
                                Dict.insert s.id
                                    { s
                                        | voiceActive = False
                                        , asrBusy = True
                                    }
                                    model.sessions
                          }
                        , Ports.voiceStop { sessionId = s.id }
                        )

                    else
                        ( { model
                            | sessions =
                                Dict.insert s.id
                                    { s
                                        | voiceActive = True
                                    }
                                    model.sessions
                          }
                        , Ports.voiceStart { sessionId = s.id }
                        )

                Nothing ->
                    ( model, Cmd.none )

        CancelAsr ->
            -- Abandon a pending transcription: the input stays locked
            -- until the ASR result arrives, so the mic button becomes a
            -- cancel. The backend call cannot be aborted mid-flight, so
            -- we just mark the session and drop the result when it
            -- shows up (AsrResult checks asrDiscard).
            case getActiveSession model of
                Just s ->
                    if s.asrBusy then
                        ( { model
                            | pendingVoiceInsert =
                                case model.pendingVoiceInsert of
                                    Just p ->
                                        if p.sessionId == s.id then
                                            Nothing

                                        else
                                            model.pendingVoiceInsert

                                    Nothing ->
                                        Nothing
                            , sessions =
                                Dict.insert s.id
                                    { s
                                        | voiceActive = False
                                        , asrBusy = False
                                        , asrDiscard = True
                                    }
                                    model.sessions
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        RawAudioInput ->
            -- Toggle raw audio recording: click records the mic, click
            -- again stops and sends the audio to AlayaCore as a UA
            -- (user audio) frame. While recording, the input box, the
            -- send button and the ASR mic button are disabled (the raw
            -- button itself stays clickable to stop).
            case getActiveSession model of
                Just s ->
                    if s.asrBusy || s.voiceActive then
                        -- ASR is recording/transcribing; the raw button
                        -- is disabled in that state (mutual exclusion).
                        ( model, Cmd.none )

                    else if s.rawRecording then
                        ( { model
                            | sessions =
                                Dict.insert s.id
                                    { s | rawRecording = False }
                                    model.sessions
                          }
                        , Ports.rawAudioStop { sessionId = s.id }
                        )

                    else
                        ( { model
                            | sessions =
                                Dict.insert s.id
                                    { s | rawRecording = True }
                                    model.sessions
                          }
                        , Ports.rawAudioStart { sessionId = s.id }
                        )

                Nothing ->
                    ( model, Cmd.none )

        PushToTalk True True ->
            -- Ctrl+" held: push-to-talk in a NEW session. Opens a
            -- session under the built-in "Talk" preset and starts ASR
            -- recording once it exists. Uses the same serialized create
            -- path as the preset menu (planCreating / planCreateQueue),
            -- tagged with UserCreate "Talk" so SessionCreated can tell
            -- this create apart. ptCreatePending arms the auto-start;
            -- the keyup before the create finishes disarms it.
            -- Auto-repeat keydowns are filtered in overlay.js; ptHeld
            -- guards here.
            if model.ptHeld then
                ( model, Cmd.none )

            else
                case model.planCreating of
                    -- Another create is in flight: queue behind it (FIFO
                    -- preserves attribution — SessionCreated consumes the
                    -- marker of the create it belongs to).
                    Just _ ->
                        ( { model
                            | ptHeld = True
                            , ptCreatePending = True
                            , planCreateQueue = model.planCreateQueue ++ [ UserCreate "Talk" ]
                          }
                        , Cmd.none
                        )

                    Nothing ->
                        ( { model
                            | ptHeld = True
                            , ptCreatePending = True
                            , pendingSwitchOnCreate = True
                            , planCreating = Just (UserCreate "Talk")
                          }
                        , Ports.createSession { toolConfirm = Nothing, preset = Just "Talk", builtinTools = Nothing, systemPrompt = Nothing, workDir = Nothing, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
                        )

        PushToTalk True False ->
            -- Plain ` held: push-to-talk in the CURRENT session — the
            -- exact equivalent of pressing the ASR mic button (same
            -- voiceStart + voiceActive, same availability checks).
            -- Release (PushToTalk False) stops and transcribes. No new
            -- session is created.
            if model.ptHeld then
                ( model, Cmd.none )

            else
                case model.activeId of
                    Just sid ->
                        case Dict.get sid model.sessions of
                            Just s ->
                                if s.voiceActive || s.asrBusy || s.rawRecording || not s.connected || PU.planRunningForSession model sid then
                                    ( model, Cmd.none )

                                else
                                    ( { model
                                        | ptHeld = True
                                        , ptSessionId = Just sid
                                        , sessions =
                                            Dict.insert sid
                                                { s | voiceActive = True }
                                                model.sessions
                                      }
                                    , Ports.voiceStart { sessionId = sid }
                                    )

                            Nothing ->
                                ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

        PushToTalk False _ ->
            -- Push-to-talk released (either mode): stop the recording —
            -- the exact equivalent of clicking the ASR mic button
            -- (voiceStop → transcribe → insert into the input). If the
            -- session is still being created (Ctrl+" mode), just
            -- disarm the auto-start (the session appears but stays
            -- silent); if the recording is already over (asrBusy
            -- transcription in flight, or the 60s cap auto-stopped us)
            -- there is nothing to stop.
            if not model.ptHeld then
                ( model, Cmd.none )

            else
                let
                    m1 =
                        { model
                            | ptHeld = False
                            , ptCreatePending = False
                        }
                in
                case m1.ptSessionId of
                    Just sid ->
                        case Dict.get sid m1.sessions of
                            Just s ->
                                if s.voiceActive then
                                    -- Reuse the VoiceInput toggle: it turns
                                    -- voiceActive off, marks asrBusy and
                                    -- sends voiceStop (transcribe).
                                    update (ForSession sid VoiceInput) { m1 | ptSessionId = Nothing }

                                else
                                    ( { m1 | ptSessionId = Nothing }, Cmd.none )

                            Nothing ->
                                ( { m1 | ptSessionId = Nothing }, Cmd.none )

                    Nothing ->
                        ( m1, Cmd.none )

        RawAudioReady raw ->
            -- JS finished encoding the recording as a WAV data URI:
            -- send it immediately as a UA (user audio) frame. The
            -- message carries ONLY the audio — the input box and any
            -- staged media stay exactly as they are (a later Send
            -- sends the text/staged separately).
            case D.decodeValue rawAudioReadyDecoder raw of
                Ok { sessionId, uri } ->
                    case Dict.get sessionId model.sessions of
                        Just s ->
                            ( model
                            , Ports.sendPrompt
                                { sessionId = PU.workCopyId model s.id
                                , text = ""
                                , media =
                                    [ E.object
                                        [ ( "media_type", E.string (T.mediaTypeToString T.Audio) )
                                        , ( "uri", E.string uri )
                                        ]
                                    ]
                                }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        RawAudioError raw ->
            -- Mic/recording failure from the raw-audio bridge; surfaced
            -- as an error message like the ASR mic errors.
            case D.decodeValue voiceErrorDecoder raw of
                Ok { sessionId, message } ->
                    case Dict.get sessionId model.sessions of
                        Just s ->
                            ( { model
                                | sessions =
                                    Dict.insert sessionId
                                        (appendErrorMsg
                                            { s | rawRecording = False }
                                            ("Audio input error: " ++ message)
                                        )
                                        model.sessions
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        CaptureAutoStop raw ->
            -- The JS capture timer hit the 60s cap and auto-stopped a
            -- recorder. Sync Elm's state so the buttons/input unlock;
            -- the finish path (ASR transcribe / raw encode+send) runs
            -- on the JS side and reports back through the usual ports.
            case D.decodeValue captureAutoStopDecoder raw of
                Ok { sessionId, kind } ->
                    case Dict.get sessionId model.sessions of
                        Just s ->
                            let
                                s1 =
                                    if kind == "asr" then
                                        { s | voiceActive = False, asrBusy = True }

                                    else
                                        { s | rawRecording = False }
                            in
                            ( { model | sessions = Dict.insert sessionId s1 model.sessions }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        VoiceError raw ->
            -- Mic/recording failure surfaced from the JS bridge
            -- (permission denied, webview unsupported, …). Shown as an
            -- error message in the session display.
            case D.decodeValue voiceErrorDecoder raw of
                Ok { sessionId, message } ->
                    case Dict.get sessionId model.sessions of
                        Just s ->
                            ( { model
                                | sessions =
                                    Dict.insert sessionId
                                        (appendErrorMsg
                                            { s
                                                | voiceActive = False
                                                , asrBusy = False
                                                , asrDiscard = False
                                            }
                                            ("Voice input error: " ++ message)
                                        )
                                        model.sessions
                                -- A failed push-to-talk recording: drop the
                                -- session link so the keyup cannot send a
                                -- second voiceStop ("Not recording" noise).
                                , ptSessionId =
                                    if model.ptSessionId == Just sessionId then
                                        Nothing

                                    else
                                        model.ptSessionId
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        AsrResult raw ->
            -- Transcription finished. On success, read the textarea
            -- caret and insert the text there; failures are appended to
            -- the message display as error messages. A result for a
            -- cancelled session (asrDiscard) is dropped silently.
            case D.decodeValue asrResultDecoder raw of
                Ok { sessionId, ok, text, error } ->
                    case Dict.get sessionId model.sessions of
                        Just s ->
                            if s.asrDiscard then
                                -- User cancelled this transcription;
                                -- ignore the result entirely.
                                ( { model
                                    | sessions =
                                        Dict.insert sessionId
                                            { s
                                                | asrDiscard = False
                                                , asrBusy = False
                                                , voiceActive = False
                                            }
                                            model.sessions
                                  }
                                , Cmd.none
                                )

                            else if ok then
                                if String.isEmpty text then
                                    ( { model
                                        | sessions =
                                            Dict.insert sessionId
                                                (appendErrorMsg
                                                    { s
                                                        | asrBusy = False
                                                        , voiceActive = False
                                                    }
                                                    "No speech recognized"
                                                )
                                                model.sessions
                                      }
                                    , Cmd.none
                                    )

                                else
                                    ( { model
                                        | pendingVoiceInsert = Just { sessionId = sessionId, text = text }
                                        , sessions =
                                            Dict.insert sessionId
                                                { s
                                                    | asrBusy = False
                                                    , voiceActive = False
                                                }
                                                model.sessions
                                      }
                                    , Ports.getCursorPos { sessionId = sessionId }
                                    )

                            else
                                ( { model
                                    | sessions =
                                        Dict.insert sessionId
                                            (appendErrorMsg
                                                { s
                                                    | asrBusy = False
                                                    , voiceActive = False
                                                }
                                                ("Voice input failed: " ++ error)
                                            )
                                            model.sessions
                                  }
                                , Cmd.none
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        CursorPosResult raw ->
            -- Caret position for a pending voice transcript: insert the
            -- text at that position and place the caret AFTER it.
            case D.decodeValue cursorPosResultDecoder raw of
                Ok { sessionId, pos } ->
                    case model.pendingVoiceInsert of
                        Just pending ->
                            if pending.sessionId == sessionId then
                                case Dict.get sessionId model.sessions of
                                    Just s ->
                                        let
                                            before =
                                                String.left pos s.input

                                            after =
                                                String.dropLeft pos s.input

                                            newInput =
                                                before ++ pending.text ++ after
                                        in
                                        ( { model
                                            | pendingVoiceInsert = Nothing
                                            , sessions =
                                                Dict.insert sessionId
                                                    { s
                                                        | input = newInput
                                                        , asrDiscard = False
                                                    }
                                                    model.sessions
                                          }
                                        -- Focus the input and place the
                                        -- caret after the insert (voice
                                        -- insert and push-to-talk alike) —
                                        -- the user can hit Enter to send
                                        -- right away.
                                        , Ports.setCursorPos
                                            { id = "msg-input-" ++ sessionId
                                            , pos = Just (pos + String.length pending.text)
                                            }
                                        )

                                    Nothing ->
                                        ( model, Cmd.none )

                            else
                                -- The caret result is for a different
                                -- session; keep waiting.
                                ( model, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        SetModel modelId ->
            case model.activeId of
                Just id ->
                    ( model, Ports.setModel { sessionId = PU.workCopyId model id, modelId = modelId } )

                Nothing ->
                    ( model, Cmd.none )

        SetReasoningLevel level ->
            case model.activeId of
                Just id ->
                    -- Optimistically reflect the new level; the core
                    -- confirms via the silent `reason` CI/CO roundtrip.
                    let
                        m1 =
                            { model
                                | sessions =
                                    Dict.update id
                                        (Maybe.map (\s -> { s | reasoningLevel = level }))
                                        model.sessions
                            }
                    in
                    ( m1, Ports.setReasoningLevel { sessionId = PU.workCopyId model id, level = level } )

                Nothing ->
                    ( model, Cmd.none )

        ConfirmTool sid id allowed ->
            case Dict.get sid model.sessions of
                Just _ ->
                    ( updateAfterConfirm model sid
                    , Ports.confirmTool { sessionId = PU.workCopyId model sid, id = id, allowed = allowed }
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
                                { sessionId = PU.workCopyId model sid
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
                        [ Ports.sendMcpDecline { sessionId = PU.workCopyId model sid, server = server }
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
                        [ Ports.sendMcpCancel { sessionId = PU.workCopyId model sid }
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
                        [ Ports.sendMcpCancel { sessionId = PU.workCopyId model sid }
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
            let
                m1 =
                    updateSession model sid (\sess ->
                        case List.filter (\m -> m.id == msgId) sess.messages |> List.head of
                            Just m ->
                                { sess | msgCollapsed = T.toggleMsgCollapsed sess.msgCollapsed m }

                            Nothing ->
                                sess
                      )
            in
            ( m1
            , case Dict.get sid m1.sessions of
                Just s ->
                    -- Expanding the BOTTOM-MOST message while auto-follow
                    -- is active: its box grows below the fold, so re-pin
                    -- to the bottom to reveal the content. Toggling a
                    -- middle message keeps the view (the header that was
                    -- clicked stays where it is; only content below it
                    -- grows/shrinks).
                    if s.atBottom && isLastMessage msgId s then
                        Ports.scrollToBottom { sessionId = sid }

                    else
                        Cmd.none

                Nothing ->
                    Cmd.none
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

        DroppedFiles raw ->
            case D.decodeValue droppedFilesDecoder raw of
                Ok res ->
                    case Dict.get res.sessionId model.sessions of
                        Just s ->
                            let
                                count =
                                    List.length s.staged

                                newItems =
                                    List.indexedMap
                                        (\i f ->
                                            { id = "drop-" ++ String.fromInt (count + i)
                                            , mediaType = FP.detectMediaType f.name
                                            , uri = f.uri
                                            , name = Just f.name
                                            }
                                        )
                                        res.files

                                s1 =
                                    { s | staged = s.staged ++ newItems }
                            in
                            ( { model
                                | sessions =
                                    Dict.insert res.sessionId
                                        (if List.isEmpty res.errors then
                                            s1

                                         else
                                            -- Surface rejected files (oversized /
                                            -- unreadable) as an error message in
                                            -- the session display.
                                            appendErrorMsg s1
                                                ("Drop failed: " ++ String.join "; " res.errors)
                                        )
                                        model.sessions
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Err _ ->
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
                        , Ports.setCursorPos { id = "fp-page-input-" ++ s.id, pos = Nothing }
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
                        , Ports.setCursorPos { id = "fp-page-input-" ++ s.id, pos = Nothing }
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
                                                    -- — session refs (C) +
                                                    -- every plan meta.
                                                    let
                                                        readQueue =
                                                            m.planMetaSessionQueue
                                                                ++ m.planMetaNodeRefsQueue
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
                                                                , planMetaNodeRefsQueue = []
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
                                            -- — record each session's REAL
                                            -- (nested) directory so plans it
                                            -- creates stay in this subtree
                                            -- (P28 layout fix) AND queue
                                            -- their session.refs.json (C3-2:
                                            -- node cascade fork's work-copy record).
                                            listNext
                                                { model
                                                    | planMetaNodeRefsQueue =
                                                        model.planMetaNodeRefsQueue
                                                            ++ List.map (\n -> dir ++ "/" ++ n ++ "/session.refs.json") dirsIn
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
                                    -- session's version refs
                                    -- (sessions/<uuid>/session.refs.json —
                                    -- C architecture: Session ROOT refs;
                                    -- work-copy directories have no refs
                                    -- and are never registered).
                                    let
                                        sessionDirs =
                                            parsed
                                                |> List.filter (\e -> e.isDir && e.name /= ".." && e.name /= ".")
                                                |> List.map .name

                                        planDirs =
                                            List.map (\n -> sessionsDir model.homeDir ++ "/" ++ n ++ "/plans") sessionDirs

                                        sessionMetaQueue =
                                            List.map
                                                (\n -> sessionsDir model.homeDir ++ "/" ++ n ++ "/session.refs.json")
                                                sessionDirs
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
                                        , Ports.setCursorPos { id = "fp-page-input-" ++ sid, pos = Nothing }
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
                        in                        ( model2, Cmd.none )

                    else
                        ( setPlanErrors [ error ] model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        -- C architecture: object_put result (freeze progress).
        ObjectPutResult raw ->            case D.decodeValue objectPutResultDecoder raw of
                Ok r ->
                    if not r.ok then
                        -- Object write failed: abort the current freeze,
                        -- start the next queue item.
                        startNextFreeze { model | freezeActive = Nothing, freezeQueue = [] }

                    else
                        case model.freezeActive of
                            Nothing ->
                                ( model, Cmd.none )

                            Just st ->
                                let
                                    st2 =
                                        Freeze.onPutResult (String.toInt r.reqId |> Maybe.withDefault -1) (Just r.hash) st
                                in
                                if Freeze.isComplete st2 then
                                    -- Version object written: update the session
                                    -- refs + write the refs file, then start the
                                    -- next freeze in the queue.
                                    let
                                        versionHash =
                                            Maybe.withDefault "" st2.versionHash

                                        refs0 =
                                            Dict.get st2.sessionId model.sessionRefs
                                                |> Maybe.withDefault (AV.SessionRefs st2.sessionId "" [] Nothing)

                                        refs =
                                            { refs0
                                                | head = versionHash
                                                , versions = refs0.versions ++ [ versionHash ]
                                                -- C2b: the work-copy directory at
                                                -- freeze time (after fork = forkId;
                                                -- resume keeps the old value)
                                                , workCopy = st2.workCopy
                                            }

                                        m1 =
                                            { model
                                                | freezeActive = Nothing
                                                , sessionRefs = Dict.insert st2.sessionId refs model.sessionRefs
                                                , runSummaries =
                                                    Dict.union
                                                        (Freeze.runSummaries st2)
                                                        model.runSummaries
                                                , versionCache =
                                                    case st2.built of
                                                        Just v ->
                                                            Dict.insert versionHash v model.versionCache

                                                        Nothing ->
                                                            model.versionCache
                                            }

                                        refsPath =
                                            PU.sessionsDir model.homeDir ++ "/" ++ st2.sessionId ++ "/session.refs.json"

                                        ( m2, nextCmd ) =
                                            startNextFreeze m1
                                    in
                                    ( m2
                                    , Cmd.batch
                                        [ nextCmd
                                        , Ports.fsWriteFileText
                                            { path = refsPath
                                            , content = AV.refsContent refs
                                            , createParents = True
                                            }
                                        ]
                                    )

                                else
                                    case Freeze.buildVersion st2 of
                                        Just version ->
                                            -- All blocks/runs ready → freeze the
                                            -- version object itself.
                                            let
                                                content =
                                                    AV.versionContent version

                                                st3 =
                                                    { st2 | built = Just version }
                                            in
                                            ( { model | freezeActive = Just st3 }
                                            , Ports.objectPut
                                                { reqId = String.fromInt (Freeze.versionReq st3)
                                                , content = content
                                                }
                                            )

                                        Nothing ->
                                            -- Some blocks/runs not ready yet: keep waiting.
                                            ( { model | freezeActive = Just st2 }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        -- C architecture: object_get result (loads version content into
        -- the cache; the status bar resolves by version).
        ObjectGetResult raw ->
            case D.decodeValue objectGetResultDecoder raw of
                Ok r ->
                    if r.ok then
                        -- C4: reqId = hash; try Version first, then Block
                        -- (message chunk) — version browsing loads both
                        -- object kinds on demand.
                        case D.decodeString AV.decodeVersion r.content of
                            Ok v ->
                                let
                                    m1 =
                                        { model | versionCache = Dict.insert r.reqId v model.versionCache }

                                    -- C4: viewing this version → auto-fetch the
                                    -- missing message blocks.
                                    blockCmd =
                                        if model.versionViewFor == Just r.reqId then
                                            let
                                                missing =
                                                    List.filter (\b -> not (Dict.member b m1.blockCache)) v.blocks
                                            in
                                            Cmd.batch (List.map (\b -> Ports.objectGet { reqId = b, hash = b }) missing)

                                        else
                                            Cmd.none
                                in
                                ( m1, blockCmd )

                            Err _ ->
                                case D.decodeString AV.decodeBlock r.content of
                                    Ok b ->
                                        ( { model | blockCache = Dict.insert r.reqId b.messages model.blockCache }, Cmd.none )

                                    Err _ ->
                                        ( model, Cmd.none )

                    else
                        ( model, Cmd.none )

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

                            ( m1, extraCmd ) =
                                if res.ok then
                                    if String.endsWith "/session.refs.json" path then
                                        -- C architecture: session version refs
                                        -- (sessions/<uuid>/session.refs.json) —
                                        -- load into sessionRefs and trigger the
                                        -- head version content load (the status
                                        -- bar resolves by version).
                                        case D.decodeString AV.decodeSessionRefs res.content of
                                            Ok refs ->
                                                let
                                                    m2 =
                                                        { model | sessionRefs = Dict.insert refs.id refs model.sessionRefs }
                                                in
                                                if refs.head /= "" && not (Dict.member refs.head model.versionCache) then
                                                    ( m2, Ports.objectGet { reqId = refs.head, hash = refs.head } )

                                                else
                                                    ( m2, Cmd.none )

                                            Err _ ->
                                                ( model, Cmd.none )

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
                                                ( { model | planMetas = Dict.insert planId meta model.planMetas }
                                                , Cmd.none
                                                )

                                            Err _ ->
                                                ( model, Cmd.none )

                                else
                                    -- A failed meta read (missing/corrupt
                                    -- file): skip it, keep the chain going.
                                    ( model, Cmd.none )
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
                                , Cmd.batch
                                    [ Ports.fsReadFileText { reqId = reqId2, path = next }
                                    , extraCmd
                                    ]
                                )

                            [] ->
                                ( { m1 | planMetaReading = Nothing, planMetaReadReqId = Nothing }
                                , extraCmd
                                )

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

        -- C4: version browsing (read-only view of historical versions;
        -- D8 does not materialize).
        OpenVersionList sid ->
            ( { model | versionListFor = Just sid, showSessionManager = False }, Cmd.none )

        CloseVersionList ->
            ( { model | versionListFor = Nothing }, Cmd.none )

        ViewVersion sid hash ->
            let
                m1 =
                    { model
                        | versionListFor = Nothing
                        , versionViewFor = Just hash
                        , versionViewSession = Just sid
                    }

                ( m2, blockGets ) =
                    case Dict.get hash m1.versionCache of
                        Just v ->
                            let
                                missing =
                                    List.filter (\b -> not (Dict.member b m1.blockCache)) v.blocks
                            in
                            ( m1, Cmd.batch (List.map (\b -> Ports.objectGet { reqId = b, hash = b }) missing) )

                        Nothing ->
                            -- Version object not loaded yet: fetch it first;
                            -- the ObjectGetResult version branch auto-fetches
                            -- the missing blocks.
                            ( m1, Cmd.none )
            in
            ( m2
            , Cmd.batch
                [ if Dict.member hash model.versionCache then
                    Cmd.none

                  else
                    Ports.objectGet { reqId = hash, hash = hash }
                , blockGets
                ]
            )

        CloseVersionView ->
            ( { model | versionViewFor = Nothing, versionViewSession = Nothing }, Cmd.none )

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
                    origin0.sessionId

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
                                            ( { model | planCascadePreview = Just scope, planCascadeError = Nothing }, Cmd.none )

                                        else
                                            ( { model | planCascadeError = Nothing }
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
                                , planCascadeError = Nothing
                            }

                        -- C architecture: on confirm, freeze "the world
                        -- before the re-run" — the re-run session's V0
                        -- (the plan keeps its pre-rerun old state/unexecuted).
                        -- The version frozen on completion later belongs to
                        -- the forked work copy, so the old session (resume)
                        -- sees V0 (old-state isolation).
                        ( mFreeze, freezeCmd ) =
                            if scope.rootSessionId /= "" then
                                let
                                    rootDiskId =
                                        scope.rootSessionId
                                in
                                if findPlanIdBySession model rootDiskId == Nothing then
                                    PU.freezeSessionVersion m0 rootDiskId Nothing

                                else
                                    ( m0, Cmd.none )

                            else
                                ( m0, Cmd.none )

                        ( m1, closeCmd ) =
                            List.foldl
                                (\pid ( m, c ) ->
                                    let
                                        ( m2, c2 ) =
                                            update (PlanClose pid) m
                                    in
                                    ( m2, Cmd.batch [ c, c2 ] )
                                )
                                ( mFreeze, Cmd.none )
                                scope.closePlanIds

                        queue =
                            List.filter (\lvl -> not (Dict.member lvl.planId m1.planWindows)) scope.levels
                                |> List.map .planId

                        ( m3, openCmd ) =
                            openNextOrStart { m1 | planCascadeOpenQueue = queue }
                    in
                    ( m3, Cmd.batch [ closeCmd, openCmd, freezeCmd ] )

                Nothing ->
                    ( model, Cmd.none )

        PlanCascadeCancel ->
            ( { model
                | planCascadePreview = Nothing
                , planCascade = Nothing
                , planCascadeOpenQueue = []
                , planCascadeFork = Nothing
                , planCascadeError = Nothing
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
                            -- C2b: the top-level re-run fork's confirm info
                            -- (target is cleared inside RegisterFork; take it
                            -- out first for the V₁ freeze).
                            forkTarget =
                                model.planCascadeFork

                            ( mReg, cReg ) =
                                update (SessionCreated r.sessionId) model

                            ( mAdopt, cAdopt ) =
                                PU.cascadeStepIn update (PC.InstanceReady (Ok r.sessionId)) mReg

                            -- C2b (§8.1): after a top-level re-run fork takes
                            -- over, freeze V₁ — messages =
                            -- sessions[Session.id] (already fork content),
                            -- A executed → head = V₁ (parent = the V₀ frozen
                            -- on confirm). An old session resumed later still
                            -- sees V₀ (isolation preserved).
                            ( mFinal, cFinal ) =
                                case forkTarget of
                                    Just t ->
                                        if t.planId == "" then
                                            let
                                                sessionId =
                                                    Dict.get t.childPlanId model.planMetas
                                                        |> Maybe.map (.origin >> .sessionId)
                                                        |> Maybe.withDefault t.forkSource
                                            in
                                            PU.freezeSessionVersion mAdopt sessionId (Just t.childPlanId)

                                        else
                                            ( mAdopt, Cmd.none )

                                    Nothing ->
                                        ( mAdopt, Cmd.none )
                        in
                        ( mFinal, Cmd.batch [ cReg, cAdopt, cFinal ] )

                    else
                        -- The fork FAILED: nothing was truncated and no
                        -- ancestor node was reset — feed the machine so it
                        -- surfaces the error (CascadeError effect) and ends
                        -- cleanly. The completed plan window stays open with
                        -- the error banner; the user can inspect / re-run.
                        let
                            ( mFail, cFail ) =
                                PU.cascadeStepIn update (PC.InstanceReady (Err r.error)) model
                        in
                        ( { mFail
                            | planCascadeFork = Nothing
                            , planCascadeOpenQueue = []
                          }
                        , cFail
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
            runStepIn update planId ts R.StartRun (startRunIn planId ts { model | planCascadeError = Nothing })

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
            -- to sub-plans of waiting (delegated) nodes. A fresh start
            -- also clears any previous cascade error (the banner stays
            -- until the next run overwrites it).
            restartPlanCascade update planId { model | planCascadeError = Nothing }

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
                -- C2b-7: no lineage — nodes bind directly by session id
                -- (stable identity).
                convId =
                    sid

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
            -- Priority: live session window (focus it) → resume from
            -- disk (C3-2: work copy dir) → detail.
            case Dict.get planId model.planWindows of
                Just win ->
                    case win.run of
                        Just run ->
                            case Dict.get nodeId run.nodes of
                                Just n ->
                                    -- C3/C5: node binding = session id (windows
                                    -- keyed by Session.id; resume keeps it).
                                    case n.conversationId of
                                        Just convId ->
                                            if Dict.member convId model.sessions then
                                                update (ActivateSession convId) model

                                            else
                                                -- dead live-binding
                                                -- (e.g. restart):
                                                -- resume from disk.
                                                -- The node STAYS
                                                -- bound to convId
                                                -- (the dir name);
                                                -- C3-2: restore from the
                                                -- work-copy directory after
                                                -- a node cascade fork
                                                -- (refs.workCopy).
                                                ( { model
                                                    | pendingSwitchOnCreate = True
                                                    , planResumeOwner = Just planId
                                                    , planResumeFrom = Just convId
                                                    , planReplaySessions = Set.insert convId model.planReplaySessions
                                                    , planNodeSessions =
                                                        Dict.insert convId (planId ++ "/" ++ nodeId) model.planNodeSessions
                                                  }
                                                , Ports.resumeSession { sessionId = resumeDirFor model convId, workDir = planWorkDir planId model, planId = Just planId, nodeId = Just nodeId, originSessionId = planOriginSessionDir model planId }
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
                                                        ( { model
                                                            | pendingSwitchOnCreate = True
                                                            , planResumeOwner = Just planId
                                                            , planResumeFrom = Just sid
                                                            , planReplaySessions = Set.insert sid model.planReplaySessions
                                                            , planNodeSessions =
                                                                Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                                                          }
                                                        , Ports.resumeSession { sessionId = resumeDirFor model sid, workDir = planWorkDir planId model, planId = Just planId, nodeId = Just nodeId, originSessionId = planOriginSessionDir model planId }
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
                ( { model
                    | pendingSwitchOnCreate = True
                    , planResumeOwner = Just planId
                    , planResumeFrom = Just sid
                    , planReplaySessions = Set.insert sid model.planReplaySessions
                    , planNodeSessions =
                        Dict.insert sid (planId ++ "/" ++ nodeId) model.planNodeSessions
                    }
                , Ports.resumeSession { sessionId = resumeDirFor model sid, workDir = planWorkDir planId model, planId = Just planId, nodeId = Just nodeId, originSessionId = planOriginSessionDir model planId }
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

        ShowGlobalMenuAt x y ->
            ( { model | showGlobalMenu = True, globalMenuX = x, globalMenuY = y, presetSubmenuOpen = False }, Cmd.none )

        CloseGlobalMenu ->
            ( { model | showGlobalMenu = False, presetSubmenuOpen = False }, Cmd.none )

        SetPresetSubmenu open ->
            ( { model | presetSubmenuOpen = open }, Cmd.none )

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
            -- C2b (§8.1): resume from the current work-copy directory
            -- (refs.workCopy = the fork directory / still it after a
            -- resume); if the work-copy directory is missing (stale/
            -- deleted) → fall back to the Session root directory (the
            -- UI hint lives in the manager status row).
            let
                resumeDir =
                    resumeDirFor model id
            in
            ( { model
                | pendingSwitchOnCreate = True
                , sessionManagerError = Nothing
                , planResumeFrom = Just id
                , planReplaySessions = Set.insert id model.planReplaySessions
              }
            , Ports.resumeSession { sessionId = resumeDir, workDir = Nothing, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
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
            ( { m3
                | closeSet = Set.empty
                , sessionManagerError = Nothing
                -- C2b: drop the Session refs and work-copy mapping (the
                -- process was already closed by CloseSession).
                , sessionRefs = Dict.remove id m3.sessionRefs
                , sessionWorkCopies = Dict.remove id m3.sessionWorkCopies
              }
            , Cmd.batch
                [ planCmds
                , sessionCmds
                , Ports.deleteSessionDir { sessionId = id, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }
                -- C2b (§8.1): delete the work-copy directory (forked) along
                -- with the Session — no orphan directories left.
                , case Dict.get id m3.sessionRefs of
                    Just refs ->
                        case refs.workCopy of
                            Just wc ->
                                if wc == id then
                                    Cmd.none

                                else
                                    Ports.deleteSessionDir { sessionId = wc, planId = Nothing, nodeId = Nothing, originSessionId = Nothing }

                            Nothing ->
                                Cmd.none

                    Nothing ->
                        Cmd.none
                , Ports.setConnectionChain (chainPayload m3 m3.connectionChain)
                ]
            )

        DeleteWorkCopyDir dir planId nodeId originSessionId ->
            -- C2b/C3: delete the old work-copy directory lazily (only
            -- after the old process's graceful close completes, to avoid
            -- a save writing back and racing the directory recreation).
            -- Nested node work copies are located by
            -- planId/nodeId/originSessionId (top-level is empty).
            ( model
            , Ports.deleteSessionDir
                { sessionId = dir
                , planId = if planId == "" then Nothing else Just planId
                , nodeId = if nodeId == "" then Nothing else Just nodeId
                , originSessionId = if originSessionId == "" then Nothing else Just originSessionId
                }
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
                        , Ports.setCursorPos { id = "model-selector-input-" ++ s.id, pos = Nothing }
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

        ModelSelectorConfirmItem id ->
            Kit.confirmItem sessionModelKit id model

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
                                { ed
                                    | state = Sel.setList res.models ed.state
                                    , activeModelId = res.activeId
                                    , error = Nothing
                                }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "model-selector-input-default"
                            , Ports.setCursorPos { id = "model-selector-input-default", pos = Nothing }
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

        -- Make a model the preset's DEFAULT: the backend probes alayacore
        -- with model_set so the preset's runtime.conf records it; new
        -- sessions under the preset then start on that model.
        DefaultModelsSetActive id ->
            ( { model
                | defaultModelsEditor =
                    let
                        ed =
                            model.defaultModelsEditor
                    in
                    { ed | error = Nothing }
              }
            , Ports.setDefaultModel
                { preset = model.defaultModelsEditor.preset
                , modelId = id
                }
            )

        -- Result of setting a model as the preset's DEFAULT.
        DefaultModelsSetActiveResult raw ->
            case D.decodeValue defaultModelsActionResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.defaultModelsEditor
                    in
                    if res.ok then
                        -- Optimistically mark the model as the default
                        -- (instant header/● feedback), then re-list so
                        -- the marker reflects what alayacore persisted.
                        ( { model
                            | defaultModelsEditor =
                                { ed
                                    | activeModelId = Just res.modelId
                                    , error = Nothing
                                }
                          }
                        , Ports.listDefaultModels { preset = ed.preset }
                        )

                    else
                        ( { model
                            | defaultModelsEditor =
                                { ed | error = Just res.error }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SetDefaultModelsInput val ->
            Kit.setInput defaultModelsKit val model

        DefaultModelsSelectItem idx ->
            Kit.selectItem defaultModelsKit idx model

        DefaultModelsConfirmItem id ->
            Kit.confirmItem defaultModelsKit id model

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
                            , Ports.setCursorPos { id = "mcp-selector-input-default", pos = Nothing }
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

        McpConfirmItem id ->
            Kit.confirmItem mcpKit id model

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

        SetSystemPrompt val ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor =
                    { ed
                        | systemPrompt = val
                        , error = Nothing
                    }
              }
            , Cmd.none
            )

        SetSettingsReasoningLevel lvl ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor =
                    { ed
                        | reasoningLevel = lvl
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
                , systemPrompt = ed.systemPrompt
                , reasoningLevel = ed.reasoningLevel
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
                                    , systemPrompt = res.systemPrompt
                                    , reasoningLevel = res.reasoningLevel
                                    , error = Nothing
                                }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "settings-tool-confirm"
                            , Ports.setCursorPos { id = "settings-tool-confirm", pos = Nothing }
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

        -- Voice input ASR config overlay (cross-preset): profile list
        OpenAsrConfig ->
            ( { model
                | asrConfigEditor =
                    { emptyAsrConfigEditor
                        | show = True
                        , loading = True
                    }
                , showGlobalMenu = False
              }
            , Ports.getAsrConfig {}
            )

        CloseAsrConfig ->
            let
                ed =
                    model.asrConfigEditor
            in
            if ed.syncing then
                -- Do not allow closing while a sync is in flight
                ( model, Cmd.none )

            else if ed.inForm then
                -- The form's Back button returns to the list; closing
                -- the overlay is only possible from the list view.
                ( model, Cmd.none )

            else
                ( { model | asrConfigEditor = emptyAsrConfigEditor }
                , Cmd.none
                )

        AsrConfigAdd ->
            -- Enter the form for a NEW profile.
            ( { model
                | asrConfigEditor =
                    { emptyAsrConfigEditor
                        | show = True
                        , inForm = True
                        , editingId = Nothing
                    }
              }
            , Cmd.none
            )

        AsrConfigEdit profileId ->
            -- Enter the form pre-filled from the profile.
            case findAsrProfile profileId model.asrConfig.profiles of
                Just p ->
                    ( { model
                        | asrConfigEditor =
                            { emptyAsrConfigEditor
                                | show = True
                                , inForm = True
                                , editingId = Just p.id
                                , name = p.name
                                , protocol = p.protocol
                                , url = p.url
                                , apiKey = p.apiKey
                                , model = p.model
                                , language = p.language
                            }
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        AsrConfigBack ->
            -- Form → list (unsaved edits are discarded).
            ( { model
                | asrConfigEditor =
                    { emptyAsrConfigEditor
                        | show = True
                    }
              }
            , Cmd.none
            )

        AsrConfigSetActive profileId ->
            -- Switch the active profile (transcription uses it).
            let
                ed =
                    model.asrConfigEditor
            in
            ( { model
                | asrConfigEditor =
                    { ed
                        | syncing = True
                        , error = Nothing
                    }
              }
            , Ports.syncAsrConfig
                { config =
                    E.encode 0
                        (asrConfigJson { active = profileId } model.asrConfig.profiles)
                }
            )

        AsrConfigDelete profileId ->
            -- First click arms the confirm state on the list row.
            let
                ed =
                    model.asrConfigEditor
            in
            ( { model
                | asrConfigEditor =
                    { ed
                        | confirmDelete =
                            if ed.confirmDelete == Just profileId then
                                Nothing

                            else
                                Just profileId
                    }
              }
            , Cmd.none
            )

        AsrConfigDeleteConfirm ->
            case model.asrConfigEditor.confirmDelete of
                Just profileId ->
                    let
                        profiles =
                            List.filter (\p -> p.id /= profileId) model.asrConfig.profiles

                        ed =
                            model.asrConfigEditor
                    in
                    ( { model
                        | asrConfigEditor =
                            { ed
                                | syncing = True
                                , confirmDelete = Nothing
                                , error = Nothing
                            }
                      }
                    , Ports.syncAsrConfig
                        { config = E.encode 0 (asrConfigJson { active = model.asrConfig.active } profiles) }
                    )

                Nothing ->
                    ( model, Cmd.none )

        AsrConfigDeleteCancel ->
            let
                ed =
                    model.asrConfigEditor
            in
            ( { model
                | asrConfigEditor =
                    { ed | confirmDelete = Nothing }
              }
            , Cmd.none
            )

        SetAsrName val ->
            setAsrEditorField model (\ed -> { ed | name = val, error = Nothing })

        SetAsrProtocol val ->
            setAsrEditorField model (\ed -> { ed | protocol = val, error = Nothing })

        SetAsrUrl val ->
            setAsrEditorField model (\ed -> { ed | url = val, error = Nothing })

        SetAsrApiKey val ->
            setAsrEditorField model (\ed -> { ed | apiKey = val, error = Nothing })

        SetAsrModel val ->
            setAsrEditorField model (\ed -> { ed | model = val, error = Nothing })

        SetAsrLanguage val ->
            setAsrEditorField model (\ed -> { ed | language = val, error = Nothing })

        AsrConfigSave ->
            let
                ed =
                    model.asrConfigEditor
            in
            if String.isEmpty (String.trim ed.url) then
                ( { model
                    | asrConfigEditor =
                        { ed | error = Just "Endpoint URL is required (full address, e.g. http://127.0.0.1:8080/v1/audio/transcriptions)" }
                  }
                , Cmd.none
                )

            else
                let
                    draft =
                        { id = Maybe.withDefault "" ed.editingId
                        , name = String.trim ed.name
                        , protocol = String.trim ed.protocol
                        , url = String.trim ed.url
                        , apiKey = String.trim ed.apiKey
                        , model = String.trim ed.model
                        , language = String.trim ed.language
                        }

                    profiles =
                        case ed.editingId of
                            Just profileId ->
                                List.map
                                    (\p -> if p.id == profileId then draft else p)
                                    model.asrConfig.profiles

                            Nothing ->
                                model.asrConfig.profiles ++ [ draft ]
                in
                ( { model
                    | asrConfigEditor =
                        { ed
                            | syncing = True
                            , error = Nothing
                        }
                  }
                , Ports.syncAsrConfig
                    { config = E.encode 0 (asrConfigJson { active = model.asrConfig.active } profiles) }
                )

        AsrConfigGetResult raw ->
            case D.decodeValue asrConfigGetResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.asrConfigEditor
                    in
                    if res.ok then
                        ( { model
                            | asrConfig =
                                { active = res.active
                                , profiles = res.profiles
                                }
                            , asrConfigEditor =
                                { ed
                                    | loading = False
                                    , error = Nothing
                                }
                          }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | asrConfigEditor =
                                { ed
                                    | loading = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        AsrConfigSyncResult raw ->
            case D.decodeValue asrConfigGetResultDecoder raw of
                Ok res ->
                    if res.ok then
                        ( { model
                            | asrConfig =
                                { active = res.active
                                , profiles = res.profiles
                                }
                            , asrConfigEditor =
                                { emptyAsrConfigEditor
                                    | show = True
                                }
                          }
                        , Cmd.none
                        )

                    else
                        let
                            ed =
                                model.asrConfigEditor
                        in
                        ( { model
                            | asrConfigEditor =
                                { ed
                                    | syncing = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        AlayacoreCheckResult raw ->
            -- Startup probe reply: the backend reports whether the
            -- alayacore binary was found and where. The home screen
            -- reads model.alayacoreCheck to show a "not found" banner;
            -- sessions that already exist still work, but creating a
            -- new one will fail. We always store the result so the
            -- banner can show it (ok=True is stored too, so the view
            -- can choose to clear the banner on success).
            case D.decodeValue alayacoreCheckDecoder raw of
                Ok res ->
                    ( { model | alayacoreCheck = Just res }, Cmd.none )

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

        PresetDragStart idx ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | dragFrom = Just idx, dragOver = Just idx }
              }
            , Cmd.none
            )

        PresetDragOver idx ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | dragOver = Just idx }
              }
            , Cmd.none
            )

        PresetDragEnd ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | dragFrom = Nothing, dragOver = Nothing }
              }
            , Cmd.none
            )

        PresetDrop idx ->
            case model.presetManager.dragFrom of
                Just from ->
                    let
                        reordered =
                            movePreset from idx model.presets

                        pm =
                            model.presetManager
                    in
                    ( { model
                        | presets = reordered
                        , presetManager = { pm | dragFrom = Nothing, dragOver = Nothing }
                      }
                    , Ports.reorderPresets { names = List.map .name reordered }
                    )

                Nothing ->
                    ( model, Cmd.none )

        PresetsListResult raw ->
            case D.decodeValue presetsListResultDecoder raw of
                Ok res ->
                    if res.ok then
                        let
                            pm =
                                model.presetManager
                        in
                        ( { model
                            | presets = res.presets
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

        FillMcpAuthUrl server url ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        { sess | mcpAuthRunning = Just server }
                      )
                    , Ports.fillMcpAuthUrl
                        { sessionId = PU.workCopyId model s.id
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

            -- Escape or Ctrl+[ closes the TOPMOST open overlay: context
            -- menu → global overlays (session manager, version browsing,
            -- editors…) → the active session's overlays (file picker,
            -- model selector) → media preview as fallback.
            -- The tool-confirm dialog is intentionally NOT closed by
            -- Escape (it requires an explicit Allow/Deny choice), and
            -- MCP init/auth overlays keep their explicit buttons too.
            -- The close-session confirmation DOES respond to Escape
            -- (= Cancel).
            else if key == "Escape" || (key == "[" && ctrl) then
                case pendingCloseConfirmId model of
                    Just sid ->
                        -- Escape cancels a per-session close
                        -- confirmation (the active one first).
                        update (DismissCloseConfirm sid) model

                    Nothing ->
                        case pendingCancelConfirmId model of
                            Just sid ->
                                -- ... and the per-session cancel-task
                                -- confirmation (keeps the task running).
                                update (DismissCancelTask sid) model

                            Nothing ->
                                if model.ctxVisible then
                                    ( { model | ctxVisible = False }, Cmd.none )

                                else if model.showSessionManager then
                                    update CloseSessionManager model

                                else if model.versionListFor /= Nothing then
                                    update CloseVersionList model

                                else if model.versionViewFor /= Nothing then
                                    update CloseVersionView model

                                else if model.presetManager.show then
                                    update ClosePresetManager model

                                else if model.defaultModelsEditor.show then
                                    update CloseDefaultModelsEditor model

                                else if model.mcpEditor.show then
                                    update CloseMcpEditor model

                                else if model.settingsEditor.show then
                                    update CloseSettingsEditor model

                                else if model.globalConfigEditor.show then
                                    update CloseGlobalConfig model

                                else if model.asrConfigEditor.show then
                                    if model.asrConfigEditor.inForm then
                                        update AsrConfigBack model

                                    else
                                        update CloseAsrConfig model

                                else if model.planCascadePreview /= Nothing then
                                    update PlanCascadeCancel model

                                else
                                    case model.activeId of
                                        Just sid ->
                                            case Dict.get sid model.sessions of
                                                Just sess ->
                                                    if sess.filePicker.show then
                                                        update (ForSession sid CloseFilePicker) model

                                                    else if sess.showModelSelector then
                                                        update (ForSession sid CloseModelSelector) model

                                                    else
                                                        ( updateActiveSession model (\s -> { s | mediaPreview = Nothing })
                                                        , Cmd.none
                                                        )

                                                Nothing ->
                                                    ( model, Cmd.none )

                                        Nothing ->
                                            ( model, Cmd.none )

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
                                -- User-initiated close: confirm first
                                -- (Close / Close and Delete / Cancel).
                                update (RequestCloseSession sid) model

                            Nothing ->
                                case model.planActiveId of
                                    Just pid2 ->
                                        update (PlanClose pid2) model

                                    Nothing ->
                                        ( model, Cmd.none )

            -- Ctrl+G requests a cancel-task confirmation for the active
            -- session's running task — the keyboard equivalent of the
            -- send button while it shows "Cancel task" (only meaningful
            -- when a task is running; otherwise it is a no-op, never a
            -- send).
            else if key == "g" && ctrl then
                case model.activeId of
                    Just sid ->
                        case Dict.get sid model.sessions of
                            Just s ->
                                if s.taskRunning then
                                    update (RequestCancelTask sid) model

                                else
                                    ( model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        ForSession sid innerMsg ->
            update innerMsg { model | activeId = Just sid }

        -- Unified pointer pipeline (touch & pointer design D1/D2/D5):
        -- transport.js forwards raw pointer events (a dumb pipe that
        -- classifies the target and captures/preventDefaults draggable
        -- surfaces); the gesture FSM below arms/activates drags, tracks
        -- the two-pointer pinch and the touch long-press. Window
        -- activation still happens via click/compat-mousedown paths
        -- (taps on a window bar activate on pointerup — see PointerUp).

        PointerDown raw ->
            case D.decodeValue P.pointerEventDecoder raw of
                Ok pe ->
                    let
                        m1 =
                            { model | activePointers = Dict.insert pe.id pe model.activePointers }
                    in
                    -- Pinch: when a SECOND canvas pointer lands and no
                    -- drag is in motion (and any armed drag is itself a
                    -- canvas pan — a bar grab plus a canvas finger is a
                    -- bar drag, not a pinch), switch to the two-pointer
                    -- zoom: a lone canvas finger never pans alone.
                    if canvasPointerCount m1 >= 2 && not (dragInMotion m1) && isPanArm m1.drag then
                        startPinch m1

                    else if m1.drag == Nothing && P.isDraggableTarget pe.target && pe.button == 0 then
                        let
                            ( m2, c1 ) =
                                armDrag m1 pe

                            ( m3, c2 ) =
                                if shouldArmLongPress pe m2 then
                                    ( { m2 | longPress = Just { pointerId = pe.id, x = pe.x, y = pe.y } }
                                    , Task.perform (\_ -> LongPressFired) (Process.sleep (toFloat P.longPressMs))
                                    )

                                else
                                    ( m2, Cmd.none )
                        in
                        ( m3, Cmd.batch [ c1, c2 ] )

                    else
                        ( m1, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        PointerMove raw ->
            case D.decodeValue P.pointerEventDecoder raw of
                Ok pe ->
                    let
                        m1 =
                            { model
                                | activePointers =
                                    Dict.update pe.id
                                        (Maybe.map (\pi -> { pi | x = pe.x, y = pe.y }))
                                        model.activePointers
                            }

                        m2 =
                            -- Moving past the slop cancels the long-press
                            -- (the gesture became a drag, not a menu tap).
                            case m1.longPress of
                                Just lp ->
                                    if lp.pointerId == pe.id && P.distance ( lp.x, lp.y ) ( pe.x, pe.y ) > P.slop then
                                        { m1 | longPress = Nothing }

                                    else
                                        m1

                                Nothing ->
                                    m1
                    in
                    case m2.drag of
                        Just d ->
                            if d.pointerId == pe.id then
                                dragMove pe d m2

                            else
                                ( m2, Cmd.none )

                        Nothing ->
                            case m2.pinch of
                                Just pc ->
                                    if pe.id == pc.pointerA || pe.id == pc.pointerB then
                                        pinchMove m2

                                    else
                                        ( m2, Cmd.none )

                                Nothing ->
                                    ( m2, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        PointerUp raw ->
            case D.decodeValue P.pointerEventDecoder raw of
                Ok pe ->
                    let
                        m1 =
                            { model | activePointers = Dict.remove pe.id model.activePointers }
                    in
                    case m1.drag of
                        Just d ->
                            if d.pointerId == pe.id then
                                -- A TAP on a window bar (armed but never
                                -- activated) still activates the window:
                                -- pointer capture preventDefaults the
                                -- compat mousedown, so the panel's
                                -- mousedown activation never fires for
                                -- bar taps (mouse or touch).
                                let
                                    base =
                                        { m1 | drag = Nothing, longPress = clearLongPressFor pe.id m1.longPress }

                                    m2 =
                                        if d.active then
                                            base

                                        else
                                            activateArmedTap d base
                                in
                                ( m2, Cmd.none )

                            else
                                ( m1, Cmd.none )

                        Nothing ->
                            let
                                m2 =
                                    case m1.pinch of
                                        Just pc ->
                                            if pe.id == pc.pointerA || pe.id == pc.pointerB then
                                                { m1 | pinch = Nothing }

                                            else
                                                m1

                                        Nothing ->
                                            m1

                                m3 =
                                    { m2 | longPress = clearLongPressFor pe.id m2.longPress }
                            in
                            ( m3, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        PointerCancel raw ->
            -- The browser stole the gesture (OS gesture, notification
            -- shade, element scroll): end everything cleanly so no
            -- drag/pinch/long-press stays armed.
            case D.decodeValue P.pointerEventDecoder raw of
                Ok pe ->
                    ( { model
                        | activePointers = Dict.remove pe.id model.activePointers
                        , drag =
                            case model.drag of
                                Just d ->
                                    if d.pointerId == pe.id then
                                        Nothing

                                    else
                                        model.drag

                                Nothing ->
                                    Nothing
                        , pinch =
                            case model.pinch of
                                Just pc ->
                                    if pe.id == pc.pointerA || pe.id == pc.pointerB then
                                        Nothing

                                    else
                                        model.pinch

                                Nothing ->
                                    Nothing
                        , longPress =
                            case model.longPress of
                                Just lp ->
                                    if lp.pointerId == pe.id then
                                        Nothing

                                    else
                                        model.longPress

                                Nothing ->
                                    Nothing
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( model, Cmd.none )

        LongPressFired ->
            -- 500ms hold on the canvas with no movement: the touch
            -- equivalent of a right-click — open the global menu at the
            -- finger. Only fires if the finger is still down and has not
            -- crossed the slop.
            case model.longPress of
                Just lp ->
                    if model.pinch /= Nothing then
                        ( { model | longPress = Nothing }, Cmd.none )

                    else
                        case Dict.get lp.pointerId model.activePointers of
                            Just pi ->
                                if P.distance ( lp.x, lp.y ) ( pi.x, pi.y ) <= P.slop then
                                    ( { model
                                        | showGlobalMenu = True
                                        , globalMenuX = round pi.x
                                        , globalMenuY = round pi.y
                                        , presetSubmenuOpen = False
                                        , longPress = Nothing
                                        -- The hold was a menu gesture,
                                        -- not a drag: discard the inert
                                        -- pan arm so moving the finger
                                        -- with the menu open does not
                                        -- pan underneath it.
                                        , drag = clearArmedPan model.drag
                                      }
                                    -- The finger release produces a
                                    -- click that would bubble to .app
                                    -- and close the menu; transport.js
                                    -- swallows that one click.
                                    , Ports.longPressMenuOpened ()
                                    )

                                else
                                    ( { model | longPress = Nothing }, Cmd.none )

                            Nothing ->
                                ( { model | longPress = Nothing }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

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

        ActivateSession id ->
            -- Always re-raise + rebuild the chain, even when this
            -- session is already `activeId`: focusing the plan window in
            -- between switched the chain away (and raised the plan
            -- chain), so clicking the session again must switch the
            -- chain back AND bring its windows back on top.
            activateSessionModel model id

        NoOp ->
            ( model, Cmd.none )


-- ─── Pointer gesture FSM helpers (D4/D5) ────────────────────────────

{-| Pointers currently down on the canvas background (pinch candidates).
-}
canvasPointers : Model -> List P.PointerInfo
canvasPointers model =
    Dict.toList model.activePointers
        |> List.filter (\( _, pi ) -> pi.target == P.TCanvas)
        |> List.map Tuple.second


canvasPointerCount : Model -> Int
canvasPointerCount model =
    List.length (canvasPointers model)


dragInMotion : Model -> Bool
dragInMotion model =
    case model.drag of
        Just d ->
            d.active

        Nothing ->
            False


{-| Two fingers on the canvas: start the pinch zoom at the current
distance. Clears any armed pan (a lone canvas finger never pans) and
the long-press (the second finger means zoom, not menu).
-}
startPinch : Model -> ( Model, Cmd Msg )
startPinch model =
    let
        pts =
            canvasPointers model
    in
    case ( List.head pts, List.head (List.drop 1 pts) ) of
        ( Just a, Just b ) ->
            ( { model
                | pinch = Just { pointerA = a.id, pointerB = b.id, startDist = P.distance ( a.x, a.y ) ( b.x, b.y ) }
                , longPress = Nothing
                , drag = clearArmedPan model.drag
              }
            , Cmd.none
            )

        _ ->
            ( model, Cmd.none )


clearArmedPan : Maybe DragState -> Maybe DragState
clearArmedPan drag =
    case drag of
        Just d ->
            if d.active || d.kind /= Pan then
                drag

            else
                Nothing

        Nothing ->
            Nothing


{-| Pointer down on a draggable surface: arm the drag with an origin
snapshot. The drag stays inert (a tap) until the pointer crosses the
slop (see dragMove). Raises nothing here — activation happens either on
slop crossing or on a bar tap's pointerup.
-}
armDrag : Model -> P.PointerInfo -> ( Model, Cmd Msg )
armDrag model pe =
    case toDragKind pe.target pe.sessionId pe.planId pe.handle of
        Just kind ->
            let
                key =
                    dragKindKey kind

                pos =
                    Dict.get key model.windowPositions

                winX =
                    pos |> Maybe.map .x |> Maybe.withDefault 0

                winY =
                    pos |> Maybe.map .y |> Maybe.withDefault 0

                winW =
                    pos |> Maybe.map .w |> Maybe.withDefault 0

                winH =
                    pos |> Maybe.map .h |> Maybe.withDefault 0
            in
            ( { model
                | drag =
                    Just
                        { kind = kind
                        , pointerId = pe.id
                        , startMouseX = pe.x
                        , startMouseY = pe.y
                        , active = False
                        , startWinX = winX
                        , startWinY = winY
                        , startWinW = winW
                        , startWinH = winH
                        , startOffsetX = model.canvasOffset.x
                        , startOffsetY = model.canvasOffset.y
                        }
              }
            , Cmd.none
            )

        Nothing ->
            ( model, Cmd.none )


dragKindKey : DragKind -> String
dragKindKey kind =
    case kind of
        Pan ->
            ""

        WindowMove sid ->
            sid

        WindowResize sid _ ->
            sid

        PlanMove pid ->
            pid

        PlanResize pid _ ->
            pid


{-| True when the armed drag is a canvas pan (both fingers on the
canvas → pinch; a bar grab + a canvas finger is a bar drag).
-}
isPanArm : Maybe DragState -> Bool
isPanArm drag =
    case drag of
        Just d ->
            d.kind == Pan

        Nothing ->
            False


{-| Touch (or button-less pen) hold on the canvas arms the menu
long-press — but only as the FIRST canvas finger (a second finger means
pinch, and the timer is discarded when the pinch starts). The pan drag
arm coexists: moving past the slop cancels the long-press and pans;
holding still opens the menu (and discards the pan arm).
-}
shouldArmLongPress : P.PointerInfo -> Model -> Bool
shouldArmLongPress pe model =
    pe.target == P.TCanvas
        && canvasPointerCount model == 1
        && model.pinch == Nothing
        && (pe.kind == P.TouchPointer || (pe.kind == P.PenPointer && pe.button == 0))


clearLongPressFor : Int -> Maybe LongPress -> Maybe LongPress
clearLongPressFor pointerId longPress =
    case longPress of
        Just lp ->
            if lp.pointerId == pointerId then
                Nothing

            else
                longPress

        Nothing ->
            Nothing


{-| Apply an in-flight drag move: cross the slop to activate (raising +
focusing window drags), then move the target by kind.
-}
dragMove : P.PointerInfo -> DragState -> Model -> ( Model, Cmd Msg )
dragMove pe d model =
    let
        setDragActive m =
            { m | drag = Maybe.map (\x -> { x | active = True }) m.drag }

        pastSlop =
            P.distance ( d.startMouseX, d.startMouseY ) ( pe.x, pe.y ) > P.slop

        m1 =
            if d.active then
                model

            else if pastSlop then
                -- Activation: the drag is in motion. Raise + focus on
                -- crossing the slop, not on pointerdown, so a tap on a
                -- lower window's bar does not steal focus before the
                -- user commits to a move.
                setDragActive
                    (case d.kind of
                        WindowMove sid ->
                            raiseWindow { model | activeId = Just sid } sid

                        PlanMove pid ->
                            raiseWindow { model | planActiveId = Just pid } pid

                        _ ->
                            model
                    )

            else
                model
    in
    if d.active || pastSlop then
        case d.kind of
            Pan ->
                -- Pan offset is in SCREEN pixels (the translate part of
                -- the transform), so deltas need no scale division. The
                -- safety bound grows with zoom (high zoom covers a
                -- smaller canvas area). No chain redraw: the connection
                -- layer lives INSIDE .canvas, so the transform carries
                -- the curves along.
                let
                    dx =
                        round pe.x - round d.startMouseX

                    dy =
                        round pe.y - round d.startMouseY

                    maxPan =
                        round (toFloat canvasMaxPan * model.canvasScale)

                    newX =
                        clamp -maxPan maxPan (d.startOffsetX + dx)

                    newY =
                        clamp -maxPan maxPan (d.startOffsetY + dy)
                in
                ( { m1 | canvasOffset = { x = newX, y = newY } }, Cmd.none )

            WindowMove sid ->
                let
                    -- Mouse deltas are screen pixels; window coords are
                    -- canvas pixels (canvas layer scaled by
                    -- canvasScale), so divide to keep the window glued
                    -- to the cursor at any zoom level. No viewport
                    -- clamp: the canvas is unbounded and the user
                    -- recovers off-screen windows by panning.
                    dx =
                        round ((pe.x - d.startMouseX) / model.canvasScale)

                    dy =
                        round ((pe.y - d.startMouseY) / model.canvasScale)

                    m2 =
                        { m1
                            | windowPositions =
                                Dict.update sid
                                    (Maybe.map (\pos -> { pos | x = d.startWinX + dx, y = d.startWinY + dy }))
                                    m1.windowPositions
                        }
                in
                -- Re-emit the chain (discrete redraw, Phase A): the
                -- dragged window moved — curves follow it live.
                ( m2, Ports.setConnectionChain (chainPayload m2 m2.connectionChain) )

            PlanMove pid ->
                let
                    dx =
                        round ((pe.x - d.startMouseX) / model.canvasScale)

                    dy =
                        round ((pe.y - d.startMouseY) / model.canvasScale)

                    m2 =
                        { m1
                            | windowPositions =
                                Dict.update pid
                                    (Maybe.map (\pos -> { pos | x = d.startWinX + dx, y = d.startWinY + dy }))
                                    m1.windowPositions
                        }
                in
                ( m2, Ports.setConnectionChain (chainPayload m2 m2.connectionChain) )

            WindowResize _ _ ->
                let
                    ( m2, _ ) =
                        handleResizeMove m1 pe.x pe.y d
                in
                ( m2, Ports.setConnectionChain (chainPayload m2 m2.connectionChain) )

            PlanResize _ _ ->
                let
                    ( m2, _ ) =
                        handleResizeMove m1 pe.x pe.y d
                in
                ( m2, Ports.setConnectionChain (chainPayload m2 m2.connectionChain) )

    else
        ( m1, Cmd.none )


{-| A tap on a window bar (drag armed, never crossed the slop) still
activates the window: pointer capture preventDefaults the compat
mousedown, so the panel's mousedown activation never fires for bar
taps — do the raise/focus here instead.
-}
activateArmedTap : DragState -> Model -> Model
activateArmedTap d model =
    case d.kind of
        WindowMove sid ->
            raiseWindow { model | activeId = Just sid } sid

        PlanMove pid ->
            raiseWindow { model | planActiveId = Just pid } pid

        _ ->
            model


{-| Two-finger pinch zoom centered on the fingers' midpoint; the zoom
factor is the current/start distance ratio (clamped by applyZoom).
-}
pinchMove : Model -> ( Model, Cmd Msg )
pinchMove model =
    case model.pinch of
        Just pc ->
            case ( Dict.get pc.pointerA model.activePointers, Dict.get pc.pointerB model.activePointers ) of
                ( Just a, Just b ) ->
                    let
                        ( midX, midY ) =
                            P.midpoint ( a.x, a.y ) ( b.x, b.y )

                        ratio =
                            P.pinchRatio pc.startDist (P.distance ( a.x, a.y ) ( b.x, b.y ))

                        m1 =
                            applyZoom ratio midX midY model
                    in
                    -- Re-emit the chain: curve stroke-width is
                    -- compensated by canvasScale (3 / scale).
                    ( m1, Ports.setConnectionChain (chainPayload m1 m1.connectionChain) )

                _ ->
                    ( model, Cmd.none )

        Nothing ->
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


-- | Apply a buffered frame/delta/status event to the sessions dict.
-- C2b (§8.1, I-D): `sidFor` routes a frame's core id to Session.id
-- (work-copy frames from fork/resume; plain session = identity). After
-- SessionCreated sets up workCopies it is used to replay buffered frames.
applyPendingEvent : (String -> String) -> E.Value -> Dict String T.SessionState -> Dict String T.SessionState
applyPendingEvent sidFor raw sessions =
    -- Try FrameEvent first (most common for initial messages)
    case D.decodeValue P.frameEventDecoder raw of
        Ok ev ->
            let
                sid =
                    sidFor ev.sessionId
            in
            case Dict.get sid sessions of
                Just session ->
                    Dict.insert sid (H.handleFrameEvent session ev) sessions

                Nothing ->
                    sessions

        Err _ ->
            -- Try DeltaEvent
            case D.decodeValue P.deltaEventDecoder raw of
                Ok ev ->
                    let
                        sid =
                            sidFor ev.sessionId
                    in
                    case Dict.get sid sessions of
                        Just session ->
                            Dict.insert sid (H.handleDeltaEvent session ev) sessions

                        Nothing ->
                            sessions

                Err _ ->
                    -- Try StatusEvent
                    case D.decodeValue P.statusEventDecoder raw of
                        Ok ev ->
                            let
                                sid =
                                    sidFor ev.sessionId
                            in
                            case Dict.get sid sessions of
                                Just session ->
                                    Dict.insert sid
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


-- { sessionId, files: [{ name, uri }], errors } — files dropped onto
-- the prompt input, read to data URIs by transport.js.
droppedFilesDecoder : D.Decoder { sessionId : String, files : List { name : String, uri : String }, errors : List String }
droppedFilesDecoder =
    D.map3
        (\sid files errors -> { sessionId = sid, files = files, errors = errors })
        (D.field "sessionId" D.string)
        (D.field "files"
            (D.list
                (D.map2 (\name uri -> { name = name, uri = uri })
                    (D.field "name" D.string)
                    (D.field "uri" D.string)
                )
            )
        )
        (D.field "errors" (D.list D.string))


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


defaultModelsListResultDecoder : D.Decoder { ok : Bool, models : List T.ModelInfo, activeId : Maybe Int, error : String }
defaultModelsListResultDecoder =
    D.map4
        (\ok models activeId error -> { ok = ok, models = models, activeId = activeId, error = error })
        (D.field "ok" D.bool)
        (D.field "models" (D.list H.modelInfoDecoder))
        (D.field "active_id" (D.maybe D.int))
        (D.field "error" D.string)


defaultModelsActionResultDecoder : D.Decoder { ok : Bool, modelId : Int, error : String }
defaultModelsActionResultDecoder =
    D.map3
        (\ok modelId error -> { ok = ok, modelId = modelId, error = error })
        (D.field "ok" D.bool)
        (D.field "modelId" D.int)
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


settingsListResultDecoder : D.Decoder { ok : Bool, toolConfirm : String, builtinTools : String, systemPrompt : String, reasoningLevel : Int, error : String }
settingsListResultDecoder =
    D.map6
        (\ok toolConfirm builtinTools systemPrompt reasoningLevel error ->
            { ok = ok
            , toolConfirm = toolConfirm
            , builtinTools = builtinTools
            , systemPrompt = systemPrompt
            , reasoningLevel = reasoningLevel
            , error = error
            }
        )
        (D.field "ok" D.bool)
        (D.field "tool_confirm" D.string)
        (D.field "builtin_tools" D.string)
        (D.field "system_prompt" D.string)
        (D.field "reasoning_level" D.int)
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


asrProfileDecoder : D.Decoder AsrProfile
asrProfileDecoder =
    D.map7 AsrProfile
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "protocol" D.string)
        (D.field "url" D.string)
        (D.field "api_key" D.string)
        (D.field "model" D.string)
        (D.field "language" D.string)


asrConfigGetResultDecoder : D.Decoder { ok : Bool, active : String, profiles : List AsrProfile, error : String }
asrConfigGetResultDecoder =
    D.map4
        (\ok active profiles error ->
            { ok = ok
            , active = active
            , profiles = profiles
            , error = error
            }
        )
        (D.field "ok" D.bool)
        (D.field "active" D.string)
        (D.field "profiles" (D.list asrProfileDecoder))
        (D.field "error" D.string)


-- AlayacoreCheckResult: the backend reports whether the alayacore
-- binary was found. { ok : Bool, path : String, error : String } — ok
-- is true on a successful locate (path is the resolved binary path);
-- ok is false on a missing binary (path is "", error is a user-facing
-- message). The frontend renders the banner based on the ok field so
-- a noisy `error` (e.g. set env var to a deleted file) does not by
-- itself show the banner.
alayacoreCheckDecoder : D.Decoder { ok : Bool, path : String, error : String }
alayacoreCheckDecoder =
    D.map3
        (\ok path error -> { ok = ok, path = path, error = error })
        (D.field "ok" D.bool)
        (D.field "path" D.string)
        (D.field "error" D.string)


voiceErrorDecoder : D.Decoder { sessionId : String, message : String }
voiceErrorDecoder =
    D.map2
        (\sessionId message -> { sessionId = sessionId, message = message })
        (D.field "sessionId" D.string)
        (D.field "message" D.string)


rawAudioReadyDecoder : D.Decoder { sessionId : String, uri : String }
rawAudioReadyDecoder =
    D.map2
        (\sessionId uri -> { sessionId = sessionId, uri = uri })
        (D.field "sessionId" D.string)
        (D.field "uri" D.string)


captureAutoStopDecoder : D.Decoder { sessionId : String, kind : String }
captureAutoStopDecoder =
    D.map2
        (\sessionId kind -> { sessionId = sessionId, kind = kind })
        (D.field "sessionId" D.string)
        (D.field "kind" D.string)


asrResultDecoder : D.Decoder { sessionId : String, ok : Bool, text : String, error : String }
asrResultDecoder =
    D.map4
        (\sessionId ok text error -> { sessionId = sessionId, ok = ok, text = text, error = error })
        (D.field "sessionId" D.string)
        (D.field "ok" D.bool)
        (D.field "text" D.string)
        (D.field "error" D.string)


cursorPosResultDecoder : D.Decoder { sessionId : String, pos : Int }
cursorPosResultDecoder =
    D.map2
        (\sessionId pos -> { sessionId = sessionId, pos = pos })
        (D.field "sessionId" D.string)
        (D.field "pos" D.int)


presetInfoDecoder : D.Decoder PresetInfo
presetInfoDecoder =
    D.map2 PresetInfo
        (D.field "name" D.string)
        (D.field "is_seed" D.bool)


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


{-| Move the item at index `from` to index `to` (0-based, clamped to the
list bounds). Used by the Preset Manager's drag-to-reorder — indices
are PRESET indices, not rendered row indices (a preset may show extra
edit rows below its main row).
-}
movePreset : Int -> Int -> List a -> List a
movePreset from to list =
    let
        len =
            List.length list

        f =
            clamp 0 (len - 1) from

        t =
            clamp 0 (len - 1) to
    in
    if len <= 1 || f == t then
        list

    else
        case List.drop f list of
            item :: rest ->
                let
                    withoutItem =
                        List.take f list ++ rest
                in
                List.take t withoutItem
                    ++ (item :: List.drop t withoutItem)

            [] ->
                list


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
    , confirm = \id model ->
        case getActiveSession model of
            Just s ->
                case List.filter (\m -> m.id == id) s.modelSelector.working |> List.head of
                    Just m ->
                        if Sel.isDirty s.modelSelector then
                            -- Unsaved edits: ask to sync before leaving
                            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.askSync sess.modelSelector })
                            , Cmd.none
                            )

                        else
                            ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
                            , Cmd.batch
                                [ Ports.setModel { sessionId = PU.workCopyId model s.id, modelId = m.id }
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
                    { sessionId = PU.workCopyId model s.id
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
    , confirm = \id model ->
        -- A single click on a model (or Enter) makes it the preset's
        -- DEFAULT. Edit is only via the per-row Edit button.
        ( { model
            | defaultModelsEditor =
                let
                    ed =
                        model.defaultModelsEditor
                in
                { ed | error = Nothing }
          }
        , Ports.setDefaultModel
            { preset = model.defaultModelsEditor.preset
            , modelId = id
            }
        )
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
    , confirm = \id model ->
        -- A single click on a server (or Enter) opens its edit page.
        let
            ed =
                model.mcpEditor
        in
        case List.filter (\s -> s.id == id) ed.state.working |> List.head of
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
