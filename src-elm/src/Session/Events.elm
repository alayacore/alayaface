module Session.Events exposing
    ( Action(..)
    , decodeWarning
    , isCurrentWorkCopy
    , bufferPendingEvent
    , pendingEventsCap
    , deltaEvent
    , frameEvent
    , statusEvent
    , applyPendingEvent
    )

{-| Inbound transport events — `DeltaEvent`, `FrameEvent`, `StatusEvent` — and
the routing they share: which session a frame belongs to, whether it is still
current, and what its arrival should cause, with the effects left as `Action`
DATA.

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


## The one thing here that re-enters the dispatcher

`FrameEvent` is the only inbound arm that can, and it does so in exactly one
narrow case: a `model_sync` CO result (`decodeSyncOutcome`) that arrives while
the session's model selector is on its `Syncing` page. That re-entry is
`Defer Msg` — one of two places in this file where a `Msg` appears, the other
being `PlanOffer`'s payload — and the mapper folds it by calling `update`.

The alternative was to inject the dispatcher as a `Dispatch` argument, the way
`Plan/Update.elm` does. Rejected on measurement: `Plan/Update` re-enters
repeatedly and recurses, so threading a function through it earns its cost, and
here the chain would have had to run through a module whose other 400 lines are
pure data. `Defer` keeps that, at the price of one action the mapper must handle
specially.

**`Defer` also drops the frame's other effects, on purpose.** Before the move
this branch returned `update (ForSession …) updatedModel3` and discarded the
frame's own `cmds`/`runnerFrameCmd`/`autoOfferCmd`, so a sync-result CO frame
never re-pinned the viewport. Emitting `[ Defer … ]` ALONE preserves that.
It is questionable — a scroll re-pin may be wanted — but it is the behaviour
under test, and a refactor does not quietly change it. If the drop is wrong, fix
it in a commit of its own that can be argued about on its own.


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


## Live and replay are in this file together

`applyPendingEvent` is the replay path: it decodes the same three event kinds and
applies the same `Session.Handlers` transform, deliberately with no effects and no
plan counting (history replay is suppressed by `planReplaySessions` rather than
re-derived). It lives here beside the live path because the two drifting apart —
a frame handled one way when it arrives and another when it happened to be
buffered — is a bug that only shows up in a race, which is the class of defect
`AGENTS.md` records the B-series learning for.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import App.Types exposing (Model, Msg(..))
import Plan.Detect
import Plan.Runner as R
import Plan.Update as PU
    exposing
        ( becamePlanMessage
        , bumpPlanCount
        , findPlanIdBySession
        , isSessionReady
        , messageBoundToPlan
        , planCountOf
        , planEventFromFrame
        )
import Session.Handlers as H
import Session.Protocol as P
import Session.Selector as Sel exposing (Page(..))
import Session.Types as T


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
  * `SendPrompt`: flush a node prompt the readiness gate was holding. Carries the
    text rather than sending it, so "a ready session releases its queued prompt"
    is an assertion and not a console line.
  * `PlanOffer`: a completed assistant message was recognised as a plan, at this
    message index. The `pendingPlanOffers` entry is written in the same action
    list's model half — the pair cannot be separated, which is what `D0` was
    about.
  * `Defer`: re-enter the dispatcher with this message. The one place an inbound
    event needs to, and the mapper is the only thing that can: see the note above
    on `FrameEvent`'s sync-result CO.
-}
type Action
    = LogWarn String
    | ScrollToBottom String
    | RunnerEvent R.Event
    | SendPrompt String String
    | PlanOffer String Int
    | Defer Msg


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


{-| A complete frame: a finished message, a user echo, a tool result, an `SM`
system message or a `CO` command output. The busiest inbound arm, and the only
one that can re-enter the dispatcher — see `Defer` above.
-}
frameEvent : Model -> E.Value -> ( Model, List Action )
frameEvent model raw =
    case D.decodeValue P.frameEventDecoder raw of
        Err err ->
            -- A malformed event here stops the transcript updating
            -- while the window still looks alive — report it.
            ( model, [ LogWarn (decodeWarning "FrameEvent" err) ] )

        Ok ev ->
            -- C2b (I-G): only handle frames from the current work copy.
            if not (isCurrentWorkCopy model ev.sessionId) then
                ( model, [] )

            else
                -- C2b (I-D): core id → Session.id.
                let
                    sid =
                        PU.sessionIdOfWorkCopy model ev.sessionId
                in
                case Dict.get sid model.sessions of
                    Nothing ->
                        bufferPendingEvent model ev.sessionId raw

                    Just session ->
                        frameForSession model session sid ev raw


{-| The frame arm's body, for a session that IS registered.

These bindings were one `let` in the dispatcher, so their textual order means
nothing — the dependency chain does, and it reads: `prevAccum → becamePlan`,
`readyNow`, `newSession`, `userEchoNow` → `flush` / `follow` → `updatedModel` →
`planOfferFromFrame` → `planEventFromFrame` → `decodeSyncOutcome`. Two of those
take the model from the step before them and two take `updatedModel`
specifically; the names carry that, so do not flatten them.
-}
frameForSession : Model -> T.SessionState -> String -> P.FrameEvent -> E.Value -> ( Model, List Action )
frameForSession model session sid ev raw =
    let
        -- M3/D4: incremental plan count — the accumulated content for this
        -- tag:historyId BEFORE the frame; if the frame's content crosses the
        -- fence for the first time, bump the counter. AT with empty content
        -- (delta-mode terminator) or already-plan accumulated content never
        -- double-counts.
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
        -- (SM {"type":"session","data":{"state":"ready"}}): MCP init done,
        -- replay ended, session interactive.
        readyNow =
            isSessionReady ev

        newSession =
            H.handleFrameEvent session ev

        -- A user echo (UT/UI/UV/UA/UD) is the user's OWN action — sent from
        -- the always-visible input bar, possibly while scrolled up reading
        -- history. Always bring it into view: chat UX requires the new user
        -- message to be visible regardless of auto-follow state (atBottom).
        userEchoNow =
            P.isUserEchoTag ev.tag

        -- A node prompt held by the readiness gate (pendingNodePrompts) is
        -- flushed the moment the session becomes ready.
        flush =
            if readyNow then
                case Dict.get sid model.pendingNodePrompts of
                    Just text ->
                        [ SendPrompt sid text ]

                    Nothing ->
                        []

            else
                []

        -- scrollToBottom is frontend DOM scrolling: elements are named by
        -- window key (Session.id), so pass sid.
        --
        -- Auto-follow re-pins on EVERY frame, not just message-count changes:
        -- frames that only grow an EXISTING message's content (Af tool-arg
        -- deltas, UF tool results, Uf previews, complete AT/AR replacements,
        -- media appended to a user echo) also push content below the fold.
        -- Gating on msgCountChanged left the viewport stuck until the next
        -- assistant-text delta created a new message. State-only frames (SM
        -- status, model sync…) are a harmless no-op: at the bottom, scrollTop
        -- = scrollHeight changes nothing.
        follow =
            if session.atBottom || userEchoNow then
                [ ScrollToBottom sid ]

            else
                []

        updatedModel =
            { model
                | sessions = Dict.insert sid { newSession | ready = newSession.ready || readyNow } model.sessions
                -- On the `||`: `Session.Handlers` already sets `ready` for this
                -- exact frame (handleSystemSession flips it on the same SM
                -- predicate `isSessionReady` reads), so the field is written
                -- twice from two modules and the OR hides that. It is kept
                -- because what is NOT duplicated is `readyNow`'s other two jobs
                -- below — releasing the queued node prompt, and lifting replay
                -- suppression. If the two predicates ever drift, the field still
                -- looks right while the flush silently stops happening, which is
                -- why both are asserted separately in SessionEventsTest.

                , pendingNodePrompts =
                    if readyNow then
                        Dict.remove sid model.pendingNodePrompts

                    else
                        model.pendingNodePrompts
                , planMessageCounts = bumpPlanCount model.planMessageCounts sid becamePlan
                -- Replay suppression: the marker is removed by the core's
                -- explicit readiness signal — SM {"type":"session","data":
                -- {"state":"ready"}} arrives AFTER all replayed history
                -- content (alayacore v0.62.4+, verified against the binary).
                -- No fallback: older cores without the ready SM are not
                -- supported.
                , planReplaySessions =
                    if readyNow then
                        Set.remove sid model.planReplaySessions

                    else
                        model.planReplaySessions
            }

        -- Plan Mode (R2): a completed assistant message carrying the
        -- alayaface-plan marker is auto-offered; recording and announcing are
        -- one decision — see planOfferFromFrame.
        ( updatedModel2, offerActions ) =
            planOfferFromFrame updatedModel sid newSession ev

        -- Runner injection: task done / SM error for a node-owned session
        -- feeds the state machine. planEventFromFrame also tracks task-start
        -- (in_progress:true) so the alayacore boot task frame is not mistaken
        -- for a real task completion (R5 fix).
        ( updatedModel3, runnerEv ) =
            planEventFromFrame updatedModel2 ev

        runnerActions =
            case runnerEv of
                Just runnerEvent ->
                    [ RunnerEvent runnerEvent ]

                Nothing ->
                    []

        -- The order is the original Cmd.batch order (flush, scroll, runner,
        -- offer): port emission order is observable to the bridge.
        frameActions =
            flush ++ follow ++ runnerActions ++ offerActions
    in
    -- model_sync completes asynchronously via CO: success closes the overlay,
    -- failure keeps it open. In this branch ONLY, the frame's own effects are
    -- dropped — see the module comment before changing it.
    case decodeSyncOutcome raw of
        Just ( isError, message ) ->
            if newSession.modelSelector.page == ModelSelSyncing then
                ( updatedModel3, [ Defer (ForSession sid (ModelSelectorSyncResult isError message)) ] )

            else
                ( updatedModel3, frameActions )

        Nothing ->
            ( updatedModel3, frameActions )


{-| Plan Mode (R2): when an assistant message completes with a fenced ```json
block carrying the alayaface-plan marker, AUTO-CREATE the plan (no button). The
offer entry is recorded keyed by message index so replay cannot create
duplicates; `PlanCreateOffer` consumes it.

One decision, two results: the model write and the announcement are returned
together. They used to be two hand-copied guard chains in the arm, and a guard
edited into one and not the other fails silently either way — an offer recorded
but never announced leaves no button, an announced offer that was never recorded
makes `PlanCreateOffer` look up a `Nothing`.

Two orderings are load-bearing and must not be "simplified":

  * the caller passes the model as it stands AFTER `sessions`/`ready` were
    written but BEFORE the offer insert; the guards and the insert read that same
    snapshot, so neither sees the other's copy;
  * `planIdx` comes from `planMessageCounts`, which this frame already bumped via
    `bumpPlanCount` — it is the index of the message that just arrived.

NOTE: in delta mode the AT frame itself is an empty terminator, so detection runs
on the final message content, not `ev.content`.
-}
planOfferFromFrame : Model -> String -> T.SessionState -> P.FrameEvent -> ( Model, List Action )
planOfferFromFrame updatedModel sid newSession ev =
    if ev.tag == "AT" then
        case List.head (List.reverse newSession.messages) of
            Just m ->
                let
                    planIdx =
                        planCountOf updatedModel.planMessageCounts sid

                    offer =
                        if m.role == T.Assistant
                            && not (Set.member sid updatedModel.planReplaySessions)
                            && not (Dict.member ( sid, planIdx ) updatedModel.pendingPlanOffers)
                            && not (messageBoundToPlan updatedModel sid planIdx) then
                            case Plan.Detect.extractPlanJson m.content of
                                Just offerRaw ->
                                    if Plan.Detect.hasPlanTypeMarker offerRaw then
                                        Just offerRaw

                                    else
                                        Nothing

                                Nothing ->
                                    Nothing

                        else
                            Nothing
                in
                case offer of
                    Just offerRaw ->
                        -- Live plan message: create + auto-open immediately. History
                        -- replays (resumed sessions) are suppressed via
                        -- planReplaySessions — their plan messages show the manual
                        -- "Open plan" button instead.
                        ( { updatedModel | pendingPlanOffers = Dict.insert ( sid, planIdx ) offerRaw updatedModel.pendingPlanOffers }
                        , [ PlanOffer sid planIdx ]
                        )

                    Nothing ->
                        ( updatedModel, [] )

            Nothing ->
                ( updatedModel, [] )

    else
        ( updatedModel, [] )


{-| Decode a model_sync CO result: `Just ( isError, message )` when the frame is
a CO for the `model_sync` command, `Nothing` otherwise.

Every field defaults rather than failing: a CO whose shape this client does not
recognise must not take the transcript down with it, and the answer here only
decides whether the model-selector overlay closes.
-}
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


{-| Apply a buffered frame/delta/status event to the sessions dict (the replay
half of `bufferPendingEvent`).

C2b (§8.1, I-D): `sidFor` routes a frame's core id to Session.id (work-copy
frames from fork/resume; plain session = identity). After `SessionCreated` sets
up `workCopies` this replays whatever arrived first.

`FrameEvent` is tried first because it is the most common for initial messages,
then `DeltaEvent`, then `StatusEvent`. Note what replay does NOT do: no plan
counting, no effects, no `ready`/`modelSelector` writes — the transform is the
session content, and a buffered frame must not re-run the decisions the live path
would have made about a frame it never saw in order.
-}
applyPendingEvent : (String -> String) -> E.Value -> Dict String T.SessionState -> Dict String T.SessionState
applyPendingEvent sidFor raw sessions =
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
