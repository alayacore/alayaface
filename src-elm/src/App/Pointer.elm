module App.Pointer exposing
    ( PointerKind(..)
    , TargetKind(..)
    , PointerInfo
    , pointerEventDecoder
    , isDraggableTarget
    , slop
    , longPressMs
    , distance
    , midpoint
    , pinchRatio
    , targetFromString
    )

{-| Unified pointer input (mouse / touch / pen) — the input side of the
touch & pointer design (D1/D2/D5). Pure module: decodes the raw pointer
events forwarded by transport.js (a dumb pipe that only classifies,
captures and forwards) and provides the gesture math the App/Update FSM
uses. No DOM access, no ports — unit-testable with elm-test.

JS payload (transport.js pointer pipe):

    { pointerId : Int
    , pointerType : "mouse" | "touch" | "pen"
    , button : Int          -- 0 left / 1 middle / 2 right (pointerdown)
    , clientX : Float
    , clientY : Float
    , targetKind : String   -- see TargetKind
    , sessionId : String    -- "" when none (session bars/handles)
    , planId : String       -- "" when none (plan bars/handles)
    , handle : String       -- "nw"|"n"|"ne"|"w"|"e"|"sw"|"s"|"se", else ""
    }

-}

import Json.Decode as D exposing (Decoder)


type PointerKind
    = MousePointer
    | TouchPointer
    | PenPointer


{-| What the pointer went down on (classified by transport.js via
closest()): the canvas background, a window title bar, a resize handle,
window content, the global menu, an overlay, or something else. Only the
draggable kinds (canvas/bar/handle) can start a drag or pinch.
-}
type TargetKind
    = TCanvas
    | TSessionBar
    | TPlanBar
    | TSessionHandle
    | TPlanHandle
    | TContent
    | TMenu
    | TOverlay
    | TOther


type alias PointerInfo =
    { id : Int
    , kind : PointerKind
    , button : Int
    , x : Float
    , y : Float
    , target : TargetKind
    , sessionId : String
    , planId : String
    , handle : String
    }


{-| Movement threshold (px) separating a tap from a drag: an armed
pointer must travel past this before the drag activates, so a tap on a
window bar activates the window without moving it, and a tap on the
canvas never pans.
-}
slop : Float
slop =
    4


{-| Touch long-press duration (ms) that opens the global menu — the
touch equivalent of a right-click. Mouse keeps the contextmenu event.
-}
longPressMs : Int
longPressMs =
    500


pointerEventDecoder : Decoder PointerInfo
pointerEventDecoder =
    D.succeed PointerInfo
        |> andMap (D.field "pointerId" D.int)
        |> andMap (D.field "pointerType" D.string |> D.map pointerKindFromString)
        |> andMap (D.field "button" D.int)
        |> andMap (D.field "clientX" D.float)
        |> andMap (D.field "clientY" D.float)
        |> andMap (D.field "targetKind" D.string |> D.map targetFromString)
        |> andMap (D.field "sessionId" D.string)
        |> andMap (D.field "planId" D.string)
        |> andMap (D.field "handle" D.string)


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    D.map2 (|>)


pointerKindFromString : String -> PointerKind
pointerKindFromString s =
    case s of
        "touch" ->
            TouchPointer

        "pen" ->
            PenPointer

        _ ->
            MousePointer


targetFromString : String -> TargetKind
targetFromString s =
    case s of
        "canvas" ->
            TCanvas

        "session-bar" ->
            TSessionBar

        "plan-bar" ->
            TPlanBar

        "session-handle" ->
            TSessionHandle

        "plan-handle" ->
            TPlanHandle

        "content" ->
            TContent

        "menu" ->
            TMenu

        "overlay" ->
            TOverlay

        _ ->
            TOther


{-| Surfaces that can start a drag (canvas pan / window move / resize).
-}
isDraggableTarget : TargetKind -> Bool
isDraggableTarget t =
    case t of
        TCanvas ->
            True

        TSessionBar ->
            True

        TPlanBar ->
            True

        TSessionHandle ->
            True

        TPlanHandle ->
            True

        _ ->
            False


distance : ( Float, Float ) -> ( Float, Float ) -> Float
distance ( ax, ay ) ( bx, by ) =
    sqrt ((bx - ax) * (bx - ax) + (by - ay) * (by - ay))


midpoint : ( Float, Float ) -> ( Float, Float ) -> ( Float, Float )
midpoint ( ax, ay ) ( bx, by ) =
    ( (ax + bx) / 2, (ay + by) / 2 )


{-| Current/start distance ratio for pinch zoom. A degenerate (zero)
start distance can never produce a crazy factor.
-}
pinchRatio : Float -> Float -> Float
pinchRatio startDist curDist =
    if startDist <= 0 then
        1

    else
        curDist / startDist
