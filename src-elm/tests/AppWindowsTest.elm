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
import App.NodeConnection as NC
import Session.Types as T
import TestHelpers exposing (initModelWithSession)


suite : Test
suite =
    let
        -- Expect.all takes a LIST of checks over ONE subject; this is the
        -- mirror image — one check over a LIST of subjects.
        eachOf : (a -> Expect.Expectation) -> List a -> Expect.Expectation
        eachOf check subjects =
            Expect.all (List.map (\s -> \() -> check s) subjects) ()
    in
    describe "App/Windows (direct)"
        [ describe "winRect / winRectList / hasWin (INV1 accessors)"
            [ test "agree with the raw dicts for 3 sessions + 2 plans" <|
                \_ ->
                    let
                        -- Mixed key space: session ids AND plan ids live in the
                        -- same dict (SD2), so the accessors must not care which
                        -- kind a key is.
                        rects =
                            Dict.fromList
                                [ ( "s1", { x = 0, y = 0, w = 560, h = 640, z = 1 } )
                                , ( "s2", { x = 600, y = 0, w = 560, h = 640, z = 2 } )
                                , ( "s3", { x = 0, y = 700, w = 560, h = 640, z = 3 } )
                                , ( "p1", { x = 1200, y = 0, w = 680, h = 720, z = 4 } )
                                , ( "p2", { x = 1200, y = 800, w = 680, h = 720, z = 5 } )
                                ]

                        m0 =
                            { initModelWithSession
                                | sessions =
                                    [ "s1", "s2", "s3" ]
                                        |> List.map (\k -> ( k, T.emptySession k ))
                                        |> Dict.fromList
                                , sessionOrder = [ "s1", "s2", "s3" ]
                                , planWindows =
                                    Dict.fromList
                                        [ ( "p1", AT.emptyPlanWindow )
                                        , ( "p2", AT.emptyPlanWindow )
                                        ]
                                , planOrder = [ "p1", "p2" ]
                                , windowPositions = rects
                            }

                        keys =
                            Dict.keys rects
                    in
                    Expect.all
                        -- F0: the accessors are the raw dict, exactly. They are a
                        -- read PATH, not a read CHANGE — solo (F1) is what makes
                        -- the effective geometry differ, and only through these.
                        [ \_ ->
                            eachOf
                                (\k ->
                                    Expect.all
                                        [ \() -> Expect.equal (W.winRect m0 k) (Dict.get k rects)
                                        , \() -> Expect.equal (W.hasWin m0 k) True
                                        ]
                                        ()
                                )
                                keys
                        , \_ -> Expect.equal (W.winRectList m0) (Dict.toList rects)
                        , \_ -> Expect.equal (List.length (W.winRectList m0)) 5
                        , \_ -> eachOf (\k -> Expect.equal (W.winRect m0 k) Nothing) [ "", "s9", "p9", "s1/p1" ]
                        , \_ -> eachOf (\k -> Expect.equal (W.hasWin m0 k) False) [ "", "s9", "p9", "s1/p1" ]
                        ]
                        ()
            , test "a plan that was never placed has no rect — callers fall back as before" <|
                \_ ->
                    -- p1 exists in planWindows/planMetas (a plan scanned from
                    -- disk, not opened as a window yet), so windowPositions has
                    -- no entry for it. Every geometry consumer must degrade to
                    -- the same behavior it had before the accessors existed:
                    -- raiseWindow a no-op, placement → viewport-centered.
                    let
                        base =
                            initModelWithSession

                        m0 =
                            { base
                                | planWindows = Dict.insert "p1" AT.emptyPlanWindow Dict.empty
                                , planOrder = [ "p1" ]
                                , planMetas =
                                    Dict.fromList
                                        [ ( "p1", { origin = { sessionId = "s1", planIndex = 0 }, feedbacks = [], depth = 1, createdAt = 0, name = "p1", lastStatus = "", parentPlanId = Nothing } )
                                        ]
                                , windowPositions =
                                    Dict.insert "s1" { x = 100, y = 200, w = 560, h = 640, z = 1 } Dict.empty
                            }

                        -- raiseWindow on a key with no rect must not invent one,
                        -- must not touch the order lists, and must not spend a z.
                        raised =
                            W.raiseWindow m0 "p1"

                        -- Rule 1 with NO live source rect → viewport fallback.
                        orphan =
                            W.planPositionBelowSession { m0 | windowPositions = Dict.empty } "s1"

                        -- Rule 2 with NO live plan rect → viewport fallback.
                        orphanNode =
                            W.nodeSessionPositionBesidePlan { m0 | windowPositions = Dict.empty } "p1"
                    in
                    Expect.all
                        [ \_ -> Expect.equal (W.winRect m0 "p1") Nothing
                        , \_ -> Expect.equal (W.hasWin m0 "p1") False
                        , \_ -> Expect.equal (W.hasWin m0 "s1") True
                        -- raiseWindow: unchanged model (a no-op, not a fresh rect)
                        , \_ -> Expect.equal raised.planOrder m0.planOrder
                        , \_ -> Expect.equal raised.nextZIndex m0.nextZIndex
                        , \_ -> Expect.equal raised.windowPositions m0.windowPositions
                        -- placement: the viewport-centered fallback, checked
                        -- against the function that computes it (F0 must not
                        -- change the fallback — an inline literal would pin a
                        -- number instead of pinning the behavior).
                        , \_ -> Expect.equal orphan (W.centeredPlanPos { m0 | windowPositions = Dict.empty })
                        , \_ -> Expect.equal orphanNode (W.centeredSessionPos { m0 | windowPositions = Dict.empty })
                        , \_ -> Expect.equal ( orphan.w, orphan.h ) ( W.planDefaultWinW, W.planDefaultWinH )
                        , \_ -> Expect.equal ( orphanNode.w, orphanNode.h ) ( W.defaultWinW, W.defaultWinH )
                        -- and the positive case: with a source rect, rule 1 still
                        -- reads through the accessor and anchors below the session
                        -- (+ one planStepY cascade: p1 already belongs to s1).
                        , \_ ->
                            Expect.equal
                                (W.planPositionBelowSession m0 "s1")
                                { x = 100
                                , y = 200 + 640 + W.canvasGapY + W.planStepY
                                , w = W.planDefaultWinW
                                , h = W.planDefaultWinH
                                , z = m0.nextZIndex
                                }
                        ]
                        ()
            ]
        , describe "applyZoom"
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
                        d =
                            { kind = AT.WindowResize "s1" AT.E
                            , pointerId = 1
                            , startMouseX = 0
                            , startMouseY = 0
                            , active = True
                            , startWinX = 100
                            , startWinY = 50
                            , startWinW = 560
                            , startWinH = 640
                            , startOffsetX = 0
                            , startOffsetY = 0
                            }

                        m0 =
                            { initModelWithSession
                                | canvasScale = 2.0
                                , windowPositions = Dict.insert "s1" { x = 100, y = 50, w = 560, h = 640, z = 1 } Dict.empty
                            }

                        ( m1, _ ) =
                            W.handleResizeMove m0 40 0 d
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
                        d =
                            { kind = AT.WindowResize "s1" AT.W
                            , pointerId = 1
                            , startMouseX = 0
                            , startMouseY = 0
                            , active = True
                            , startWinX = 100
                            , startWinY = 50
                            , startWinW = 560
                            , startWinH = 640
                            , startOffsetX = 0
                            , startOffsetY = 0
                            }

                        m0 =
                            { initModelWithSession
                                | canvasScale = 1.0
                                , windowPositions = Dict.insert "s1" { x = 100, y = 50, w = 560, h = 640, z = 1 } Dict.empty
                            }

                        ( m1, _ ) =
                            W.handleResizeMove m0 -40 0 d
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
                    -- No lineage: a plan's owning session = its origin
                    -- (stable Session.id), even when the work copy changed
                    -- (the fork directory fork-1 is in sessions) — the
                    -- connection segment still points at Session.id (s1).
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
        , describe "soloTarget — which window a key-less command acts on"
            [ test "the topmost of the active plan and the active session wins" <|
                \_ ->
                    -- p1 above s1, then the reverse. Written as two explicit
                    -- boards rather than one with arithmetic on z, so a change
                    -- to the comparison cannot silently satisfy both cases.
                    let
                        board pz sz =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , activeId = Just "s1"
                                , planWindows = Dict.insert "p1" AT.emptyPlanWindow Dict.empty
                                , windowPositions =
                                    Dict.fromList
                                        [ ( "p1", { x = 0, y = 0, w = 100, h = 100, z = pz } )
                                        , ( "s1", { x = 0, y = 0, w = 100, h = 100, z = sz } )
                                        ]
                            }
                    in
                    Expect.all
                        [ \_ -> Expect.equal (W.soloTarget (board 10 9)) (Just "p1")
                        , \_ -> Expect.equal (W.soloTarget (board 9 10)) (Just "s1")
                        ]
                        ()
            , test "one-sided focus, and an empty board" <|
                \_ ->
                    let
                        rects =
                            Dict.fromList
                                [ ( "p1", { x = 0, y = 0, w = 680, h = 720, z = 1 } )
                                , ( "s1", { x = 0, y = 0, w = 560, h = 640, z = 2 } )
                                ]

                        planOnly =
                            { initModelWithSession
                                | planActiveId = Just "p1"
                                , activeId = Nothing
                                , windowPositions = rects
                            }

                        sessionOnly =
                            { initModelWithSession
                                | planActiveId = Nothing
                                , activeId = Just "s1"
                                , windowPositions = rects
                            }

                        none =
                            { initModelWithSession
                                | planActiveId = Nothing
                                , activeId = Nothing
                                , windowPositions = rects
                            }
                    in
                    Expect.all
                        [ \_ -> Expect.equal (W.soloTarget planOnly) (Just "p1")
                        , \_ -> Expect.equal (W.soloTarget sessionOnly) (Just "s1")
                        , \_ -> Expect.equal (W.soloTarget none) Nothing
                        -- a focused id whose window does not exist is not a
                        -- target either (INV2's reasoning, applied here)
                        -- a focused id whose window is gone is NOT a target:
                        -- focus is a habit, planActiveId/activeId can outlive
                        -- the window, and acting on such an id would be a
                        -- silent no-op
                        , \_ -> Expect.equal (W.soloTarget { planOnly | windowPositions = Dict.empty }) Nothing
                        ]
                        ()
            ]
        ]
