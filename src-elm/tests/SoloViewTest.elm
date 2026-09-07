module SoloViewTest exposing (suite)

{-| Solo view (F-series): the state machine, the geometry derivation and the
interaction gating. Everything here is pure — the feature's rule is that the
presentation lives in Elm (SD7), so the JS bridge is not exercised by these
tests at all (that half is `e2e/solo-e2e.mjs`).

The invariants under test are TODO.md's INV2/INV3/INV4 and SD6/SD8/SD9/SD13;
the numbers they assert are behaviour, not layout taste.
-}

import Dict
import Expect
import Json.Encode as E
import Set
import App.Pointer as P
import App.Types as AT
import App.Update as AU
import App.Windows as W
import Session.Types as T
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


-- A three-window board: two sessions and a plan belonging to "s1". The
-- rects are deliberately unsymmetric so a wrong x/y/w/h cannot pass.


board : AT.Model
board =
    let
        s2 =
            T.emptySession "s2"

        rects =
            Dict.fromList
                [ ( "s1", { x = 100, y = 100, w = 560, h = 640, z = 1 } )
                , ( "s2", { x = 700, y = 100, w = 560, h = 640, z = 2 } )
                , ( "p1", { x = 100, y = 764, w = 560, h = 720, z = 3 } )
                ]
    in
    { initModelWithSession
        | sessions = Dict.insert "s2" s2 initModelWithSession.sessions
        , sessionOrder = [ "s1", "s2" ]
        , planWindows = Dict.insert "p1" AT.emptyPlanWindow Dict.empty
        , planOrder = [ "p1" ]
        , planMetas =
            Dict.fromList
                [ ( "p1", { origin = { sessionId = "s1", planIndex = 0 }, feedbacks = [], depth = 1, createdAt = 0, name = "p1", lastStatus = "", parentPlanId = Nothing } )
            ]
        , windowPositions = rects
        , nextZIndex = 4
        , appWidth = 1400
        , appHeight = 900
    }


soloS1 : AT.Model
soloS1 =
    W.enterSolo "s1" board


suite : Test
suite =
    describe "solo view (F1)"
        [ describe "geometry is derived, never stored (SD5)"
            [ test "the solo window gets the viewport, the others get Nothing" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            Expect.equal
                                (W.winRect soloS1 "s1")
                                (Just { x = 0, y = 0, w = 1400, h = 900, z = 1 })
                        , \_ -> Expect.equal (W.winRect soloS1 "s2") Nothing
                        , \_ -> Expect.equal (W.winRect soloS1 "p1") Nothing
                        -- winRectList is the visible board, so the chain
                        -- payload and anything else walking it cannot draw a
                        -- curve to a window that is not there.
                        , \_ -> Expect.equal (List.map Tuple.first (W.winRectList soloS1)) [ "s1" ]
                        -- …while `hasWin` still says all three exist: solo
                        -- hides, it does not destroy (SD1).
                        , \_ -> Expect.equal (List.map (W.hasWin soloS1) [ "s1", "s2", "p1" ]) [ True, True, True ]
                        ]
                        ()
            , test "the rect is the VIEWPORT mapped into canvas coordinates" <|
                \_ ->
                    -- Panels live inside .canvas, which is
                    -- translate3d(offset) scale(scale). Filling the viewport
                    -- therefore means inverse-transforming it — the naive
                    -- 0,0,appWidth,appHeight is only right at offset 0/scale 1
                    -- (which is why an e2e at default zoom cannot catch this).
                    let
                        moved =
                            W.enterSolo "s1"
                                { board
                                    | canvasOffset = { x = 300, y = -200 }
                                    , canvasScale = 2.0
                                }
                    in
                    Expect.equal
                        (W.winRect moved "s1")
                        (Just { x = -150, y = 100, w = 700, h = 450, z = 1 })
            , test "an OS resize moves the solo rect for free (SD5)" <|
                \_ ->
                    let
                        resized =
                            { soloS1 | appWidth = 800, appHeight = 600 }
                    in
                    Expect.equal
                        (W.winRect resized "s1" |> Maybe.map (\p -> ( p.w, p.h )))
                        (Just ( 800, 600 ))
            , test "solo keeps the window's own z (nothing is re-stacked)" <|
                \_ ->
                    -- p1 is the topmost of the board (z 3); solo'ing it must
                    -- not raise it further, and nextZIndex must not move.
                    Expect.all
                        [ \_ -> Expect.equal (W.winRect (W.enterSolo "p1" board) "p1" |> Maybe.map .z) (Just 3)
                        , \_ -> Expect.equal (W.enterSolo "p1" board).nextZIndex board.nextZIndex
                        ]
                        ()
            ]
        , describe "INV4 — entering and leaving solo writes nothing else"
            [ test "enterSolo touches no layout field" <|
                \_ ->
                    Expect.equal
                        ( layoutOf soloS1 )
                        ( layoutOf board )
            , test "enter → exit is the identity on the whole model" <|
                \_ ->
                    Expect.equal (W.exitSolo soloS1).windowPositions board.windowPositions
            , test "update SoloWindow → ExitSolo round-trips the model" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update (AT.SoloWindow "s1") board

                        ( m2, _ ) =
                            AU.update AT.ExitSolo m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin (Just "s1")
                        , \_ -> Expect.equal m2.soloWin Nothing
                        , \_ -> Expect.equal (layoutOf m2) (layoutOf board)
                        -- ExitSolo rebuilds the chain; every other field of
                        -- the model must be exactly what it was.
                        , \_ -> Expect.equal (layoutOf m1) (layoutOf board)
                        ]
                        ()
            , test "ToggleSolo flips both directions" <|
                \_ ->
                    let
                        ( on, _ ) =
                            AU.update (AT.ToggleSolo "s2") board

                        ( off, _ ) =
                            AU.update (AT.ToggleSolo "s2") on

                        ( other, _ ) =
                            AU.update (AT.ToggleSolo "p1") on
                    in
                    Expect.all
                        [ \_ -> Expect.equal on.soloWin (Just "s2")
                        , \_ -> Expect.equal off.soloWin Nothing
                        -- toggling a DIFFERENT window while solo moves solo,
                        -- it does not exit (SD3's "opening X moves solo onto X")
                        , \_ -> Expect.equal other.soloWin (Just "p1")
                        ]
                        ()
            , test "a key with no window cannot go solo" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update (AT.SoloWindow "ghost") board
                    in
                    Expect.equal m1 board
            ]
        , describe "INV2 — a stale soloWin degrades to the canvas"
            [ test "winRect ignores a soloWin whose window is gone" <|
                \_ ->
                    let
                        stale =
                            { board | soloWin = Just "gone" }
                    in
                    Expect.all
                        [ \_ -> Expect.equal (W.isSolo stale) False
                        , \_ -> Expect.equal (W.soloKey stale) Nothing
                        , \_ -> Expect.equal (W.winRect stale "s1") (Dict.get "s1" board.windowPositions)
                        , \_ -> Expect.equal (W.winRect stale "s2") (Dict.get "s2" board.windowPositions)
                        , \_ -> Expect.equal (W.visibleWindows stale board.sessionOrder) [ "s1", "s2" ]
                        ]
                        ()
            , test "closing the solo window exits solo (SD9)" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update (AT.CloseSession "s1") soloS1
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin Nothing
                        -- …and the surviving windows come back at their
                        -- stored rects.
                        , \_ -> Expect.equal (W.winRect m1 "s2") (Dict.get "s2" board.windowPositions)
                        ]
                        ()
            , test "closing ANOTHER window leaves solo alone" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update (AT.CloseSession "s2") soloS1
                    in
                    Expect.equal m1.soloWin (Just "s1")
            , test "closing the solo PLAN window exits solo (SD9)" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update (AT.PlanClose "p1") (W.enterSolo "p1" board)
                    in
                    Expect.equal m1.soloWin Nothing
            -- F2.4: the empty state and solo are mutually exclusive, so
            -- `viewNoSessionPanel`'s "right-click the canvas" tagline is never
            -- shown over a view where the canvas is covered. Closing the LAST
            -- window must clear solo (SD9) and leave the shell in canvas view —
            -- otherwise the advice would be a lie exactly when it is read.
            , test "closing the only window leaves canvas view, not solo (F2.4)" <|
                \_ ->
                    let
                        only =
                            { initModelWithSession
                                | windowPositions =
                                    Dict.insert "s1" { x = 0, y = 0, w = 1400, h = 900, z = 1 } Dict.empty
                                , soloWin = Just "s1"
                            }

                        ( m1, _ ) =
                            AU.update (AT.CloseSession "s1") only
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin Nothing
                        , \_ -> Expect.equal (W.isSolo m1) False
                        , \_ -> Expect.equal (m1.sessionOrder /= [] || m1.planOrder /= []) False
                        ]
                        ()
            ]
        , describe "SD8 — who may take the solo view"
            [ test "a session the USER created follows solo" <|
                \_ ->
                    let
                        m0 =
                            { soloS1 | planCreating = Just (AT.UserCreate "chat"), activeId = Just "s1" }

                        ( m1, _ ) =
                            AU.update (AT.SessionCreated "s9") m0
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin (Just "s9")
                        , \_ -> Expect.equal (W.winRect m1 "s9") (Just (W.soloRect m1 "s9"))
                        , \_ -> Expect.equal (W.visibleWindows m1 m1.sessionOrder) [ "s9" ]
                        ]
                        ()
            , test "a session the RUNNER created does not steal it" <|
                \_ ->
                    let
                        m0 =
                            { soloS1
                                | planCreating = Just (AT.RunnerCreate "p1" "t1")
                                , planNodeSessions = Dict.empty
                            }

                        ( m1, _ ) =
                            AU.update (AT.SessionCreated "s9") m0
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin (Just "s1")
                        -- the runner's window is on the board, just not shown
                        , \_ -> Expect.equal (W.hasWin m1 "s9") True
                        , \_ -> Expect.equal (W.winRect m1 "s9") Nothing
                        ]
                        ()
            , test "creating a window in canvas view never ENTERS solo" <|
                \_ ->
                    let
                        m0 =
                            { board | planCreating = Just (AT.UserCreate "chat") }

                        ( m1, _ ) =
                            AU.update (AT.SessionCreated "s9") m0
                    in
                    Expect.equal m1.soloWin Nothing
            , test "a plan opened from the solo session takes solo (SD3)" <|
                \_ ->
                    -- p1's meta binds it to s1, and s1 is solo.
                    let
                        m1 =
                            W.addPlanWindow "p1" AT.emptyPlanWindow soloS1
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin (Just "p1")
                        , \_ -> Expect.equal (W.winRect m1 "s1") Nothing
                        ]
                        ()
            , test "a plan owned by another session does not steal solo (SD8)" <|
                \_ ->
                    -- p2 belongs to s2, which is hidden behind the solo s1.
                    let
                        m0 =
                            { soloS1
                                | planMetas =
                                    Dict.insert "p2"
                                        { origin = { sessionId = "s2", planIndex = 0 }, feedbacks = [], depth = 1, createdAt = 0, name = "p2", lastStatus = "", parentPlanId = Nothing }
                                        soloS1.planMetas
                            }

                        m1 =
                            W.addPlanWindow "p2" AT.emptyPlanWindow m0
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin (Just "s1")
                        , \_ -> Expect.equal (W.winRect m1 "p2") Nothing
                        ]
                        ()
            ]
        , describe "SD6 — hidden means not rendered"
            [ test "visibleWindows filters both order lists" <|
                \_ ->
                    Expect.all
                        [ \_ -> Expect.equal (W.visibleWindows soloS1 board.sessionOrder) [ "s1" ]
                        , \_ -> Expect.equal (W.visibleWindows soloS1 board.planOrder) []
                        -- canvas view: everything stays, in order
                        , \_ -> Expect.equal (W.visibleWindows board board.sessionOrder) [ "s1", "s2" ]
                        , \_ -> Expect.equal (W.visibleWindows board board.planOrder) [ "p1" ]
                        ]
                        ()
            ]
        , describe "SD13 — the chain is a canvas feature"
            [ test "the payload is empty in solo on BOTH sides" <|
                \_ ->
                    let
                        chain =
                            [ { kind = "plan", sessionId = "s1", planId = "p1", nodeId = Nothing } ]

                        inSolo =
                            W.chainPayload { soloS1 | connectionChain = chain } chain

                        inCanvas =
                            W.chainPayload { board | connectionChain = chain } chain
                    in
                    Expect.all
                        [ \_ -> Expect.equal inSolo.segments []
                        , \_ -> Expect.equal inSolo.positions []
                        -- the same model minus solo must carry both again:
                        -- this is what makes ExitSolo's re-send work without
                        -- any call site knowing about solo.
                        , \_ -> Expect.equal (List.length inCanvas.segments) 1
                        , \_ -> Expect.equal (List.length inCanvas.positions) 3
                        ]
                        ()
            , test "exit rebuilds the chain for the window in focus" <|
                \_ ->
                    let
                        -- s1 is a plan node session, so its chain is not empty
                        nodeBoard =
                            { board
                                | planNodeSessions = Dict.insert "s1" "p1/t1" Dict.empty
                                , activeId = Just "s1"
                            }

                        m1 =
                            W.enterSolo "s1" nodeBoard

                        ( m2, _ ) =
                            AU.update AT.ExitSolo m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.connectionChain nodeBoard.connectionChain
                        , \_ -> Expect.equal m2.connectionChain (W.connectionChainForSession nodeBoard "s1")
                        , \_ -> Expect.equal (List.length m2.connectionChain) 2
                        ]
                        ()
            , test "entering solo keeps the chain in the model (it is only hidden)" <|
                \_ ->
                    let
                        nodeBoard =
                            { board
                                | planNodeSessions = Dict.insert "s1" "p1/t1" Dict.empty
                                , connectionChain = [ { kind = "plan", sessionId = "s1", planId = "p1", nodeId = Nothing } ]
                            }
                    in
                    Expect.equal (W.enterSolo "s1" nodeBoard).connectionChain nodeBoard.connectionChain
            ]
        , describe "SD7 — the gestures are refused in Elm"
            [ test "toDragKind refuses every draggable surface while solo" <|
                \_ ->
                    let
                        solo =
                            [ AT.toDragKind True P.TCanvas "s1" "" ""
                            , AT.toDragKind True P.TSessionBar "s1" "" ""
                            , AT.toDragKind True P.TPlanBar "" "p1" ""
                            , AT.toDragKind True P.TSessionHandle "s1" "" "nw"
                            , AT.toDragKind True P.TPlanHandle "" "p1" "se"
                            ]

                        canvas =
                            [ AT.toDragKind False P.TCanvas "s1" "" ""
                            , AT.toDragKind False P.TSessionBar "s1" "" ""
                            , AT.toDragKind False P.TPlanBar "" "p1" ""
                            , AT.toDragKind False P.TSessionHandle "s1" "" "nw"
                            , AT.toDragKind False P.TPlanHandle "" "p1" "se"
                            ]
                    in
                    Expect.all
                        [ \_ -> Expect.equal solo (List.repeat 5 Nothing)
                        , \_ -> Expect.equal (List.all ((/=) Nothing) canvas) True
                        ]
                        ()
            , test "pointerdown arms nothing in solo but still tracks the pointer" <|
                \_ ->
                    let
                        raw =
                            E.object
                                [ ( "pointerId", E.int 7 )
                                , ( "pointerType", E.string "mouse" )
                                , ( "button", E.int 0 )
                                , ( "clientX", E.float 400 )
                                , ( "clientY", E.float 300 )
                                , ( "targetKind", E.string "session-bar" )
                                , ( "sessionId", E.string "s1" )
                                , ( "planId", E.string "" )
                                , ( "handle", E.string "" )
                                ]

                        m1 =
                            AU.update (AT.PointerDown raw) soloS1 |> Tuple.first

                        m2 =
                            AU.update (AT.PointerDown raw) board |> Tuple.first
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.drag Nothing
                        , \_ -> Expect.equal m1.longPress Nothing
                        , \_ -> Expect.equal m1.pinch Nothing
                        -- The bookkeeping MUST run: pointerup removes by id,
                        -- and a pointer left in the map breaks the next
                        -- gesture after solo ends.
                        , \_ -> Expect.equal (Dict.member 7 m1.activePointers) True
                        -- the control: the same event arms a drag in canvas view
                        , \_ -> Expect.equal (m2.drag |> Maybe.map .kind) (Just (AT.WindowMove "s1"))
                        ]
                        ()
            , test "wheel zoom and zoom-reset are no-ops in solo" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update (AT.CanvasZoom 120 400 300) soloS1

                        ( m2, _ ) =
                            AU.update AT.CanvasZoomReset soloS1

                        ( m3, _ ) =
                            AU.update (AT.CanvasZoom 120 400 300) board
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1 soloS1
                        , \_ -> Expect.equal m2 soloS1
                        -- control: the same wheel event zooms the canvas
                        , \_ -> Expect.equal (m3.canvasScale /= board.canvasScale) True
                        ]
                        ()
            ]
        , describe "soloTarget — what the menu and the shortcut act on"
            [ test "the topmost of session and plan wins" <|
                \_ ->
                    let
                        planOnTop =
                            { board | activeId = Just "s1", planActiveId = Just "p1" }

                        sessionOnTop =
                            { planOnTop
                                | windowPositions =
                                    Dict.insert "s1" { x = 0, y = 0, w = 560, h = 640, z = 9 } planOnTop.windowPositions
                            }

                        planOnly =
                            { board | activeId = Nothing, planActiveId = Just "p1" }

                        none =
                            { board | activeId = Nothing, planActiveId = Nothing, windowPositions = Dict.empty }
                    in
                    Expect.all
                        [ \_ -> Expect.equal (W.soloTarget planOnTop) (Just "p1")
                        , \_ -> Expect.equal (W.soloTarget sessionOnTop) (Just "s1")
                        , \_ -> Expect.equal (W.soloTarget planOnly) (Just "p1")
                        , \_ -> Expect.equal (W.soloTarget none) Nothing
                        ]
                        ()
            , test "Ctrl+Shift+F toggles the topmost window" <|
                \_ ->
                    -- board's planActiveId is Nothing (initModelWithSession's),
                    -- so the topmost question would answer with s1. Make p1 the
                    -- active plan: its z (3) is above s1's (1).
                    let
                        focused =
                            { board | planActiveId = Just "p1" }

                        ( m1, _ ) =
                            AU.update (AT.KeyDown "F" True False True False) focused

                        ( m2, _ ) =
                            AU.update (AT.KeyDown "F" True False True False) m1
                    in
                    Expect.all
                        [ \_ -> Expect.equal m1.soloWin (Just "p1")
                        , \_ -> Expect.equal m2.soloWin Nothing
                        -- plain Ctrl+F (browser find) must not trigger it
                        , \_ ->
                            AU.update (AT.KeyDown "f" True False False False) focused
                                |> Tuple.first
                                |> .soloWin
                                |> Expect.equal Nothing
                        -- …nor Ctrl+Shift+F once something already handled the
                        -- key (the early return is the first branch).
                        , \_ ->
                            AU.update (AT.KeyDown "F" True False True True) focused
                                |> Tuple.first
                                |> .soloWin
                                |> Expect.equal Nothing
                        ]
                        ()
            ]
        , describe "SD11 — attentionCounts (what the exit control reports)"
            [ test "canvas view counts nothing: no window is hidden" <|
                \_ ->
                    let
                        busy =
                            { board
                                | sessions =
                                    Dict.map (\_ s -> { s | taskRunning = True, closeConfirm = True }) board.sessions
                            }
                    in
                    Expect.equal (W.attentionCounts busy) { waiting = 0, running = 0 }
            , test "a hidden window stalled on the user is counted, running separately" <|
                \_ ->
                    -- s2 sits behind the solo s1 with a tool confirmation open
                    -- and a task running: the run is stalled and NOTHING on
                    -- screen says so. That is the bug this count exists for.
                    let
                        hidden =
                            hideSession "s2" (\s -> { s | pendingConfirm = [ { id = "t1", toolName = Just "edit_file", toolInput = Nothing } ], taskRunning = True }) soloS1
                    in
                    Expect.equal (W.attentionCounts hidden) { waiting = 1, running = 1 }
            , test "the VISIBLE solo window is never counted (it is on screen)" <|
                \_ ->
                    let
                        soloBlocked =
                            hideSession "s1" (\s -> { s | closeConfirm = True, taskRunning = True }) soloS1
                    in
                    Expect.equal (W.attentionCounts soloBlocked) { waiting = 0, running = 0 }
            , test "every waiting condition the view can render is covered" <|
                \_ ->
                    -- One entry per overlay renderer in App/View.elm. A new
                    -- modal added there without a matching field here means
                    -- solo stops reporting a stalled session — the exact
                    -- failure SD11 exists to prevent — so the list is pinned
                    -- field by field instead of by counting entries.
                    let
                        conditions =
                            [ ( "closeConfirm", \s -> { s | closeConfirm = True } )
                            , ( "cancelTaskConfirm", \s -> { s | cancelTaskConfirm = True } )
                            , ( "pendingConfirm", \s -> { s | pendingConfirm = [ { id = "t", toolName = Nothing, toolInput = Nothing } ] } )
                            , ( "pendingMcpAuths", \s -> { s | pendingMcpAuths = [ { server = "srv", url = "" } ] } )
                            , ( "mcpAuthRunning", \s -> { s | mcpAuthRunning = Just "srv" } )
                            , ( "mcpStatus", \s -> { s | mcpStatus = Just "auth_required" } )
                            , ( "filePicker"
                              , \s ->
                                    let
                                        fp =
                                            s.filePicker
                                    in
                                    { s | filePicker = { fp | show = True } }
                              )
                            , ( "showModelSelector", \s -> { s | showModelSelector = True } )
                            , ( "mediaPreview", \s -> { s | mediaPreview = Just { mediaType = T.Image, uri = "x", name = Nothing } } )
                            ]

                        missed =
                            conditions
                                |> List.filter
                                    (\( _, fn ) ->
                                        (W.attentionCounts (hideSession "s2" fn soloS1)).waiting /= 1
                                    )
                                |> List.map Tuple.first
                    in
                    Expect.equal missed []
            , test "a stale soloWin counts nothing (INV2b again)" <|
                \_ ->
                    Expect.equal
                        (W.attentionCounts { board | soloWin = Just "gone" })
                        { waiting = 0, running = 0 }
            ]
        , describe "INV3 — soloWin is only written by the three helpers"
            -- Enforced mechanically by scripts/check-layout-invariants.sh
            -- (`soloWin =` outside App/Windows.elm fails the build). Pinned
            -- here as behaviour: the follow helper's four cases.
            [ test "followSolo SoloCreated only moves an EXISTING solo" <|
                \_ ->
                    Expect.all
                        [ \_ -> Expect.equal (W.followSolo (W.SoloCreated "s2") board).soloWin Nothing
                        , \_ -> Expect.equal (W.followSolo (W.SoloCreated "s2") soloS1).soloWin (Just "s2")
                        , \_ -> Expect.equal (W.followSolo (W.SoloCreated "s2") (W.enterSolo "ghost" board)).soloWin Nothing
                        ]
                        ()
            , test "followSolo SoloClosed clears only its own key" <|
                \_ ->
                    Expect.all
                        [ \_ -> Expect.equal (W.followSolo (W.SoloClosed "s1") soloS1).soloWin Nothing
                        , \_ -> Expect.equal (W.followSolo (W.SoloClosed "s2") soloS1).soloWin (Just "s1")
                        , \_ -> Expect.equal (W.followSolo (W.SoloClosed "s1") board).soloWin Nothing
                        ]
                        ()
            ]
        ]


-- The fields solo must never write (INV4). Compared as one record so a new
-- write shows up as a named failure instead of a silent diff.


layoutOf : AT.Model -> { rects : Dict.Dict String AT.WindowPos, offset : { x : Int, y : Int }, scale : Float, sessions : List String, plans : List String, nextZ : Int }
layoutOf m =
    { rects = m.windowPositions
    , offset = m.canvasOffset
    , scale = m.canvasScale
    , sessions = m.sessionOrder
    , plans = m.planOrder
    , nextZ = m.nextZIndex
    }


{-| Put a session's state through `fn` (leaving every other field alone) —
the test's own fixture helper, because `Session.Types` has no update lens.
-}
hideSession : String -> (T.SessionState -> T.SessionState) -> AT.Model -> AT.Model
hideSession key fn model =
    { model
        | sessions =
            Dict.insert
                key
                (fn (Dict.get key model.sessions |> Maybe.withDefault (T.emptySession key)))
                model.sessions
    }
