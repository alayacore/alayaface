module App.Windows exposing
    ( defaultWinW
    , defaultWinH
    , planDefaultWinW
    , planDefaultWinH
    , minWinW
    , minWinH
    , canvasGapY
    , planStepY
    , nodeGapX
    , nodeStepX
    , nodeStepY
    , canvasMargin
    , canvasMaxPan
    , canvasMinScale
    , canvasMaxScale
    , getPlanWin
    , setPlanWin
    , updateActivePlanWin
    , originLiveId
    , openPlansForOrigin
    , openNodeSessionsForPlan
    , pendingNodePlanId
    , centeredSessionPos
    , centeredPlanPos
    , planPositionBelowSession
    , nodeSessionPositionBesidePlan
    , applyZoom
    , bringIntoView
    , addPlanWindow
    , winRect
    , winRectList
    , hasWin
    , isSolo
    , soloKey
    , soloRect
    , enterSolo
    , exitSolo
    , SoloChange(..)
    , followSolo
    , soloTarget
    , visibleWindows
    , attentionCounts
    , chainCtx
    , chainPayload
    , connectionChainForSession
    , connectionChainForPlan
    , raiseWindow
    , raiseChainWindows
    , dropChainSession
    , handleResizeMove
    , resizeDimensions
    )

{-| Window / canvas / zoom / drag / z-index management (M2): window
placement rules, canvas pan & zoom, connection-chain z-ordering, plan
window accessors, and resize math. Pure helpers only — no transports.
Extracted from App/Update.elm (D2). Types live in App.Types.
-}

import Dict exposing (Dict)
import App.Types exposing (..)
import App.NodeConnection as NC
import Plan.Meta as PM
import Session.Types as T


-- ─── Effective window geometry (INV1) ───────────────────────────────
--
-- THESE THREE ACCESSORS ARE THE SOLE READ PATH FOR "WHERE IS A WINDOW".
-- `windowPositions` stays the single source of truth for canvas layout
-- (SD4) — it is the store, and writes to it remain direct. But a *read*
-- must go through here, because the geometry a window is drawn with is
-- not always the stored one: solo view (F1) derives a full-viewport
-- rect for the topmost window and makes every other window invisible.
-- Reading the dict directly in the view layer would leave half the model
-- (chainPayload, armDrag, bringIntoView, planFocusAboveSession, the
-- placement rules) describing a screen that no longer exists.
--
-- Enforced by scripts/check-layout-invariants.sh: no
-- `Dict.get|Dict.member|Dict.toList` on `windowPositions` outside this
-- module, and the in-module count can only shrink. See TODO.md INV1.


{-| Where a window effectively is, by window key (session id or plan id).
`Nothing` means "not rendered" — no such window, or hidden because another
window is solo. See the module header: this is the SOLE read path for
geometry, and the solo override below is the whole reason it exists.
-}
winRect : Model -> String -> Maybe WindowPos
winRect model key =
    case soloKey model of
        Nothing ->
            layoutRect model key

        Just solo ->
            -- Visibility and geometry are ONE derivation: the solo window
            -- gets the viewport, everything else gets Nothing (so the view
            -- never renders it, SD6).
            if solo == key then
                Just (soloRect model key)

            else
                Nothing


{-| Every window with its effective rect — that is, every window the user
can currently see. In solo that is the one solo window, and with no solo it
is the whole board.
-}
winRectList : Model -> List ( String, WindowPos )
winRectList model =
    case soloKey model of
        Nothing ->
            Dict.toList model.windowPositions

        Just solo ->
            winRect model solo |> Maybe.map (List.singleton << Tuple.pair solo) |> Maybe.withDefault []


{-| Is there a window under this key at all? Distinguishes "no window"
from "window at some rect" for the create/close paths. Deliberately NOT
solo-aware: a hidden window still HAS a window (SD1 — solo never destroys
anything), and the close/create bookkeeping must see it.
-}
hasWin : Model -> String -> Bool
hasWin model key =
    Dict.member key model.windowPositions


{-| The layout store, read directly. Placement rules anchor on THIS, not on
`winRect`: their question is "where in the canvas does this new window join
the layout?", and answering it with the solo window's fake viewport rect
would write a viewport-relative position into the persistent layout —
exactly what SD4 forbids ("entering/leaving solo never writes
windowPositions"). Solo is a presentation state; the board underneath it is
unchanged and stays the anchor.
-}
layoutRect : Model -> String -> Maybe WindowPos
layoutRect model key =
    Dict.get key model.windowPositions


-- ─── Solo view (F1) ─────────────────────────────────────────────────


{-| Is some window currently solo? Derived, so a `soloWin` left pointing at
a closed window reads as "not solo" (INV2's second layer).
-}
isSolo : Model -> Bool
isSolo model =
    soloKey model /= Nothing


{-| The solo window key, but only while that window still exists. This is
the ONLY reader of `soloWin` (INV2b): every solo question — geometry,
visibility, dragging, the chain — goes through here, so a stale key can
never blank the screen.
-}
soloKey : Model -> Maybe String
soloKey model =
    model.soloWin |> Maybe.andThen (\key -> if hasWin model key then Just key else Nothing)


{-| The effective rect of the solo window: the whole viewport, expressed in
CANVAS coordinates. The panels live inside `.canvas`, which is
`translate3d(offset) scale(scale)`, so the viewport's own rect is the
inverse transform of (0, 0, appWidth, appHeight) — the same conversion
`centeredSessionPos` uses. Deriving it (instead of writing it) is SD5: an OS
resize or a `RequerySize` moves it for free, and exiting solo has nothing to
restore. `z` comes from the stored rect so entering solo does not reorder
anything.
-}
soloRect : Model -> String -> WindowPos
soloRect model key =
    { x = round ((0 - toFloat model.canvasOffset.x) / model.canvasScale)
    , y = round ((0 - toFloat model.canvasOffset.y) / model.canvasScale)
    , w = max minWinW (round (toFloat model.appWidth / model.canvasScale))
    , h = max minWinH (round (toFloat model.appHeight / model.canvasScale))
    , z = layoutRect model key |> Maybe.map .z |> Maybe.withDefault model.nextZIndex
    }


{-| Writer #1 of `soloWin` (INV3). Does not touch the layout store (INV4).
-}
enterSolo : String -> Model -> Model
enterSolo key model =
    { model | soloWin = Just key }


{-| Writer #2 of `soloWin` (INV3).
-}
exitSolo : Model -> Model
exitSolo model =
    { model | soloWin = Nothing }


{-| Which LIVE session a window belongs to: a session window is its own
owner; a plan window's owner is the session that created it (Nothing once
that session is closed). Used by the SD3/SD8 follow test — "did this window
come from what the user is looking at?" — without comparing ids by hand in
three places.
-}
windowOwner : Model -> String -> Maybe String
windowOwner model key =
    if Dict.member key model.sessions then
        Just key

    else
        originLiveId model key


{-| Should a newly opened plan window take the solo view (SD3)? Yes when it
belongs to the SAME live session as the currently solo window — the user
opened a plan from the session they are looking at, or a sub-plan of the plan
they are looking at. No when it belongs to a different session: that is the
runner's or another window's business, and it must not steal the presentation
(SD8's reason, applied to plans).
-}
soloFollowsPlan : Model -> String -> Bool
soloFollowsPlan model newPlanId =
    case ( soloKey model, windowOwner model newPlanId ) of
        ( Just sk, Just newOwner ) ->
            windowOwner model sk == Just newOwner

        _ ->
            False


{-| Writer #3 of `soloWin` (INV3): the SD8/SD9 follow logic, both
directions in one place.

  - `SoloCreated key` — a window the USER created takes the solo view
    (SD8), but only if something was already solo: creating a window in
    canvas view must never enter solo by itself. A window created by the
    PLAN RUNNER never comes here (the caller checks), so it cannot steal
    solo (SD8) — it waits behind the solo window and shows up in the
    attention badge (SD11).
  - `SoloClosed key` — solo cannot outlive its window (SD9). It clears
    only when the closing window IS the solo one; any other close (a
    runner session finishing in the background, a cascade that does not
    own the solo window) leaves solo alone.
-}
type SoloChange
    = SoloCreated String
    | SoloClosed String


followSolo : SoloChange -> Model -> Model
followSolo change model =
    case change of
        SoloCreated key ->
            if isSolo model then
                { model | soloWin = Just key }

            else if model.soloWin /= Nothing then
                -- Not solo (INV2b: the key `soloWin` holds is gone) but the
                -- field is still dirty. Clear it here rather than leave a
                -- time bomb: session ids are REUSED by resume (Session.id =
                -- the on-disk dir id), so a stale key would silently re-attach
                -- solo the moment that session is opened again.
                { model | soloWin = Nothing }

            else
                model

        SoloClosed key ->
            -- Compares the RAW field, deliberately: this runs on models where
            -- the window is already removed from the store (the close blocks
            -- below), so the derived `soloKey` is Nothing by then and could
            -- not be matched. De-attaching a dangling `soloWin` is exactly
            -- what SD9 asks for.
            if model.soloWin == Just key then
                { model | soloWin = Nothing }

            else
                model


{-| Which of these window keys are on screen — the view's filter for
`sessionOrder` / `planOrder` (SD6: a hidden window is not rendered at all,
not hidden with CSS). Kept here so the renderer and `winRect` can never
disagree about what is visible: both ask `winRect`.
-}
visibleWindows : Model -> List String -> List String
visibleWindows model keys =
    List.filter (\key -> winRect model key /= Nothing) keys


{-| The two counts the solo view's exit control carries (SD11): hidden
windows that are BLOCKED on the user, and hidden windows that are merely
busy.

Solo hides a window, and a window can be waiting for an answer — a tool
confirmation you never saw, an MCP auth prompt, a close confirmation. That is
not a cosmetic problem: a hidden modal stops its session's whole run, and the
user has no way to notice. So the control that leaves solo says what is
behind it.

`waiting` is exactly "this session would render an overlay", i.e. the same
conditions `App/View.elm`'s overlay renderers test — `viewCloseConfirmOverlay`,
`viewCancelTaskConfirmOverlay`, `viewConfirmOverlay`, `viewMcpInitOverlay`,
`viewFilePickerOverlay`, `viewModelSelectorOverlay`,
`viewMediaPreviewOverlay`. Change a renderer's guard and change this with it;
the two lists are one fact about the UI expressed twice because one of them is
spread over seven view functions that must not import each other. (`mcpStatus`
is deliberately ` /= Nothing` rather than a copy of the init overlay's
per-status filter: any MCP state worth showing the overlay for is also worth
interrupting solo for, and "connecting" with an empty server list resolves to
Nothing anyway.)
-}
attentionCounts : Model -> { waiting : Int, running : Int }
attentionCounts model =
    let
        -- Hidden = no effective rect (SD6's own definition). Only sessions
        -- are counted: a plan window has no modal state of its own, and a
        -- plan that needs the user surfaces through its session.
        hidden =
            model.sessionOrder
                |> List.filter (\key -> winRect model key == Nothing)
                |> List.filterMap (\key -> Dict.get key model.sessions)

        step s acc =
            { waiting = acc.waiting + (if sessionIsWaiting s then 1 else 0)
            , running = acc.running + (if s.taskRunning then 1 else 0)
            }
    in
    List.foldl step { waiting = 0, running = 0 } hidden


{-| Would this session render a blocking overlay right now? The list must
match `App/View.elm`'s overlay renderers — `viewConfirmOverlay`,
`viewCloseConfirmOverlay`, `viewCancelTaskConfirmOverlay`,
`viewMcpInitOverlay`, `viewFilePickerOverlay`, `viewModelSelectorOverlay`,
`viewMediaPreviewOverlay` — and those carry a comment pointing back here. If a
new modal appears in the view and not here, solo stops reporting it and the
user never learns their run is stalled.
-}
sessionIsWaiting : T.SessionState -> Bool
sessionIsWaiting s =
    s.closeConfirm
        || s.cancelTaskConfirm
        || not (List.isEmpty s.pendingConfirm)
        || not (List.isEmpty s.pendingMcpAuths)
        || s.mcpAuthRunning /= Nothing
        || s.mcpStatus /= Nothing
        || s.filePicker.show
        || s.showModelSelector
        || s.mediaPreview /= Nothing


{-| The topmost window — what "solo this window" means when the command has
no panel of its own (the global menu item, Ctrl+Shift+F). Same answer as
Ctrl+W gives for "which window is the user focused on": the plan when its
window sits on the session's, else the active session, else the active plan.
`Nothing` when the board is empty.
-}
soloTarget : Model -> Maybe String
soloTarget model =
    case ( model.planActiveId, model.activeId ) of
        ( Just pid, Just sid ) ->
            case ( layoutRect model pid, layoutRect model sid ) of
                ( Just p, Just s ) ->
                    if p.z > s.z then
                        Just pid

                    else
                        Just sid

                ( Just _, Nothing ) ->
                    Just pid

                ( Nothing, Just _ ) ->
                    Just sid

                ( Nothing, Nothing ) ->
                    Nothing

        ( Just pid, Nothing ) ->
            Just pid

        ( Nothing, Just sid ) ->
            Just sid

        ( Nothing, Nothing ) ->
            Nothing


defaultWinW : Int
defaultWinW = 560

defaultWinH : Int
defaultWinH = 640

-- Plan windows use the SAME default width as session windows (the DAG
-- canvas adapts; a plan sits below its owning session so the left edges
-- align); height stays larger for the header + canvas.
planDefaultWinW : Int
planDefaultWinW = 560

planDefaultWinH : Int
planDefaultWinH = 720

minWinW : Int
minWinW = 300

minWinH : Int
minWinH = 200

-- Infinite-canvas placement constants.
-- New windows are anchored to their SOURCE window (a plan opens below
-- the session that created it; a node session opens right of its plan),
-- with same-source windows cascading down / stacking with a slight
-- offset. Fallback placement (no live source) centers on the viewport.
canvasGapY : Int
canvasGapY = 24

planStepY : Int
planStepY = 36

nodeGapX : Int
nodeGapX = 24

nodeStepX : Int
nodeStepX = 28

nodeStepY : Int
nodeStepY = 24

-- bringIntoView keeps this much breathing room around a fresh window
-- when panning the canvas toward it.
canvasMargin : Int
canvasMargin = 24

-- Safety bound for canvas pan (infinite in principle; guards float
-- precision and runaway drags). Scales with zoom: at high zoom the
-- viewport covers a smaller canvas area, so more pan distance is legal.
canvasMaxPan : Int
canvasMaxPan = 100000

-- Canvas zoom limits (scale factor, 1.0 = 100%).
canvasMinScale : Float
canvasMinScale = 0.2

canvasMaxScale : Float
canvasMaxScale = 4.0
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
chainCtx : Model -> NC.ChainCtx
chainCtx model =
    { nodeSessions = model.planNodeSessions
    , liveSessions = Dict.map (\_ _ -> ()) model.sessions
    -- C2b-7: no lineage — a plan's owning session IS its origin (stable Session.id).
    , planOrigins =
        Dict.map
            (\_ meta -> meta.origin.sessionId)
            model.planMetas
    }


{-| Build the FULL connection chain for a focused session: the session's
own node↔session segment plus every ancestor segment up to the
top-level session — focusing a deep node session shows the whole path.
[] for plain sessions (not bound to a plan node).
-}
connectionChainForSession : Model -> String -> List NC.ChainSegment
connectionChainForSession model sid =
    NC.chainForSession (chainCtx model) sid


{-| Build the FULL connection chain for an active plan window: the
plan's own segment to its owning session, plus (for a sub-plan) the
owning session's whole ancestor chain up to the top-level session.
[] when the owning session is closed.
-}
connectionChainForPlan : Model -> String -> List NC.ChainSegment
connectionChainForPlan model planId =
    NC.chainForPlan (chainCtx model) planId


{-| Raise every window on the connection chain so the whole path is
visible, ordered top→bottom: the focused window first, then its plan,
then the plan's owning session, then that session's plan, … up to the
top-level session. Every node curve is drawn at its plan's z (below the
session, above the plan) and every plan curve at its plan's z (above
both participants, since the plan sits directly above its owning
session) — so no curve is buried. Returns the updated positions and the
next free z index (rebased — z stays bounded, see `rebasePositions`).
Windows without a recorded position (e.g. a closed plan) are skipped;
transport.js hides their segments anyway.
-}
raiseChainWindows : Model -> List NC.ChainSegment -> ( Dict String WindowPos, Int )
raiseChainWindows model chain =
    let
        addWin k ws =
            if List.member k ws then
                ws

            else
                ws ++ [ k ]

        -- Top→bottom order of every window on the path (deduped).
        windows =
            List.foldl
                (\seg acc ->
                    case seg.kind of
                        "node" ->
                            addWin seg.planId (addWin seg.sessionId acc)

                        _ ->
                            addWin seg.sessionId (addWin seg.planId acc)
                )
                []
                chain

        count =
            List.length windows

        ( positions, _ ) =
            List.foldl
                (\k ( pos, z ) ->
                    ( Dict.update k
                        (Maybe.map (\p -> { p | z = z }))
                        pos
                    , z - 1
                    )
                )
                ( model.windowPositions, model.nextZIndex + count - 1 )
                windows
    in
    rebasePositions positions (model.nextZIndex + count)


-- ─── Z manager (P39/D6) ─────────────────────────────────────────────
--
-- Windows are FOCUSED by list order (raiseWindow moves a window to the
-- end of its sessionOrder/planOrder list — DOM order, last = top).
-- Numeric z survives only for two things: ordering windows ACROSS the
-- session/plan lists (a focused session must sit above plans) and
-- layering the connection curves between windows. To keep z bounded
-- (no unbounded nextZIndex, no z-cap patches), every raise bumps
-- nextZIndex by one and, once it crosses zRebaseThreshold, ALL z
-- values are rebased down by a constant (relative order unchanged).

zRebaseThreshold : Int
zRebaseThreshold =
    500


-- After a rebase the highest window lands at this z (nextZIndex =
-- zRebaseFloor + 1, always well below the modal overlays at 1000000).
zRebaseFloor : Int
zRebaseFloor =
    100


{-| Subtract a constant from every window z (and from nextZIndex) so the
highest z lands at zRebaseFloor. Relative order is preserved exactly
(subtracting the same constant from every value); values may go
negative inside the canvas stacking context — harmless, the canvas
layer is transparent and the curves are children of the same context.
-}
rebasePositions : Dict String WindowPos -> Int -> ( Dict String WindowPos, Int )
rebasePositions positions nextZ =
    if nextZ <= zRebaseThreshold then
        ( positions, nextZ )

    else
        let
            -- nextZ = max assigned z + 1, so dropping nextZ to
            -- zRebaseFloor + 1 puts the top window at zRebaseFloor.
            drop =
                max 0 (nextZ - zRebaseFloor - 1)
        in
        ( Dict.map (\_ p -> { p | z = p.z - drop }) positions
        , nextZ - drop
        )


{-| Bound the model's z state (positions + nextZIndex) the same way.
-}
rebaseZ : Model -> Model
rebaseZ model =
    let
        ( positions, nextZ ) =
            rebasePositions model.windowPositions model.nextZIndex
    in
    { model
        | windowPositions = positions
        , nextZIndex = nextZ
    }


moveToEnd : String -> List String -> List String
moveToEnd key list =
    List.filter ((/=) key) list ++ [ key ]


{-| Focus a window (D6): move it to the end of its order list (DOM
order = intra-list focus) and give it the next z (cross-list ordering),
bumping the bounded nextZIndex. Works for session AND plan windows;
unknown keys (no window) are a no-op.
-}
raiseWindow : Model -> String -> Model
raiseWindow model key =
    if hasWin model key then
        let
            m1 =
                if Dict.member key model.sessions then
                    { model | sessionOrder = moveToEnd key model.sessionOrder }

                else if Dict.member key model.planWindows then
                    { model | planOrder = moveToEnd key model.planOrder }

                else
                    model

            positions =
                Dict.update key
                    (Maybe.map (\p -> { p | z = m1.nextZIndex }))
                    m1.windowPositions

            m2 =
                { m1
                    | windowPositions = positions
                    , nextZIndex = m1.nextZIndex + 1
                }
        in
        if m2.nextZIndex > zRebaseThreshold then
            rebaseZ m2

        else
            m2

    else
        model


-- ─── Chain payload (P39/Phase A) ────────────────────────────────────
--
-- The setConnectionChain port payload: segments + every window's
-- canvas rect/z + per-plan DAG scrollTop + the canvas scale (curve
-- stroke width is compensated 3 / scale). Pure — chain.js only draws
-- what Elm sends (no window measuring, no rAF loop).

{-| Build the setConnectionChain payload from the model: the chain plus
the canvas state chain.js needs to draw curves in canvas coordinates.

SOLO IS A CANVAS FEATURE (SD13): while a window is solo the payload is EMPTY
on both sides — no segments, no positions. Not "the one visible window's
rect", because chain.js then still has segments to draw between ids whose
panels are gone. The emptiness is derived HERE rather than at the 18
`Ports.setConnectionChain` call sites, so no call site has to know solo
exists, and `ExitSolo` re-sends by calling this same function on a model that
is no longer solo.
-}
chainPayload : Model -> List NC.ChainSegment -> { segments : List NC.ChainSegment, positions : List { id : String, x : Int, y : Int, w : Int, h : Int, z : Int }, canvasScale : Float }
chainPayload model segments =
    if isSolo model then
        { segments = []
        , positions = []
        , canvasScale = model.canvasScale
        }

    else
        { segments = segments
        , positions =
            winRectList model
                |> List.map
                    (\( id, p ) ->
                        { id = id
                        , x = p.x
                        , y = p.y
                        , w = p.w
                        , h = p.h
                        , z = p.z
                        }
                    )
        , canvasScale = model.canvasScale
        }


{-| Drop every chain segment that references a closed session. If the
ANCHOR (the first segment — the focused session, or a plan segment's
owning session) is the one that closed, the whole chain goes: the focus
is gone and the next focus rebuilds it.
-}
dropChainSession : List NC.ChainSegment -> String -> List NC.ChainSegment
dropChainSession chain sid =
    case chain of
        first :: _ ->
            if first.sessionId == sid then
                []

            else
                List.filter (\seg -> seg.sessionId /= sid) chain

        [] ->
            []


{-| Focus a session: raise it above everything else. If it belongs to a
plan node, raise the whole connection chain (its plan window to the
second layer, that plan's owning session below it, and so on up to the
top-level session) and tell transport.js to draw every segment — a deep
node session's full path is visible. Otherwise hide any curves.
-}
originLiveId : Model -> String -> Maybe String
originLiveId model planId =
    Dict.get planId model.planMetas
        |> Maybe.map (.origin >> .sessionId)
        |> Maybe.andThen (NC.liveSessionForOrigin model.sessions)


{-| Number of plan windows currently open that belong to the given LIVE
source session. Used to cascade same-source plans downward.
-}
openPlansForOrigin : Model -> String -> Int
openPlansForOrigin model liveOriginId =
    Dict.foldl
        (\planId _ acc ->
            case originLiveId model planId of
                Just lid ->
                    if lid == liveOriginId then
                        acc + 1

                    else
                        acc

                Nothing ->
                    acc
        )
        0
        model.planWindows


{-| Number of node-session windows currently open for a plan (label
"planId/nodeId" and the session is still alive). Used to stack
same-plan sessions beside the plan with a slight offset.
-}
openNodeSessionsForPlan : Model -> String -> Int
openNodeSessionsForPlan model planId =
    Dict.foldl
        (\sid label acc ->
            if String.startsWith (planId ++ "/") label && Dict.member sid model.sessions then
                acc + 1

            else
                acc
        )
        0
        model.planNodeSessions


{-| The plan a PENDING session creation belongs to: a runner create
(planCreating) or a node resume (planResumeFrom → planNodeSessions
label). Used to place the fresh session window beside its plan.
-}
pendingNodePlanId : Model -> Maybe String
pendingNodePlanId model =
    case model.planCreating of
        Just (RunnerCreate planId _) ->
            Just planId

        _ ->
            case model.planResumeFrom of
                Just origId ->
                    Dict.get origId model.planNodeSessions
                        |> Maybe.andThen NC.parseNodeConnection
                        |> Maybe.map Tuple.first

                Nothing ->
                    Nothing


{-| Viewport-centered fallback placement for a plain session window
(New Session / fork / resume of a plain session): centered on the
current viewport, cascading with the same 6×4 stagger as before.
-}
centeredSessionPos : Model -> WindowPos
centeredSessionPos model =
    { x = round ((toFloat (model.appWidth // 2 - defaultWinW // 2 + remainderBy 6 model.nextSessionNum * 50) - toFloat model.canvasOffset.x) / model.canvasScale)
    , y = round ((toFloat (model.appHeight // 2 - defaultWinH // 2 + remainderBy 4 model.nextSessionNum * 40) - toFloat model.canvasOffset.y) / model.canvasScale)
    , w = defaultWinW
    , h = defaultWinH
    , z = model.nextZIndex
    }


{-| Viewport-centered fallback placement for a plan window opened from
the manager (no live owning session).
-}
centeredPlanPos : Model -> WindowPos
centeredPlanPos model =
    let
        n =
            Dict.size model.planWindows
    in
    { x = round ((toFloat (model.appWidth // 2 - planDefaultWinW // 2 + remainderBy 6 n * 50) - toFloat model.canvasOffset.x) / model.canvasScale)
    , y = round ((toFloat (model.appHeight // 2 - planDefaultWinH // 2 + remainderBy 4 n * 40) - toFloat model.canvasOffset.y) / model.canvasScale)
    , w = planDefaultWinW
    , h = planDefaultWinH
    , z = model.nextZIndex
    }


{-| Placement rule 1 (session → plan): the new plan window sits directly
below its owning session, cascading downward as more plans open for the
same session.
-}
planPositionBelowSession : Model -> String -> WindowPos
planPositionBelowSession model liveOriginId =
    case layoutRect model liveOriginId of
        Just sp ->
            { x = sp.x
            , y = sp.y + sp.h + canvasGapY + openPlansForOrigin model liveOriginId * planStepY
            , w = planDefaultWinW
            , h = planDefaultWinH
            , z = model.nextZIndex
            }

        Nothing ->
            centeredPlanPos model


{-| Placement rule 2 (plan → node session): the new session window sits
directly right of its plan, stacking right-and-down with a slight
offset as more node sessions open for the same plan.
-}
nodeSessionPositionBesidePlan : Model -> String -> WindowPos
nodeSessionPositionBesidePlan model planId =
    case layoutRect model planId of
        Just pp ->
            let
                n =
                    openNodeSessionsForPlan model planId
            in
            { x = pp.x + pp.w + nodeGapX + n * nodeStepX
            , y = pp.y + n * nodeStepY
            , w = defaultWinW
            , h = defaultWinH
            , z = model.nextZIndex
            }

        Nothing ->
            centeredSessionPos model


{-| Apply a zoom factor centered on viewport point (mx, my): the canvas
point under the cursor stays under the cursor. Derivation:
canvas point c = (mx - ox) / s; after zoom mx = c * s' + ox' so
ox' = mx - (mx - ox) * (s'/s). Screen = canvas * scale + offset.
-}
applyZoom : Float -> Float -> Float -> Model -> Model
applyZoom factor mx my model =
    let
        oldScale =
            model.canvasScale

        newScale =
            clamp canvasMinScale canvasMaxScale (oldScale * factor)

        k =
            newScale / oldScale

        ox =
            toFloat model.canvasOffset.x

        oy =
            toFloat model.canvasOffset.y
    in
    { model
        | canvasScale = newScale
        , canvasOffset =
            { x = round (mx - (mx - ox) * k)
            , y = round (my - (my - oy) * k)
            }
    }


{-| Pan the canvas so a window (canvas coordinates) is visible in the
viewport, keeping at least canvasMargin on each side. New windows are
placed relative to their source — which may be far off-screen — so a
fresh window must bring itself into view or the user would see nothing.
-}
bringIntoView : Model -> WindowPos -> Model
bringIntoView model pos =
    -- Window rect converted to SCREEN coordinates (screen = canvas *
    -- scale + offset) before comparing against the viewport.
    let
        s =
            model.canvasScale

        vx =
            toFloat pos.x * s + toFloat model.canvasOffset.x

        vy =
            toFloat pos.y * s + toFloat model.canvasOffset.y

        w =
            toFloat pos.w

        h =
            toFloat pos.h

        margin =
            toFloat canvasMargin

        dx =
            if vx + w < margin then
                margin - (vx + w)

            else if vx > toFloat model.appWidth - margin then
                toFloat model.appWidth - margin - vx

            else
                0

        dy =
            if vy + h < margin then
                margin - (vy + h)

            else if vy > toFloat model.appHeight - margin then
                toFloat model.appHeight - margin - vy

            else
                0
    in
    { model
        | canvasOffset =
            { x = model.canvasOffset.x + round dx
            , y = model.canvasOffset.y + round dy
            }
    }


{-| Insert (or update) a plan window, activate it, assign a default
window position if it is new, and raise it to the top.
-}
addPlanWindow : String -> PlanWindow -> Model -> Model
addPlanWindow key win model =
    let
        positions1 =
            if hasWin model key then
                model.windowPositions

            else
                Dict.insert key
                    (case originLiveId model key of
                        -- Rule 1: below the owning session (cascading).
                        Just liveOrigin ->
                            planPositionBelowSession model liveOrigin

                        -- Manager open / no live source: center on viewport.
                        Nothing ->
                            centeredPlanPos model
                    )
                    model.windowPositions

        m0 =
            { model
                | planWindows = Dict.insert key win model.planWindows
                , planOrder =
                    if List.member key model.planOrder then
                        model.planOrder

                    else
                        model.planOrder ++ [ key ]
                , planActiveId = Just key
                , windowPositions = positions1
                -- The new plan window is active: connect it to its owning
                -- session (drawn by transport.js via the setConnectionChain
                -- port — PlanSaveReady emits the matching Cmd). For a
                -- sub-plan the chain continues up to the top-level
                -- session, so the whole ancestor path is visible.
                , connectionChain = connectionChainForPlan model key
            }

        -- Raise (D6): move the window to the end of planOrder and give
        -- it the next bounded z (raiseWindow also rebases when the z
        -- counter crosses the threshold).
        m1 =
            raiseWindow m0 key

        -- SD3: opening a plan from the solo session (or a sub-plan of the
        -- solo plan) moves the solo view onto it; a plan belonging to some
        -- other session never steals it.
        m2 =
            if soloFollowsPlan model key then
                enterSolo key m1

            else
                m1
    in
    case layoutRect m2 key of
        Just p ->
            -- bringIntoView pans the canvas, which is canvas state — so it
            -- only makes sense in canvas view. In solo the new window is by
            -- definition the whole viewport, and panning behind the user's
            -- back would move the layout they will return to (SD4).
            if isSolo m2 then
                m2

            else
                bringIntoView m2 p

        Nothing ->
            m2


{-| Apply an in-flight RESIZE drag (D4): reads the origin + handle from
the unified DragState and recomputes the window rect from the current
pointer position. Returns Cmd.none; the caller re-emits the chain.
-}
handleResizeMove : Model -> Float -> Float -> DragState -> ( Model, Cmd Msg )
handleResizeMove model mouseX mouseY d =
    case d.kind of
        WindowResize key handle ->
            resizeMove model key handle mouseX mouseY d

        PlanResize key handle ->
            resizeMove model key handle mouseX mouseY d

        _ ->
            ( model, Cmd.none )


resizeMove : Model -> String -> ResizeHandle -> Float -> Float -> DragState -> ( Model, Cmd Msg )
resizeMove model key handle mouseX mouseY d =
    let
        -- Mouse deltas are screen pixels; window coords are canvas
        -- pixels (the canvas layer is scaled by canvasScale), so divide
        -- to keep the resize edge under the cursor at any zoom level.
        dx =
            round ((mouseX - d.startMouseX) / model.canvasScale)

        dy =
            round ((mouseY - d.startMouseY) / model.canvasScale)

        config =
            { handle = handle
            , dx = dx
            , dy = dy
            , startX = d.startWinX
            , startY = d.startWinY
            , startW = d.startWinW
            , startH = d.startWinH
            , minW = minWinW
            , minH = minWinH
            }

        r =
            resizeDimensions config

        -- No viewport clamp on resize either: the canvas is unbounded,
        -- only the minimum size is enforced (inside resizeDimensions).
        -- Positions move freely off-screen.
    in
    ( { model
        | windowPositions =
            Dict.update key
                (Maybe.map (\pos -> { pos | x = r.x, y = r.y, w = r.w, h = r.h }))
                model.windowPositions
      }
    , Cmd.none
    )


-- Apply a buffered transport event to the sessions dict.
-- Returns the updated sessions dict unchanged if the event can't be decoded or session not found.
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


