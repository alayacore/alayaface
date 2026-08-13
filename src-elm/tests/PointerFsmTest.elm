module PointerFsmTest exposing (tests)

{-| Gesture FSM tests (touch & pointer design D5): the Pointer*
messages driven through App/Update — arming, slop activation, pan /
window drag / resize, pinch zoom, long-press menu, and the cancel /
multi-finger edge cases. Covers the same ground the old mouse-only
drag handlers did, plus the new touch gestures.
-}

import Dict
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import App.Update as AU
import App.Types as AT
import App.Pointer as P
import TestHelpers exposing (initModelWithSession)


pev : Int -> String -> Int -> Float -> Float -> String -> String -> String -> String -> E.Value
pev id ptype button x y target sessionId planId handle =
    E.object
        [ ( "pointerId", E.int id )
        , ( "pointerType", E.string ptype )
        , ( "button", E.int button )
        , ( "clientX", E.float x )
        , ( "clientY", E.float y )
        , ( "targetKind", E.string target )
        , ( "sessionId", E.string sessionId )
        , ( "planId", E.string planId )
        , ( "handle", E.string handle )
        ]


down : E.Value -> AT.Model -> AT.Model
down raw =
    AU.update (AT.PointerDown raw) >> Tuple.first


move : E.Value -> AT.Model -> AT.Model
move raw =
    AU.update (AT.PointerMove raw) >> Tuple.first


up : E.Value -> AT.Model -> AT.Model
up raw =
    AU.update (AT.PointerUp raw) >> Tuple.first


cancel : E.Value -> AT.Model -> AT.Model
cancel raw =
    AU.update (AT.PointerCancel raw) >> Tuple.first


longPressFired : AT.Model -> AT.Model
longPressFired =
    AU.update AT.LongPressFired >> Tuple.first


withSessionWindow : AT.Model
withSessionWindow =
    { initModelWithSession
        | windowPositions = Dict.insert "s1" { x = 100, y = 50, w = 560, h = 640, z = 1 } Dict.empty
        , nextZIndex = 2
    }


tests : Test
tests =
    describe "pointer gesture FSM (App/Update)"
        [ describe "canvas pan"
            [ test "touch pointerdown arms a pan drag + the menu long-press" <|
                \_ ->
                    let
                        m1 =
                            down (pev 1 "touch" 0 100 100 "canvas" "" "" "") initModelWithSession
                    in
                    Expect.all
                        [ \m -> Expect.equal (m.drag |> Maybe.map .kind) (Just AT.Pan)
                        , \m -> Expect.equal (m.drag |> Maybe.map .active) (Just False)
                        , \m -> Expect.equal (m.longPress |> Maybe.map .pointerId) (Just 1)
                        , \m -> Expect.equal (m.activePointers |> Dict.size) 1
                        ]
                        m1
            , test "a tap (down + up) never pans and clears the arm" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            up (pev 1 "touch" 0 100 100 "canvas" "" "" "") m0
                    in
                    Expect.all
                        [ \m -> Expect.equal m.canvasOffset { x = 0, y = 0 }
                        , \m -> Expect.equal m.drag Nothing
                        , \m -> Expect.equal (m.activePointers |> Dict.size) 0
                        , \m -> Expect.equal m.longPress Nothing
                        ]
                        m1
            , test "moving past the slop pans by the full delta" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "mouse" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            move (pev 1 "mouse" 0 120 110 "canvas" "" "" "") m0
                    in
                    Expect.all
                        [ \m -> Expect.equal m.canvasOffset { x = 20, y = 10 }
                        , \m -> Expect.equal (m.drag |> Maybe.map .active) (Just True)
                        ]
                        m1
            , test "movement within the slop does not pan" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "mouse" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            move (pev 1 "mouse" 0 102 101 "canvas" "" "" "") m0
                    in
                    Expect.equal m1.canvasOffset { x = 0, y = 0 }
            , test "right button (context menu) never arms a drag" <|
                \_ ->
                    let
                        m1 =
                            down (pev 1 "mouse" 2 100 100 "canvas" "" "" "") initModelWithSession
                    in
                    Expect.equal m1.drag Nothing
            , test "pointercancel clears the pan arm and pointers" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            cancel (pev 1 "touch" 0 120 130 "canvas" "" "" "") m0
                    in
                    Expect.all
                        [ \m -> Expect.equal m.drag Nothing
                        , \m -> Expect.equal (m.activePointers |> Dict.size) 0
                        , \m -> Expect.equal m.longPress Nothing
                        ]
                        m1
            ]
        , describe "window drag (session bar)"
            [ test "a bar tap raises + focuses without moving the window" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 10 5 "session-bar" "s1" "" "") withSessionWindow

                        m1 =
                            up (pev 1 "touch" 0 10 5 "session-bar" "s1" "" "") m0
                    in
                    Expect.all
                        [ \m -> Expect.equal m.drag Nothing
                        , \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map .x) (Just 100)
                        , \m -> Expect.equal m.activeId (Just "s1")
                        , \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map .z) (Just 2)
                        , \m -> Expect.equal m.nextZIndex 3
                        ]
                        m1
            , test "dragging the bar past the slop moves + raises the window" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 10 5 "session-bar" "s1" "" "") withSessionWindow

                        m1 =
                            move (pev 1 "touch" 0 60 35 "session-bar" "s1" "" "") m0
                    in
                    Expect.all
                        [ \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map (\p -> ( p.x, p.y ))) (Just ( 150, 80 ))
                        , \m -> Expect.equal (m.drag |> Maybe.map .kind) (Just (AT.WindowMove "s1"))
                        , \m -> Expect.equal m.activeId (Just "s1")
                        , \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map .z) (Just 2)
                        ]
                        m1
            , test "a second finger during an ACTIVE window drag is ignored" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 10 5 "session-bar" "s1" "" "") withSessionWindow

                        m1 =
                            move (pev 1 "touch" 0 60 35 "session-bar" "s1" "" "") m0

                        m2 =
                            down (pev 2 "touch" 0 500 400 "canvas" "" "" "") m1
                    in
                    Expect.all
                        [ \m -> Expect.equal (m.drag |> Maybe.map .kind) (Just (AT.WindowMove "s1"))
                        , \m -> Expect.equal (m.drag |> Maybe.map .active) (Just True)
                        , \m -> Expect.equal (m.pinch) Nothing
                        ]
                        m2
            ]
        , describe "plan window drag"
            [ test "plan bar drag moves the plan window and sets planActiveId" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | windowPositions = Dict.insert "p1" { x = 100, y = 50, w = 560, h = 640, z = 1 } Dict.empty
                                , nextZIndex = 2
                            }

                        m1 =
                            down (pev 1 "mouse" 0 10 5 "plan-bar" "" "p1" "") m0

                        m2 =
                            move (pev 1 "mouse" 0 40 25 "plan-bar" "" "p1" "") m1
                    in
                    Expect.all
                        [ \m -> Expect.equal (Dict.get "p1" m.windowPositions |> Maybe.map (\p -> ( p.x, p.y ))) (Just ( 130, 70 ))
                        , \m -> Expect.equal (m.drag |> Maybe.map .kind) (Just (AT.PlanMove "p1"))
                        , \m -> Expect.equal m.planActiveId (Just "p1")
                        ]
                        m2
            ]
        , describe "resize"
            [ test "east handle drag grows the width (scale-divided deltas)" <|
                \_ ->
                    let
                        m0 =
                            { withSessionWindow | canvasScale = 2.0 }

                        m1 =
                            down (pev 1 "mouse" 0 0 0 "session-handle" "s1" "" "e") m0

                        m2 =
                            move (pev 1 "mouse" 0 40 0 "session-handle" "s1" "" "e") m1
                    in
                    -- dx = 40 / 2 = 20 canvas px → w 560 + 20
                    Expect.all
                        [ \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map .w) (Just 580)
                        , \m -> Expect.equal (m.drag |> Maybe.map .kind) (Just (AT.WindowResize "s1" AT.E))
                        ]
                        m2
            , test "unknown handle never arms" <|
                \_ ->
                    let
                        m1 =
                            down (pev 1 "mouse" 0 0 0 "session-handle" "s1" "" "x") withSessionWindow
                    in
                    Expect.equal m1.drag Nothing
            ]
        , describe "pinch zoom"
            [ test "two canvas fingers start a pinch and clear the pan arm" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            down (pev 2 "touch" 0 200 100 "canvas" "" "" "") m0
                    in
                    Expect.all
                        [ \m -> Expect.equal m.drag Nothing
                        , \m -> Expect.equal (m.pinch |> Maybe.map .startDist) (Just 100)
                        , \m -> Expect.equal m.longPress Nothing
                        ]
                        m1
            , test "spreading the fingers zooms by the distance ratio" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            down (pev 2 "touch" 0 200 100 "canvas" "" "" "") m0

                        -- distance 100 → 200 = ratio 2 → scale 1.0 → 2.0
                        m2 =
                            move (pev 2 "touch" 0 300 100 "canvas" "" "" "") m1
                    in
                    Expect.equal m2.canvasScale 2.0
            , test "lifting one finger ends the pinch without jumping into a drag" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 100 100 "canvas" "" "" "") initModelWithSession

                        m1 =
                            down (pev 2 "touch" 0 200 100 "canvas" "" "" "") m0

                        m2 =
                            up (pev 1 "touch" 0 100 100 "canvas" "" "" "") m1
                    in
                    Expect.all
                        [ \m -> Expect.equal m.pinch Nothing
                        , \m -> Expect.equal m.drag Nothing
                        ]
                        m2
            ]
        , describe "long-press menu (touch right-click)"
            [ test "a still 500ms hold opens the global menu at the finger" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 50 60 "canvas" "" "" "") initModelWithSession

                        m1 =
                            longPressFired m0
                    in
                    Expect.all
                        [ \m -> Expect.equal m.showGlobalMenu True
                        , \m -> Expect.equal ( m.globalMenuX, m.globalMenuY ) ( 50, 60 )
                        , \m -> Expect.equal m.longPress Nothing
                        , \m -> Expect.equal m.drag Nothing
                        ]
                        m1
            , test "movement past the slop cancels the long-press" <|
                \_ ->
                    let
                        m0 =
                            down (pev 1 "touch" 0 50 60 "canvas" "" "" "") initModelWithSession

                        m1 =
                            move (pev 1 "touch" 0 60 70 "canvas" "" "" "") m0

                        m2 =
                            longPressFired m1
                    in
                    Expect.all
                        [ \m -> Expect.equal m.longPress Nothing
                        , \m -> Expect.equal m.showGlobalMenu False
                        ]
                        m2
            , test "a mouse press never arms the long-press" <|
                \_ ->
                    let
                        m1 =
                            down (pev 1 "mouse" 0 50 60 "canvas" "" "" "") initModelWithSession
                    in
                    Expect.equal m1.longPress Nothing
            ]
        , describe "App/Pointer helpers"
            [ test "toDragKind maps targets + ids to drag kinds" <|
                \_ ->
                    Expect.all
                        [ \_ -> Expect.equal (AT.toDragKind P.TCanvas "" "" "") (Just AT.Pan)
                        , \_ -> Expect.equal (AT.toDragKind P.TSessionBar "s1" "" "") (Just (AT.WindowMove "s1"))
                        , \_ -> Expect.equal (AT.toDragKind P.TPlanBar "" "p1" "") (Just (AT.PlanMove "p1"))
                        , \_ -> Expect.equal (AT.toDragKind P.TSessionHandle "s1" "" "nw") (Just (AT.WindowResize "s1" AT.NW))
                        , \_ -> Expect.equal (AT.toDragKind P.TPlanHandle "" "p1" "s") (Just (AT.PlanResize "p1" AT.S))
                        , \_ -> Expect.equal (AT.toDragKind P.TContent "" "" "") Nothing
                        ]
                        ()
            ]
        ]
