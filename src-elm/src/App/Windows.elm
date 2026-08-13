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
bridge.js hides their segments anyway.
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
    if Dict.member key model.windowPositions then
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
-}
chainPayload : Model -> List NC.ChainSegment -> { segments : List NC.ChainSegment, positions : List { id : String, x : Int, y : Int, w : Int, h : Int, z : Int }, canvasScale : Float }
chainPayload model segments =
    { segments = segments
    , positions =
        Dict.toList model.windowPositions
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
top-level session) and tell bridge.js to draw every segment — a deep
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
    case Dict.get liveOriginId model.windowPositions of
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
    case Dict.get planId model.windowPositions of
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
            if Dict.member key model.windowPositions then
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
                -- session (drawn by bridge.js via the setConnectionChain
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
    in
    case Dict.get key positions1 of
        Just p ->
            bringIntoView m1 p

        Nothing ->
            m1


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


