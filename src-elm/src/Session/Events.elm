module Session.Events exposing
    ( Action(..)
    , decodeWarning
    , isCurrentWorkCopy
    , bufferPendingEvent
    , pendingEventsCap
    , deltaEvent
    , statusEvent
    )

{-| Inbound transport events: which session a frame belongs to, whether it is
still current, and what its arrival should cause — with the effects left as
`Action` DATA. `DeltaEvent` and `StatusEvent` live here; `FrameEvent` joins in
the next slice.

`Session/Handlers.elm` already owns the per-session transform
(`handleFrameEvent`/`handleDeltaEvent`: messages, tool calls, `historyContents`,
status), and it is pure over `SessionState`. What could not live there is the
part that reads the whole board: which `Session.id` a frame's CORE id maps to
(after a fork, they differ), whether that core is still the current work copy,
what to do when no session is registered yet, and which port call the frame
justifies. That is this module.

It takes `Model` and returns `( Model, List Action )` — the `App/Arch.elm`
shape, for the same reason: the decision spans five fields at a time, so
passing them in individually would rebuild `Model` by hand. Effects stay data so
they are assertable; `grep -c 'Ports\.' src/Session/Events.elm` returns 0, and a
test can say "this path warns once" instead of trusting a console.


## The work-copy guard is the first thing, always

A fork or resume replaces the alayacore process a session talks to, and frames
from the OLD work copy are still in flight. `isCurrentWorkCopy` (C2b, I-G) is
the single gate: skip the frame otherwise, and a `connected: false` from a dying
core marks the new session disconnected, while a stale frame appends to a
transcript the user has already moved past. Every entry point here runs it
before anything else — the guard's position, not just its presence, is what
makes it load-bearing.

The fourth caller of the gate is `SessionCreateError`, which stays in
`App/Update.elm` because it is not an inbound stream event; that is the one call
this module cannot keep honest on its own.


## The buffer is a bounded queue, keyed by core id

Frames arriving for a session this client has not created yet are buffered under
the CORE id and replayed once `SessionCreated` establishes the mapping. See
`bufferPendingEvent` for why the bound and the drop-oldest policy exist.


## Live and replay must not drift

`applyPendingEvent` (`App/Update.elm`) replays the buffer through the same
`Session.Protocol` decoders and the same `Session.Handlers` transform, and
deliberately applies no effects and no plan counting — history is suppressed by
`planReplaySessions` rather than by re-deriving it. When `FrameEvent` moves here,
that function has to be repointed at this module rather than keep its own copy of
the routing: a protocol change applied to the live path alone makes the same
frame behave differently when it happened to be buffered, which is a bug that
only shows up in a race.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import App.Types exposing (Model)
import Plan.Runner as R
import Plan.Update as PU exposing (becamePlanMessage, bumpPlanCount, findPlanIdBySession)
import Session.Handlers as H
import Session.Protocol as P
import Session.Selector as Sel exposing (Page(..))


{-| What an inbound event asks the transport or the app to do. Mapped to
commands by `App.Update`'s `applyEventAction`, which is the only producer of
these commands — so "which code can scroll the view" and "which code can wake
the plan runner" are each one grep.

  * `LogWarn`: report something the user cannot otherwise see (a frame that
    would not decode, a buffer that had to drop frames).
  * `ScrollToBottom`: re-pin auto-follow. Carries `Session.id`, not the core id —
    DOM elements are named by window key.
  * `RunnerEvent`: a plan-runner event derived from the stream. The timestamp is
    added by the mapper, because this module does not know about clocks and a
    test should not have to guess a millisecond to assert that the runner was
    woken.
-}
type Action
    = LogWarn String
    | ScrollToBottom String
    | RunnerEvent R.Event


{-| Why a malformed inbound event is reported instead of discarded.

A frame that fails to decode used to return `( model, Cmd.none )`: the transcript
stopped updating while the window still looked alive, which is the
"infrastructure half-worked" case `AGENTS.md` opens with. The label names the
port that broke, and `D.errorToString` carries the reason.
-}
decodeWarning : String -> D.Error -> String
decodeWarning label err =
    label ++ " decode failed: " ++ D.errorToString err


{-| Is `coreId` the alayacore process this session is talking to NOW (C2b, I-G)?

After a fork or resume the old process may still be emitting; a frame or status
belonging to it must not touch the session the user now sees. A session with no
work copy registered resolves to identity, so ordinary sessions always pass.
-}
isCurrentWorkCopy : Model -> String -> Bool
isCurrentWorkCopy model coreId =
    let
        sid =
            PU.sessionIdOfWorkCopy model coreId
    in
    PU.workCopyId model sid == coreId


{-| Frames that arrive for a session this client has not created yet are
buffered and replayed when it appears (`SessionCreated` → `applyPendingEvent`).
Without a bound the buffer is a leak: the Go backend broadcasts every frame to
every client, so a second tab, an SSH session, or any core this UI never opened
keeps appending to a key that will never be drained — for the lifetime of the
page. 512 frames is far more than a session start can be waiting for (a
replay-long enough to matter would already be on screen), and dropping the
OLDEST keeps the newest state, which is the part the replay needs: `taskRunning
= True` or the final `model` frame is worthless without the messages that came
before it.

One `logWarn` per session, not per frame: `pendingOverflow` records that this
key already said so. Without it a runaway core writes the log at frame rate —
and the point of the warning is a human reading it, not the disc it lands on.
-}
pendingEventsCap : Int
pendingEventsCap =
    512


bufferPendingEvent : Model -> String -> E.Value -> ( Model, List Action )
bufferPendingEvent model sessionId raw =
    let
        existing =
            Dict.get sessionId model.pendingEvents |> Maybe.withDefault []

        queued =
            existing ++ [ raw ]

        over =
            List.length queued - pendingEventsCap

        alreadyLogged =
            Set.member sessionId model.pendingOverflow

        kept =
            if over > 0 then
                List.drop over queued

            else
                queued

        warn =
            -- over > 0 on the FIRST frame that pushes a key past the cap; every
            -- later frame sees the flag already set, so this fires once.
            if over > 0 && not alreadyLogged then
                [ LogWarn
                    ("dropping oldest buffered events for unknown session "
                        ++ sessionId
                        ++ " (buffer capped at "
                        ++ String.fromInt pendingEventsCap
                        ++ ")"
                    )
                ]

            else
                []
    in
    ( { model
        | pendingEvents = Dict.insert sessionId kept model.pendingEvents
        , pendingOverflow =
            if over > 0 then
                Set.insert sessionId model.pendingOverflow

            else
                model.pendingOverflow
      }
    , warn
    )


{-| A `delta` frame: text appended to an in-flight message.

Writes `sessions` and `planMessageCounts` only. An unknown session buffers; a
stale work copy is ignored; a malformed frame warns.
-}
deltaEvent : Model -> E.Value -> ( Model, List Action )
deltaEvent model raw =
    case D.decodeValue P.deltaEventDecoder raw of
        Err err ->
            -- A malformed event here stops the transcript updating
            -- while the window still looks alive — report it.
            ( model, [ LogWarn (decodeWarning "DeltaEvent" err) ] )

        Ok ev ->
            -- C2b (I-G): only handle frames from the CURRENT work
            -- copy — late frames/disconnects from an old work copy
            -- (replaced by a fork) would pollute the new entry.
            if not (isCurrentWorkCopy model ev.sessionId) then
                ( model, [] )

            else
                -- C2b (I-D): frame core id → Session.id (work-copy
                -- frame; plain session = identity).
                let
                    sid =
                        PU.sessionIdOfWorkCopy model ev.sessionId
                in
                case Dict.get sid model.sessions of
                    -- Buffering is still keyed by core id (replayed
                    -- with routing once SessionCreated sets up
                    -- workCopies).
                    Nothing ->
                        bufferPendingEvent model ev.sessionId raw

                    Just session ->
                        -- M3/D4: incremental plan count — the delta
                        -- accumulator for this tag:historyId before
                        -- and after; crossing the ```json fence
                        -- bumps the counter exactly once per plan
                        -- message (replaces the per-frame O(n)
                        -- planIndexForMessage scan).
                        let
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
                            follow =
                                if session.atBottom then
                                    [ ScrollToBottom sid ]

                                else
                                    []
                        in
                        ( { model
                            | sessions = Dict.insert sid newSession model.sessions
                            , planMessageCounts = bumpPlanCount model.planMessageCounts sid becamePlan
                          }
                        , follow
                        )


{-| A `SM` status frame: the core reports connection state (and, for
`type: "session"`, readiness — which arrives as a `FrameEvent`, not here).

Writes `sessions` — `connected`, `statusMsg`, `sendPending`, and on a
disconnect mid-sync the model-selector page too. A session owned by a plan node
additionally fails that node: the runner needs `SessionDisconnected` whether or
not this client still has the session registered, which is why the runner action
is computed from `model` before the session lookup and is batched with the
buffer path as well.
-}
statusEvent : Model -> E.Value -> ( Model, List Action )
statusEvent model raw =
    case D.decodeValue P.statusEventDecoder raw of
        Err err ->
            -- A malformed event here stops the transcript updating
            -- while the window still looks alive — report it.
            ( model, [ LogWarn (decodeWarning "StatusEvent" err) ] )

        Ok ev ->
            -- C2b (I-G): only handle status events from the CURRENT
            -- work copy (a connected:false from an old work copy
            -- being closed must not pollute the new entry).
            if not (isCurrentWorkCopy model ev.sessionId) then
                ( model, [] )

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
                    runnerActions =
                        if ev.connected then
                            []

                        else
                            case findPlanIdBySession model sid of
                                Just _ ->
                                    [ RunnerEvent (R.SessionDisconnected sid ev.message) ]

                                Nothing ->
                                    []
                in
                case Dict.get sid model.sessions of
                    Nothing ->
                        let
                            ( model1, bufferActions ) =
                                bufferPendingEvent model ev.sessionId raw
                        in
                        ( model1, bufferActions ++ runnerActions )

                    Just session ->
                        let
                            updated =
                                { session
                                    | connected = ev.connected
                                    , statusMsg = ev.message
                                    -- A disconnect means any in-flight
                                    -- prompt can never be echoed back —
                                    -- clear the stuck "Sending…" state.
                                    , sendPending =
                                        if ev.connected then
                                            session.sendPending

                                        else
                                            False
                                }
                        in
                        if not ev.connected && session.modelSelector.page == ModelSelSyncing then
                            -- A disconnect means the model_sync CO will
                            -- never arrive — fail the sync instead of
                            -- leaving the overlay stuck.
                            ( { model
                                | sessions =
                                    Dict.insert sid
                                        { updated
                                            | modelSelector = Sel.syncFailed "Session disconnected during sync" updated.modelSelector
                                        }
                                        model.sessions
                              }
                            , runnerActions
                            )

                        else
                            ( { model | sessions = Dict.insert sid updated model.sessions }
                            , runnerActions
                            )
