module AppWindowsTest exposing (suite)

{-| Direct unit tests for App/Windows (M2): window/canvas/zoom/z-index
management extracted from App/Update.elm — placement rules, canvas pan
& zoom clamping, plan window accessors, resize math and chain
z-ordering. Pure functions, no transports.
-}

import Expect
import Test exposing (Test, describe, test)
import Dict
import App.Types as AT
import App.Windows as W
import App.Update as AU
import App.NodeConnection as NC
import Session.Types as T
import TestHelpers exposing (initModelWithSession)


suite : Test
suite =
    describe "App/Windows (direct)"
        [ describe "applyZoom"
            [ test "clamps to the canvas scale bounds" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession | canvasScale = 1.0 }

                        m1 =
                            W.applyZoom 0.01 0 0 m0

                        m2 =
                            W.applyZoom 100 0 0 m0
                    in
                    Expect.equal ( m1.canvasScale, m2.canvasScale ) ( 0.2, 4.0 )
            , test "keeps the cursor anchor fixed when zooming" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | canvasScale = 1.0
                                , canvasOffset = { x = 100, y = 50 }
                            }

                        m1 =
                            W.applyZoom 2.0 200 100 m0
                    in
                    -- canvas point at screen (200,100): canvas x = (200-100)/1 = 100;
                    -- after 2x zoom the offset must be 200 - 100*2 = 0 to keep it there
                    Expect.equal ( m1.canvasScale, m1.canvasOffset ) ( 2.0, { x = 0, y = 0 } )
            ]
        , describe "bringIntoView"
            [ test "pans a window that is off the right edge into view" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | appWidth = 1000
                                , canvasOffset = { x = 0, y = 0 }
                                , canvasScale = 1.0
                            }

                        pos =
                            { x = 2000, y = 0, w = 400, h = 300, z = 5 }

                        m1 =
                            W.bringIntoView m0 pos
                    in
                    -- 2000 > 1000 - 24 → pan left so the right edge sits at margin
                    Expect.equal m1.canvasOffset.x (1000 - 24 - 2000)
            ]
        , describe "placement"
            [ test "centeredSessionPos centers on the viewport" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | appWidth = 1400
                                , appHeight = 900
                                , canvasOffset = { x = 0, y = 0 }
                                , canvasScale = 1.0
                                , nextZIndex = 7
                            }

                        pos =
                            W.centeredSessionPos m0
                    in
                    Expect.all
                        [ \p -> Expect.equal p.x 470
                        , \p -> Expect.equal p.y 170
                        , \p -> Expect.equal p.w 560
                        , \p -> Expect.equal p.h 640
                        , \p -> Expect.equal p.z 7
                        ]
                        pos
            , test "planPositionBelowSession cascades under the owning session" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | windowPositions =
                                    Dict.insert "s1" { x = 100, y = 200, w = 560, h = 640, z = 1 } Dict.empty
                                , planWindows =
                                    Dict.fromList
                                        [ ( "p1", AT.emptyPlanWindow )
                                        , ( "p2", AT.emptyPlanWindow )
                                        ]
                                , planMetas =
                                    Dict.fromList
                                        [ ( "p1", { origin = { sessionId = "s1", planIndex = 0 }, feedbacks = [], depth = 1, createdAt = 0, name = "p1", lastStatus = "", parentPlanId = Nothing } )
                                        , ( "p2", { origin = { sessionId = "s1", planIndex = 1 }, feedbacks = [], depth = 1, createdAt = 0, name = "p2", lastStatus = "", parentPlanId = Nothing } )
                                        ]
                            }

                        pos =
                            W.planPositionBelowSession m0 "s1"
                    in
                    -- cascade count = 2 open plans for s1 → y = 200+640+24+2*36
                    Expect.equal ( pos.x, pos.y ) ( 100, 200 + 640 + 24 + 2 * 36 )
            ]
        , describe "plan window accessors"
            [ test "getPlanWin / setPlanWin / updateActivePlanWin" <|
                \_ ->
                    let
                        base =
                            AT.emptyPlanWindow

                        v0 =
                            AT.emptyPlanView

                        w0 =
                            { base | view = { v0 | errors = [ "a" ] } }

                        m0 =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , planWindows = Dict.insert "p1" w0 Dict.empty
                            }

                        got =
                            W.getPlanWin m0

                        m1 =
                            W.setPlanWin "p1" (\w -> { w | runPath = Just "/x" }) m0

                        m2 =
                            W.updateActivePlanWin m0 (\w -> { w | selectedNode = Just "t1" })
                    in
                    Expect.equal
                        ( got |> Maybe.map .view |> Maybe.map .errors
                        , Dict.get "p1" m1.planWindows |> Maybe.andThen .runPath
                        , Dict.get "p1" m2.planWindows |> Maybe.andThen .selectedNode
                        )
                        ( Just [ "a" ], Just "/x", Just "t1" )
            ]
        , describe "handleResizeMove"
            [ test "east handle grows the width (canvas-scaled deltas)" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | canvasScale = 2.0
                                , resizeInfo =
                                    Just
                                        { sessionId = "s1"
                                        , handle = AT.E
                                        , startMouseX = 0
                                        , startMouseY = 0
                                        , startWinX = 100
                                        , startWinY = 50
                                        , startWinW = 560
                                        , startWinH = 640
                                        }
                                , windowPositions = Dict.insert "s1" { x = 100, y = 50, w = 560, h = 640, z = 1 } Dict.empty
                            }

                        ( m1, _ ) =
                            W.handleResizeMove m0 40 0
                    in
                    -- dx = 40/2 = 20 canvas px → w = 560+20 = 580
                    case Dict.get "s1" m1.windowPositions of
                        Just p ->
                            Expect.equal ( p.w, p.h, p.x ) ( 580, 640, 100 )

                        Nothing ->
                            Expect.fail "window missing"
            , test "west handle moves x and shrinks width" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | canvasScale = 1.0
                                , resizeInfo =
                                    Just
                                        { sessionId = "s1"
                                        , handle = AT.W
                                        , startMouseX = 0
                                        , startMouseY = 0
                                        , startWinX = 100
                                        , startWinY = 50
                                        , startWinW = 560
                                        , startWinH = 640
                                        }
                                , windowPositions = Dict.insert "s1" { x = 100, y = 50, w = 560, h = 640, z = 1 } Dict.empty
                            }

                        ( m1, _ ) =
                            W.handleResizeMove m0 -40 0
                    in
                    case Dict.get "s1" m1.windowPositions of
                        Just p ->
                            Expect.equal ( p.x, p.w ) ( 60, 600 )

                        Nothing ->
                            Expect.fail "window missing"
            ]
        , describe "addPlanWindow"
            [ test "inserts, activates, assigns a position and raises z" <|
                \_ ->
                    let
                        m0 =
                            initModelWithSession

                        m1 =
                            W.addPlanWindow "p1" AT.emptyPlanWindow m0
                    in
                    Expect.all
                        [ \m -> Expect.equal (Dict.member "p1" m.planWindows) True
                        , \m -> Expect.equal m.planActiveId (Just "p1")
                        , \m -> Expect.equal m.nextZIndex 2
                        , \m -> Expect.equal m.planOrder [ "p1" ]
                        , \m -> Expect.equal (Dict.get "p1" m.windowPositions |> Maybe.map .z) (Just 1)
                        ]
                        m1
            ]
        , describe "raiseWindow (P39/D6 bounded z)"
            [ test "moves a session to the end of sessionOrder and bumps z" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | sessionOrder = [ "s1", "s2" ]
                                , windowPositions =
                                    Dict.insert "s1" { x = 0, y = 0, w = 560, h = 640, z = 1 } Dict.empty
                            }

                        m1 =
                            W.raiseWindow m0 "s1"
                    in
                    Expect.all
                        [ \m -> Expect.equal m.sessionOrder [ "s2", "s1" ]
                        , \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map .z) (Just 1)
                        , \m -> Expect.equal m.nextZIndex 2
                        ]
                        m1
            , test "moves a plan to the end of planOrder and bumps z" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planWindows = Dict.insert "p1" AT.emptyPlanWindow Dict.empty
                                , planOrder = [ "p1" ]
                                , windowPositions =
                                    Dict.insert "p1" { x = 0, y = 0, w = 680, h = 720, z = 1 } Dict.empty
                            }

                        m1 =
                            W.raiseWindow m0 "p1"
                    in
                    Expect.all
                        [ \m -> Expect.equal m.planOrder [ "p1" ]
                        , \m -> Expect.equal (Dict.get "p1" m.windowPositions |> Maybe.map .z) (Just 1)
                        , \m -> Expect.equal m.nextZIndex 2
                        ]
                        m1
            , test "unknown window key is a no-op" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession | nextZIndex = 7 }

                        m1 =
                            W.raiseWindow m0 "ghost"
                    in
                    Expect.equal ( m1.nextZIndex, m1.sessionOrder ) ( 7, [ "s1" ] )
            , test "rebases z when nextZIndex crosses the threshold" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | nextZIndex = 500
                                , windowPositions =
                                    Dict.fromList
                                        [ ( "s1", { x = 0, y = 0, w = 560, h = 640, z = 499 } )
                                        , ( "s2", { x = 0, y = 0, w = 560, h = 640, z = 1 } )
                                        ]
                            }

                        m1 =
                            W.raiseWindow m0 "s1"
                    in
                    -- raise → s1 z=500, nextZ=501 > 500 → drop = 501-100-1 = 400
                    -- s1 → 100 (floor), s2 → -399 (negative inside the canvas
                    -- stacking context is harmless), nextZIndex → 101.
                    Expect.all
                        [ \m -> Expect.equal m.nextZIndex 101
                        , \m -> Expect.equal (Dict.get "s1" m.windowPositions |> Maybe.map .z) (Just 100)
                        , \m -> Expect.equal (Dict.get "s2" m.windowPositions |> Maybe.map .z) (Just -399)
                        ]
                        m1
            , test "raiseChainWindows rebases when nextZIndex crosses the threshold" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | nextZIndex = 500
                                , windowPositions =
                                    Dict.fromList
                                        [ ( "s1", { x = 0, y = 0, w = 560, h = 640, z = 1 } )
                                        , ( "p1", { x = 0, y = 0, w = 680, h = 720, z = 1 } )
                                        ]
                            }

                        segments =
                            [ { kind = "node", sessionId = "s1", planId = "p1", nodeId = Just "t1" } ]

                        ( positions, next ) =
                            W.raiseChainWindows m0 segments
                    in
                    -- z starts at 500+2-1 = 501 → nextZ 502 > 500 → drop =
                    -- 502-100-1 = 401: s1 → 100 (floor), p1 → 99, next → 101.
                    Expect.all
                        [ \_ -> Expect.equal (Dict.get "s1" positions |> Maybe.map .z) (Just 100)
                        , \_ -> Expect.equal (Dict.get "p1" positions |> Maybe.map .z) (Just 99)
                        , \_ -> Expect.equal next 101
                        ]
                        positions
            ]
        , describe "chainPayload (P39/Phase A)"
            [ test "carries positions and canvas scale" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | windowPositions =
                                    Dict.insert "s1" { x = 10, y = 20, w = 560, h = 640, z = 3 } Dict.empty
                                , canvasScale = 1.5
                            }

                        payload =
                            W.chainPayload m0 []
                    in
                    Expect.all
                        [ \p -> Expect.equal p.positions [ { id = "s1", x = 10, y = 20, w = 560, h = 640, z = 3 } ]
                        , \p -> Expect.within (Expect.Absolute 0.0001) p.canvasScale 1.5
                        ]
                        payload
            ]
        , describe "chain z-ordering"
            [ test "raiseChainWindows assigns increasing z to chain windows" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | nextZIndex = 10
                                , windowPositions =
                                    Dict.fromList
                                        [ ( "s1", { x = 0, y = 0, w = 560, h = 640, z = 1 } )
                                        , ( "p1", { x = 0, y = 0, w = 680, h = 720, z = 1 } )
                                        ]
                            }

                        segments =
                            [ { kind = "node", sessionId = "s1", planId = "p1", nodeId = Just "t1" } ]

                        ( positions, next ) =
                            W.raiseChainWindows m0 segments
                    in
                    -- windows = [s1, p1]; z starts at 10+2-1 = 11: s1→11, p1→10
                    Expect.all
                        [ \_ -> Expect.equal (Dict.get "s1" positions |> Maybe.map .z) (Just 11)
                        , \_ -> Expect.equal (Dict.get "p1" positions |> Maybe.map .z) (Just 10)
                        , \_ -> Expect.equal next 12
                        ]
                        positions
            ]
        , describe "connectionChainForPlan"
            [ test "builds a plan segment for an origin-bound top-level plan" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planMetas =
                                    Dict.fromList
                                        [ ( "p1", { origin = { sessionId = "s1", planIndex = 0 }, feedbacks = [], depth = 1, createdAt = 0, name = "p1", lastStatus = "", parentPlanId = Nothing } )
                                        ]
                            }

                        chain =
                            W.connectionChainForPlan m0 "p1"
                    in
                    Expect.equal
                        ( List.map .kind chain, List.map .planId chain, List.map .sessionId chain )
                        ( [ "plan" ], [ "p1" ], [ "s1" ] )
            , test "C2b-7: the plan segment resolves to the plan origin (Session.id stable, no lineage)" <|
                \_ ->
                    -- 无血缘：plan 的属主会话 = origin（稳定 Session.id），
                    -- 即使工作副本已换（fork 目录 fork-1 在 sessions 里），
                    -- 连接段仍指向 Session.id（s1）。
                    let
                        forkSess =
                            T.emptySession "fork-1"

                        m0 =
                            { initModelWithSession
                                | sessions = Dict.insert "fork-1" forkSess initModelWithSession.sessions
                                , planMetas =
                                    Dict.fromList
                                        [ ( "p1", { origin = { sessionId = "s1", planIndex = 0 }, feedbacks = [], depth = 1, createdAt = 0, name = "p1", lastStatus = "", parentPlanId = Nothing } )
                                        ]
                            }

                        chain =
                            W.connectionChainForPlan m0 "p1"
                    in
                    Expect.equal
                        ( List.map .kind chain, List.map .planId chain, List.map .sessionId chain )
                        ( [ "plan" ], [ "p1" ], [ "s1" ] )
            ]
        , describe "planFocusAboveSession (Ctrl+W close target)"
            [ test "plan window on top → close the plan, not the session below" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , activeId = Just "s1"
                                , windowPositions =
                                    Dict.fromList
                                        [ ( "p1", { x = 0, y = 0, w = 100, h = 100, z = 10 } )
                                        , ( "s1", { x = 0, y = 0, w = 100, h = 100, z = 9 } )
                                        ]
                            }
                    in
                    Expect.equal (AU.planFocusAboveSession m0) (Just "p1")
            , test "session window on top → close the session" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , activeId = Just "s1"
                                , windowPositions =
                                    Dict.fromList
                                        [ ( "p1", { x = 0, y = 0, w = 100, h = 100, z = 9 } )
                                        , ( "s1", { x = 0, y = 0, w = 100, h = 100, z = 10 } )
                                        ]
                            }
                    in
                    Expect.equal (AU.planFocusAboveSession m0) Nothing
            , test "no active session → the plan is the close target" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , activeId = Nothing
                            }
                    in
                    Expect.equal (AU.planFocusAboveSession m0) (Just "p1")
            , test "no active plan → nothing (session fallback in the caller)" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | planActiveId = Nothing
                                , activeId = Just "s1"
                            }
                    in
                    Expect.equal (AU.planFocusAboveSession m0) Nothing
            ]
        ]
