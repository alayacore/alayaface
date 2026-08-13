module PointerTest exposing (tests)

{-| Unit tests for App/Pointer — the pure input side of the touch &
pointer design: pointer event decoding, target classification and the
gesture math (slop, distance, midpoint, pinch ratio).
-}

import Expect
import Json.Decode as D
import Test exposing (Test, describe, test)
import App.Pointer as P


pev : Int -> String -> Int -> Float -> Float -> String -> String -> String -> String -> String
pev id ptype button x y target sessionId planId handle =
    "{\"pointerId\":" ++ String.fromInt id
        ++ ",\"pointerType\":\"" ++ ptype
        ++ "\",\"button\":" ++ String.fromInt button
        ++ ",\"clientX\":" ++ String.fromFloat x
        ++ ",\"clientY\":" ++ String.fromFloat y
        ++ ",\"targetKind\":\"" ++ target
        ++ "\",\"sessionId\":\"" ++ sessionId
        ++ "\",\"planId\":\"" ++ planId
        ++ "\",\"handle\":\"" ++ handle
        ++ "\"}"


tests : Test
tests =
    describe "App/Pointer"
        [ describe "pointerEventDecoder"
            [ test "decodes a full touch payload" <|
                \_ ->
                    pev 7 "touch" 0 120.5 80.25 "canvas" "" "" ""
                        |> D.decodeString P.pointerEventDecoder
                        |> Expect.equal
                            (Ok
                                { id = 7
                                , kind = P.TouchPointer
                                , button = 0
                                , x = 120.5
                                , y = 80.25
                                , target = P.TCanvas
                                , sessionId = ""
                                , planId = ""
                                , handle = ""
                                }
                            )
            , test "decodes a bar drag with ids and a handle" <|
                \_ ->
                    pev 2 "mouse" 0 10 20 "session-handle" "s1" "" "se"
                        |> D.decodeString P.pointerEventDecoder
                        |> Expect.equal
                            (Ok
                                { id = 2
                                , kind = P.MousePointer
                                , button = 0
                                , x = 10
                                , y = 20
                                , target = P.TSessionHandle
                                , sessionId = "s1"
                                , planId = ""
                                , handle = "se"
                                }
                            )
            , test "unknown targetKind / pointerType fall back safely" <|
                \_ ->
                    pev 1 "trackpad" 2 0 0 "warp-drive" "s1" "p1" ""
                        |> D.decodeString P.pointerEventDecoder
                        |> Result.map (\pi -> ( pi.kind, pi.target ))
                        |> Expect.equal (Ok ( P.MousePointer, P.TOther ))
            , test "rejects a malformed payload" <|
                \_ ->
                    "{}"
                        |> D.decodeString P.pointerEventDecoder
                        |> Expect.err
            ]
        , describe "target classification"
            [ test "draggable surfaces are the five gesture kinds" <|
                \_ ->
                    [ P.TCanvas, P.TSessionBar, P.TPlanBar, P.TSessionHandle, P.TPlanHandle ]
                        |> List.map P.isDraggableTarget
                        |> Expect.equal [ True, True, True, True, True ]
            , test "content / menu / overlay / other never drag" <|
                \_ ->
                    [ P.TContent, P.TMenu, P.TOverlay, P.TOther ]
                        |> List.map P.isDraggableTarget
                        |> Expect.equal [ False, False, False, False ]
            ]
        , describe "gesture math"
            [ test "distance is euclidean" <|
                \_ ->
                    Expect.equal (P.distance ( 0, 0 ) ( 3, 4 )) 5
            , test "midpoint averages both axes" <|
                \_ ->
                    Expect.equal (P.midpoint ( 10, 20 ) ( 30, 40 )) ( 20, 30 )
            , test "pinch ratio is current/start" <|
                \_ ->
                    P.pinchRatio 100 250
                        |> Expect.within (Expect.Absolute 0.0001) 2.5
            , test "pinch ratio guards a zero start distance" <|
                \_ ->
                    Expect.equal (P.pinchRatio 0 999) 1
            , test "slop separates taps from drags (4px)" <|
                \_ ->
                    Expect.equal P.slop 4
            ]
        ]
