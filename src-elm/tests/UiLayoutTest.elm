module UiLayoutTest exposing (suite)

{-| The layout store's client policy (F3): what a file may do to the board, and
what the board may do to the file.

Split by the two directions, because each has its own failure mode:

  * READING (`decodeGet`, `applyLoaded`, `App.Windows.storedRect` /
    `restoreOrPlace`) — a corrupt, hand-edited or future-version file must
    degrade to "somebody else's layout", never to an unusable window or a board
    the user cannot get back. Restoring is precisely the act of trusting a file
    you did not write.
  * WRITING (`App.UiLayout` driven through `App.Update`) — a write happens at
    the END of an interaction and describes the board actually on screen. The
    failure mode here is silent: an over-eager saver floods the backend on every
    click, an under-eager one loses a layout the user believes they saved, and
    neither shows up until a restart. `UiFlush` is driven directly as "write the
    store now", which keeps these assertions about the policy rather than about
    a gesture's plumbing.

The document schema itself (leniency, per-entry repair, cap arithmetic) is
`UiConfigTest`'s job; the gesture FSM is `PointerFsmTest`'s. Neither is repeated
here.
-}

import Dict exposing (Dict)
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import App.Types as AT exposing (Msg(..))
import App.Update as AU
import App.UiConfig as UC
import App.UiLayout as UiLayout
import App.Windows as Win
import TestHelpers exposing (initModelWithSession)


-- ─── fixtures ─────────────────────────────────────────────────────


entry : Int -> Int -> Int -> Int -> Int -> UC.Entry
entry x y w h t =
    { x = x, y = y, w = w, h = h, t = t }


docOf : Maybe String -> Dict String UC.Entry -> UC.Document
docOf solo windows =
    UC.fromStore
        { solo = solo
        , offset = { x = 0, y = 0 }
        , scale = 1.0
        , windows = windows
        , extras = Dict.empty
        }


{-| The get_ui_config envelope, as the bridge builds it. -}
envelope : Bool -> E.Value -> String -> E.Value
envelope ok config error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "version", E.int UC.version )
        , ( "config", config )
        , ( "error", E.string error )
        ]


{-| The pointer payload transport.js forwards (App/Pointer.pointerEventDecoder). -}
pev : Int -> Float -> Float -> String -> String -> E.Value
pev id x y target sessionId =
    E.object
        [ ( "pointerId", E.int id )
        , ( "pointerType", E.string "mouse" )
        , ( "button", E.int 0 )
        , ( "clientX", E.float x )
        , ( "clientY", E.float y )
        , ( "targetKind", E.string target )
        , ( "sessionId", E.string sessionId )
        , ( "planId", E.string "" )
        , ( "handle", E.string "" )
        ]


{-| A client that HAS read ui.conf (the gate on every write, see
`App.UiLayout.syncUiLayout`) with these windows on the board. Most tests need
this: without it they would only prove that a gated client writes nothing, which
is a different assertion (and has its own test). -}
read : AT.Model -> AT.Model
read =
    UiLayout.markLoaded


bareBoard : List ( String, Int, Int ) -> AT.Model -> AT.Model
bareBoard specs model =
    { model
        | windowPositions =
            specs
                |> List.indexedMap
                    (\i ( k, x, y ) ->
                        ( k, { x = x, y = y, w = Win.defaultWinW, h = Win.defaultWinH, z = i + 1 } )
                    )
                |> Dict.fromList
    }


board : List ( String, Int, Int ) -> AT.Model -> AT.Model
board specs =
    read << bareBoard specs


flush : AT.Model -> AT.Model
flush =
    AU.update UiFlush >> Tuple.first


touchOf : String -> AT.Model -> Maybe Int
touchOf key model =
    model.uiLayout |> Dict.get key |> Maybe.map .t



-- ─── reading the envelope ────────────────────────────────────────


decodeSuite : Test
decodeSuite =
    describe "decodeGet — the get_ui_config envelope"
        [ test "a stored document is read" <|
            \_ ->
                envelope True (UC.encode (docOf Nothing (Dict.fromList [ ( "s9", entry 1 2 3 4 9 ) ]))) ""
                    |> UiLayout.decodeGet
                    |> Result.map (Maybe.map .windows)
                    |> Expect.equal (Ok (Just (Dict.fromList [ ( "s9", entry 1 2 3 4 9 ) ])))
        , test "config null means 'no file yet', which is not a failure" <|
            \_ ->
                envelope True E.null ""
                    |> UiLayout.decodeGet
                    |> Expect.equal (Ok Nothing)
        , test "a missing config key means the same thing" <|
            \_ ->
                E.object [ ( "ok", E.bool True ), ( "error", E.string "" ) ]
                    |> UiLayout.decodeGet
                    |> Expect.equal (Ok Nothing)
        , test "a body that is not an object is no document — and still no error" <|
            \_ ->
                envelope True (E.string "garbage") ""
                    |> UiLayout.decodeGet
                    |> Expect.equal (Ok Nothing)
        , test "a refused read keeps its reason, because nothing else shows it" <|
            \_ ->
                case UiLayout.decodeGet (envelope False E.null "permission denied") of
                    Err why ->
                        Expect.all
                            [\s -> Expect.equal True (String.contains "permission denied" s)
                            , \s -> Expect.equal True (String.contains "get_ui_config" s)
                            ]
                            why

                    Ok _ ->
                        Expect.fail "a refused read must not look like an empty file"
        , test "a refused WRITE is reported the same way" <|
            \_ ->
                case UiLayout.decodeSyncResult (E.object [ ( "ok", E.bool False ), ( "error", E.string "too many windows" ) ]) of
                    Err why ->
                        Expect.equal True (String.contains "too many windows" why)

                    Ok _ ->
                        Expect.fail "a refused write reported as success would be the silent kind"
        ]


-- ─── the read: what a file may do to the board ───────────────────


applySuite : Test
applySuite =
    describe "applyLoaded — trusting a file you did not write"
        [ test "the board memory lands, and the touch counter clears above it" <|
            \_ ->
                let
                    after =
                        UiLayout.applyLoaded (docOf Nothing (Dict.fromList [ ( "s9", entry 40 50 560 400 77 ) ]))
                            initModelWithSession
                in
                Expect.all
                    [\m -> Expect.equal (Just (entry 40 50 560 400 77)) (Dict.get "s9" m.uiLayout)
                    , \m -> Expect.equal 77 m.uiTouch
                    ]
                    after
        , test "a stored touch never moves the counter backwards" <|
            \_ ->
                -- Eviction orders by `t`. A file written by an earlier build (or
                -- hand-edited) must not make an old entry look newer than the
                -- last write this process performed.
                UiLayout.applyLoaded (docOf Nothing (Dict.fromList [ ( "s9", entry 1 1 400 300 3 ) ]))
                    { initModelWithSession | uiTouch = 500 }
                    |> .uiTouch
                    |> Expect.equal 500
        , test "an unknown top-level key survives the load, to be written back out" <|
            \_ ->
                -- sync_ui_config REPLACES the file. Carrying the key through is
                -- the difference between "an old client ignores a new field" and
                -- "an old client deletes it" — the model.conf lesson, again.
                let
                    loaded =
                        envelope True
                            (E.object
                                [ ( "version", E.int 1 )
                                , ( "canvasScale", E.float 1.0 )
                                , ( "hyperdrive", E.bool True )
                                ]
                            )
                            ""
                            |> UiLayout.decodeGet
                            |> Result.withDefault Nothing

                    after =
                        Maybe.map (\d -> UiLayout.applyLoaded d initModelWithSession) loaded
                            |> Maybe.withDefault initModelWithSession
                in
                Expect.equal [ "hyperdrive" ] (Dict.keys after.uiExtras)
        , test "the stored viewport applies to a viewport nobody has touched" <|
            \_ ->
                let
                    stored =
                        UC.fromStore
                            { solo = Nothing
                            , offset = { x = -300, y = 120 }
                            , scale = 1.75
                            , windows = Dict.empty
                            , extras = Dict.empty
                            }
                in
                UiLayout.applyLoaded stored initModelWithSession
                    |> (\m -> ( m.canvasOffset, m.canvasScale ))
                    |> Expect.equal ( { x = -300, y = 120 }, 1.75 )
        , test "…but NOT onto one the user has already panned" <|
            \_ ->
                -- The read is asynchronous. Applying it over a gesture in
                -- progress yanks the board out from under the pointer, so the
                -- file loses that race — deliberately, and only for the canvas.
                let
                    stored =
                        UC.fromStore
                            { solo = Nothing
                            , offset = { x = -300, y = 120 }
                            , scale = 1.75
                            , windows = Dict.empty
                            , extras = Dict.empty
                            }
                in
                UiLayout.applyLoaded stored { initModelWithSession | canvasOffset = { x = 7, y = 7 } }
                    |> (\m -> ( m.canvasOffset, m.canvasScale ))
                    |> Expect.equal ( { x = 7, y = 7 }, 1.0 )
        , test "a hand-edited scale cannot divide by zero or inflate the canvas" <|
            \_ ->
                -- applyZoom DIVIDES by the scale, so an unclamped 0 in the file
                -- is a crash on the next wheel tick rather than a bad zoom.
                let
                    applied s =
                        (UiLayout.applyLoaded
                            (UC.fromStore
                                { solo = Nothing
                                , offset = { x = 0, y = 0 }
                                , scale = s
                                , windows = Dict.empty
                                , extras = Dict.empty
                                }
                            )
                            initModelWithSession
                        ).canvasScale
                in
                Expect.all
                    [\_ -> Expect.within (Expect.Absolute 0.0001) Win.canvasMaxScale (applied 9999.0)
                    , \_ -> Expect.within (Expect.Absolute 0.0001) Win.canvasMinScale (applied 0.0)
                    , \_ -> Expect.within (Expect.Absolute 0.0001) 0.5 (applied 0.5)
                    ]
                    ()
        , test "a hand-edited pan stays inside the bound a drag can produce" <|
            \_ ->
                let
                    stored =
                        UC.fromStore
                            { solo = Nothing
                            , offset = { x = 100000000, y = -100000000 }
                            , scale = 1.0
                            , windows = Dict.empty
                            , extras = Dict.empty
                            }
                in
                UiLayout.applyLoaded stored initModelWithSession
                    |> .canvasOffset
                    |> Expect.equal { x = Win.canvasMaxPan, y = -Win.canvasMaxPan }
        ]


-- ─── the placement decision ──────────────────────────────────────


placeSuite : Test
placeSuite =
    describe "restoreOrPlace — where a window joins the board"
        [ test "a stored rect wins over the placement rule" <|
            \_ ->
                let
                    model =
                        { initModelWithSession | uiLayout = Dict.fromList [ ( "s1", entry 111 222 640 480 3 ) ] }

                    computed =
                        Win.centeredSessionPos model
                in
                let
                    rect =
                        Win.restoreOrPlace model "s1" computed
                in
                Expect.all
                    [\_ -> Expect.equal 111 rect.x
                    , \_ -> Expect.equal 222 rect.y
                    , \_ -> Expect.equal 640 rect.w
                    , \_ -> Expect.equal 480 rect.h
                    ]
                    ()
        , test "…but it never brings its z: stacking follows this process (SD17)" <|
            \_ ->
                let
                    model =
                        { initModelWithSession | uiLayout = Dict.fromList [ ( "s1", entry 111 222 640 480 3 ) ] }

                    computed =
                        Win.centeredSessionPos model
                in
                Win.restoreOrPlace model "s1" computed
                    |> .z
                    |> Expect.equal computed.z
        , test "no entry for that identity means the placement rule stands" <|
            \_ ->
                let
                    model =
                        { initModelWithSession | uiLayout = Dict.fromList [ ( "other", entry 111 222 640 480 3 ) ] }

                    computed =
                        Win.centeredSessionPos model
                in
                Win.restoreOrPlace model "s1" computed
                    |> (\p -> ( p.x, p.y ))
                    |> Expect.equal ( computed.x, computed.y )
        , test "a rect below the minimum window size is refused, not clamped up" <|
            \_ ->
                -- Inventing a size for a 3×4 window would put a window on screen
                -- that nobody ever had. "Unusable" and "wrong size" are not the
                -- same answer, and only one of them falls back to the rule.
                Expect.equal Nothing (Win.storedRect (entry 10 10 3 4 1))
        , test "a coordinate outside the pannable canvas is refused" <|
            \_ ->
                Expect.equal Nothing (Win.storedRect (entry 9999999 0 Win.minWinW Win.minWinH 1))
        , test "the smallest legal window is legal" <|
            \_ ->
                Win.storedRect (entry 0 0 Win.minWinW Win.minWinH 1)
                    |> Expect.equal (Just { x = 0, y = 0, w = Win.minWinW, h = Win.minWinH })
        ]


-- ─── the write: what the board does to the file ──────────────────


absorbSuite : Test
absorbSuite =
    describe "the store absorbs the board, and only the board"
        [ test "no write happens before the file has been read" <|
            \_ ->
                -- The startup read can fail (backend down, refused, transport
                -- race). A client that never saw the file must not replace it
                -- with a document built from an empty store — that is how a
                -- transient error becomes permanent data loss, the exact shape
                -- of the `model.conf` hazard AGENTS.md records.
                let
                    unread =
                        bareBoard [ ( "s1", 300, 400 ) ] initModelWithSession
                in
                Expect.all
                    [\_ -> Expect.equal Dict.empty (unread |> flush |> .uiLayout)
                    ,\_ -> Expect.equal [ "s1" ] ((read unread |> flush).uiLayout |> Dict.keys)
                    ]
                    ()
        , test "a flush records a window the store has never seen" <|
            \_ ->
                let
                    after =
                        board [ ( "s1", 300, 400 ) ] initModelWithSession |> flush
                in
                Expect.all
                    [\m -> Expect.equal (Just (entry 300 400 Win.defaultWinW Win.defaultWinH 1)) (Dict.get "s1" m.uiLayout)
                    , \m -> Expect.equal 1 m.uiTouch
                    , \m -> Expect.equal [ "s1" ] (Dict.keys m.uiLayout)
                    ]
                    after
        , test "an unchanged rect keeps its touch — `t` means last MOVED" <|
            \_ ->
                -- If every flush re-touched everything, eviction would drop
                -- whichever windows happened to be open and keep whichever were
                -- idle — the opposite of least-recently-used.
                let
                    first =
                        board [ ( "s1", 300, 400 ) ] initModelWithSession |> flush
                in
                Expect.equal (Just 1) (first |> flush |> touchOf "s1")
        , test "moving one window touches it and leaves its neighbour alone" <|
            \_ ->
                let
                    two =
                        board [ ( "s1", 100, 100 ), ( "s2", 200, 200 ) ] initModelWithSession |> flush

                    moved =
                        board [ ( "s1", 100, 100 ), ( "s2", 200, 999 ) ] two |> flush
                in
                Expect.all
                    [\m -> Expect.equal (Just 1) (touchOf "s1" m)
                    , \m -> Expect.equal (Just 3) (touchOf "s2" m)
                    , \m -> Expect.equal 3 m.uiTouch
                    , \m -> Expect.equal (Just 999) (Dict.get "s2" m.uiLayout |> Maybe.map .y)
                    ]
                    moved
        , test "the store is the LAYOUT board: a solo window keeps its real rect" <|
            \_ ->
                -- winRect would answer "the viewport" while a window is solo,
                -- and writing THAT to the file remembers a window the user never
                -- had — the same corruption SD4 forbids for windowPositions.
                let
                    after =
                        board [ ( "s1", 120, 90 ) ] initModelWithSession
                            |> AU.update (SoloWindow "s1")
                            >> Tuple.first
                            |> flush
                in
                Expect.all
                    [\m -> Expect.equal True (Win.isSolo m)
                    , \m -> Expect.equal (Just 120) (Dict.get "s1" m.uiLayout |> Maybe.map .x)
                    , \m -> Expect.equal (Just 90) (Dict.get "s1" m.uiLayout |> Maybe.map .y)
                    , \m -> Expect.equal (Just Win.defaultWinH) (Dict.get "s1" m.uiLayout |> Maybe.map .h)
                    ]
                    after
        , test "closing a window keeps its memory; deleting the identity drops it" <|
            \_ ->
                -- The distinction IS SD15: a closed session may come back, and
                -- the rect is the whole reason to remember it. A deleted one has
                -- no directory left to reopen.
                let
                    stored =
                        board [ ( "s1", 300, 400 ) ] initModelWithSession |> flush

                    closed =
                        AU.update (CloseSession "s1") stored |> Tuple.first

                    deleted =
                        UiLayout.prune [ "s1" ] stored
                in
                Expect.all
                    [\m -> Expect.notEqual Nothing (Dict.get "s1" m.uiLayout)
                    , \m -> Expect.equal Nothing (Dict.get "s1" deleted.uiLayout)
                    , \m -> Expect.equal Nothing (Dict.get "s1" m.windowPositions)
                    ]
                    closed
        , test "deleting a session leaves no trace in the store" <|
            \_ ->
                -- What this pins is the PRUNE EXISTING at all, driven through the
                -- real arm rather than `prune` on its own: a delete that closes
                -- its windows but forgets the memory would grow ui.conf by one
                -- dead UUID per deletion, and nothing would look wrong.
                --
                -- It cannot pin the ORDER of the writes — the cascade below each
                -- saves, so the deleted key must already be gone from the model
                -- BEFORE them, or a stale document can land last (the first
                -- version's bug). That race is only visible against a real
                -- backend, so `e2e/solo-e2e.mjs` §12(g) reads the file back after
                -- a delete and owns that half.
                let
                    stored =
                        board [ ( "s1", 300, 400 ) ] initModelWithSession |> flush
                in
                Expect.all
                    [\m -> Expect.equal Nothing (Dict.get "s1" m.uiLayout)
                    , \m -> Expect.notEqual Nothing (Dict.get "s1" stored.uiLayout)
                    , \m -> Expect.equal Nothing (Dict.get "s1" m.windowPositions)
                    ]
                    (AU.update (DeleteSession "s1") stored |> Tuple.first)
        , test "nothing is written until the file has been read" <|
            \_ ->
                -- A write REPLACES ui.conf. A client whose read failed (backend
                -- refused, transport down mid-startup) has an empty store, and
                -- publishing it would delete the user's layout with nothing in
                -- the log to explain the disappearance later. So the gate is on
                -- the READ, not on the board being non-empty.
                let
                    positions =
                        { initModelWithSession
                            | windowPositions =
                                Dict.fromList
                                    [ ( "s1", { x = 300, y = 400, w = Win.defaultWinW, h = Win.defaultWinH, z = 1 } ) ]
                        }

                    unread =
                        flush positions

                    afterRead =
                        flush (UiLayout.markLoaded positions)
                in
                Expect.all
                    [\m -> Expect.equal False m.uiLoaded
                    , \m -> Expect.equal Dict.empty unread.uiLayout
                    , \m -> Expect.equal [ "s1" ] (Dict.keys afterRead.uiLayout)
                    ]
                    positions
        , test "a read that reports no file still unlocks writes, and applies nothing" <|
            \_ ->
                -- The answer "there is no ui.conf" is not an error and must not
                -- be treated as one — but it also must not CLEAR a store the user
                -- has already built up while the answer was in flight.
                let
                    alreadyBuilt =
                        board [ ( "s1", 300, 400 ) ] initModelWithSession |> flush

                    unlocked =
                        UiLayout.markLoaded alreadyBuilt |> flush
                in
                Expect.all
                    [\m -> Expect.equal True m.uiLoaded
                    , \m -> Expect.equal [ "s1" ] (Dict.keys m.uiLayout)
                    ]
                    unlocked
        , test "eviction protects the OPEN windows and drops the oldest touched" <|
            \_ ->
                let
                    openKey =
                        "s-open"

                    crowded =
                        List.range 1 (UC.maxStoredWindows + 5)
                            |> List.map (\i -> ( String.fromInt i, entry 0 0 Win.minWinW Win.minWinH i ))
                            |> Dict.fromList

                    base =
                        { initModelWithSession
                            | uiLayout = Dict.insert openKey (entry 5 5 Win.minWinW Win.minWinH 99999) crowded
                        }

                    after =
                        board [ ( openKey, 5, 5 ) ] base |> flush
                in
                Expect.all
                    [\m -> Expect.equal UC.maxStoredWindows (Dict.size m.uiLayout)
                    , \m -> Expect.notEqual Nothing (Dict.get openKey m.uiLayout)
                    , \m -> Expect.equal Nothing (Dict.get "1" m.uiLayout)
                    , \m -> Expect.notEqual Nothing (Dict.get (String.fromInt (UC.maxStoredWindows + 5)) m.uiLayout)
                    ]
                    after
        ]


-- ─── the triggers ────────────────────────────────────────────────


triggerSuite : Test
triggerSuite =
    describe "when a write is allowed to happen (SD16)"
        [ test "an ended window drag stores the rect it ended at" <|
            \_ ->
                let
                    after =
                        board [ ( "s1", 100, 100 ) ] initModelWithSession
                            |> AU.update (AT.PointerDown (pev 1 500 500 "session-bar" "s1"))
                            >> Tuple.first
                            |> AU.update (AT.PointerMove (pev 1 600 560 "session-bar" "s1"))
                            >> Tuple.first
                            |> AU.update (AT.PointerUp (pev 1 600 560 "session-bar" "s1"))
                            >> Tuple.first
                in
                Expect.all
                    [\m -> Expect.equal Nothing m.drag
                    , \m -> Expect.equal (Just 200) (Dict.get "s1" m.uiLayout |> Maybe.map .x)
                    , \m -> Expect.equal (Just 160) (Dict.get "s1" m.uiLayout |> Maybe.map .y)
                    ]
                    after
        , test "a drag still in flight writes nothing" <|
            \_ ->
                -- The store is not a live mirror of windowPositions. Per-frame
                -- writes were explicitly refused (SD16): the backend would see
                -- one RPC per pointer event for the rest of the feature's life.
                let
                    midDrag =
                        board [ ( "s1", 100, 100 ) ] initModelWithSession
                            |> AU.update (AT.PointerDown (pev 1 500 500 "session-bar" "s1"))
                            >> Tuple.first
                            |> AU.update (AT.PointerMove (pev 1 640 620 "session-bar" "s1"))
                            >> Tuple.first
                in
                Expect.all
                    [\m -> Expect.equal True (m.drag /= Nothing)
                    , \m -> Expect.equal Dict.empty m.uiLayout
                    ]
                    midDrag
        , test "a pointer move that never crossed the slop writes nothing" <|
            \_ ->
                -- An armed tap only activates a window. Saving there would put an
                -- RPC on the click path of every window in the app.
                let
                    after =
                        board [ ( "s1", 100, 100 ) ] initModelWithSession
                            |> AU.update (AT.PointerDown (pev 1 500 500 "session-bar" "s1"))
                            >> Tuple.first
                            |> AU.update (AT.PointerUp (pev 1 502 502 "session-bar" "s1"))
                            >> Tuple.first
                in
                Expect.equal Dict.empty after.uiLayout
        , test "a gesture the OS stole still counts as an end" <|
            \_ ->
                -- pointercancel is not a rollback: the window stayed where the
                -- drag put it, so the store must agree with the screen.
                let
                    after =
                        board [ ( "s1", 100, 100 ) ] initModelWithSession
                            |> AU.update (AT.PointerDown (pev 1 500 500 "session-bar" "s1"))
                            >> Tuple.first
                            |> AU.update (AT.PointerMove (pev 1 700 700 "session-bar" "s1"))
                            >> Tuple.first
                            |> AU.update (AT.PointerCancel (pev 1 700 700 "session-bar" "s1"))
                            >> Tuple.first
                in
                Expect.equal (Just 300) (Dict.get "s1" after.uiLayout |> Maybe.map .x)
        , test "a wheel burst costs one write: a stale generation is dropped" <|
            \_ ->
                let
                    placed =
                        board [ ( "s1", 40, 40 ) ] initModelWithSession

                    model =
                        { placed | uiZoomGen = 7 }

                    stale =
                        AU.update (UiZoomIdle 6) model |> Tuple.first

                    live =
                        AU.update (UiZoomIdle 7) model |> Tuple.first
                in
                Expect.all
                    [\_ -> Expect.equal Dict.empty stale.uiLayout
                    , \_ -> Expect.equal [ "s1" ] (Dict.keys live.uiLayout)
                    , \_ -> Expect.equal 7 model.uiZoomGen
                    ]
                    ()
        , test "entering solo is remembered, and supersedes a pending restore intent" <|
            \_ ->
                -- Otherwise a file from three restarts ago could re-open a solo
                -- view the user has already left and re-left.
                let
                    placed =
                        board [ ( "s1", 60, 70 ) ] initModelWithSession

                    model =
                        { placed | uiSoloPending = Just "other" }

                    after =
                        AU.update (SoloWindow "s1") model |> Tuple.first
                in
                Expect.all
                    [\m -> Expect.equal (Just "s1") (Win.soloKey m)
                    , \m -> Expect.equal Nothing m.uiSoloPending
                    , \m -> Expect.equal [ "s1" ] (Dict.keys m.uiLayout)
                    ]
                    after
        , test "a stored solo key attaches to the window when it finally opens" <|
            \_ ->
                -- Sessions do not auto-reopen, so the intent is the only way the
                -- flag can survive a restart: it waits, and the create consumes
                -- it. Nothing here writes Model.soloWin directly (INV3).
                let
                    -- The window has to be on the board before the intent can
                    -- attach: `soloKey` refuses a key with no window (INV2), so a
                    -- restore that raced ahead of creation degrades to canvas
                    -- view rather than to a viewport with nothing in it.
                    withIntent =
                        board [ ( "s1", 60, 70 ) ] initModelWithSession
                            |> UiLayout.applyLoaded (docOf (Just "s1") Dict.empty)

                    attached =
                        UiLayout.attachPendingSolo "s1" withIntent

                    unrelated =
                        UiLayout.attachPendingSolo "other" withIntent
                in
                Expect.all
                    [\m -> Expect.equal Nothing m.uiSoloPending
                    , \m -> Expect.equal (Just "s1") (Win.soloKey m)
                    , \m -> Expect.equal unrelated withIntent
                    ]
                    attached
        , test "the intent does not leak into a save that never used it" <|
            \_ ->
                -- Nothing is solo and the key never opened: the file must keep
                -- the intent (so a later restart can still honour it) while
                -- reporting no live solo.
                let
                    startModel =
                        UiLayout.markLoaded initModelWithSession

                    withIntent =
                        { startModel | uiSoloPending = Just "ghost" }

                    after =
                        flush withIntent
                in
                Expect.equal (Just "ghost") after.uiSoloPending
        ]


suite : Test
suite =
    describe "App.UiLayout — the ui.conf client policy (F3)"
        [ decodeSuite
        , applySuite
        , placeSuite
        , absorbSuite
        , triggerSuite
        ]
