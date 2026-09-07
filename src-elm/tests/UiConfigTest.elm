module UiConfigTest exposing (suite)

{-| The `ui.conf` schema (F3), tested where it is owned.

The properties worth pinning are the ones that keep the file from being
damaged: what goes out comes back (so no field can be "forgotten by the
encoder" — the model.conf failure mode), a corrupt document degrades to
defaults instead of throwing away the whole board, and eviction is
deterministic so the client and both backends can never disagree about what a
file contains.
-}

import Dict
import Expect
import Json.Decode as D
import Json.Encode as E
import App.UiConfig as UI
import Test exposing (Test, describe, test)


rect : Int -> Int -> Int -> UI.Entry
rect x y t =
    { x = x, y = y, w = 560, h = 640, t = t }


doc : List ( String, UI.Entry ) -> UI.Document
doc windows =
    let
        empty =
            UI.emptyDocument
    in
    { empty | windows = Dict.fromList windows }


keysIn : E.Value -> List String
keysIn value =
    case D.decodeValue (D.dict D.value) value |> Result.toMaybe of
        Just m ->
            Dict.keys m

        Nothing ->
            []


suite : Test
suite =
    describe "App/UiConfig — the ui.conf schema"
        [ describe "round trip"
            [ test "a full document survives encode → decode unchanged" <|
                \_ ->
                    let
                        base =
                            doc [ ( "s1", rect 40 60 3 ), ( "p1", rect 100 800 9 ) ]

                        original =
                            { base
                                | soloWin = Just "s1"
                                , canvasOffset = { x = -120, y = 30 }
                                , canvasScale = 1.75
                            }
                    in
                    Expect.equal (UI.decode (UI.encode original)) (Just original)
            , test "soloWin null reads back as Nothing, not as a missing key" <|
                \_ ->
                    Expect.equal
                        (UI.decode (E.object [ ( "version", E.int 1 ), ( "soloWin", E.null ) ]) |> Maybe.map .soloWin)
                        (Just Nothing)
            , test "an empty body is a valid document of defaults" <|
                \_ ->
                    -- Compared against the module's OWN empty document: "the
                    -- defaults" is one definition, not five values repeated.
                    Expect.equal (UI.decode (E.object [])) (Just UI.emptyDocument)
            , test "a key from a newer client is carried through and re-written" <|
                -- The backends already pass it through untouched; this is the
                -- OTHER writer. An older AlayaFace saving a file a newer one
                -- wrote must not eat a field it has never seen.
                \_ ->
                    let
                        stored =
                            E.object
                                [ ( "version", E.int 1 )
                                , ( "futureThing", E.list E.int [ 1, 2, 3 ] )
                                , ( "windows", E.object [ ( "s1", rectValue (rect 5 5 1) ) ] )
                                ]
                    in
                    Expect.equal
                        (UI.decode stored |> Maybe.map (UI.encode >> keysIn >> List.member "futureThing"))
                        (Just True)
            ]
        , describe "lenient decode (a bad file degrades, never deletes the good parts)"
            [ test "a bad canvasScale does not poison the windows" <|
                \_ ->
                    let
                        stored =
                            E.object
                                [ ( "version", E.int 1 )
                                , ( "canvasScale", E.string "big" )
                                , ( "windows", E.object [ ( "s1", rectValue (rect 7 9 2) ) ] )
                                ]
                    in
                    case UI.decode stored of
                        Just d ->
                            Expect.all
                                [ \_ -> Expect.equal d.canvasScale 1.0
                                , \_ -> Expect.equal (Dict.get "s1" d.windows) (Just (rect 7 9 2))
                                ]
                                ()

                        Nothing ->
                            Expect.fail "one bad field must not discard the document"
            , test "an unusable entry is dropped, its siblings survive" <|
                \_ ->
                    let
                        stored =
                            E.object
                                [ ( "windows"
                                  , E.object
                                        [ ( "good", rectValue (rect 1 2 3) )
                                        , ( "no-h", E.object [ ( "x", E.int 0 ), ( "y", E.int 0 ), ( "w", E.int 560 ) ] )
                                        , ( "zero", rectValue { x = 0, y = 0, w = 0, h = 640, t = 1 } )
                                        , ( "negative", rectValue { x = 0, y = 0, w = -4, h = 640, t = 1 } )
                                        , ( "floaty", E.object [ ( "x", E.float 1.5 ), ( "y", E.int 0 ), ( "w", E.int 560 ), ( "h", E.int 640 ), ( "t", E.int 1 ) ] )
                                        ]
                                  )
                                ]
                    in
                    case UI.decode stored of
                        Just d ->
                            Expect.all
                                [ \_ -> Expect.equal (Dict.keys d.windows) [ "good" ]
                                , \_ -> Expect.equal (Dict.get "good" d.windows) (Just (rect 1 2 3))
                                ]
                                ()

                        Nothing ->
                            Expect.fail "one bad entry must not discard the document"
            , test "a non-object body is no document at all" <|
                \_ ->
                    Expect.equal
                        (List.filterMap UI.decode [ E.int 7, E.string "x", E.list E.int [ 1 ], E.null ])
                        []
            , test "an entry with no t counts as the oldest" <|
                -- Otherwise a hand-written entry would be unevictable forever.
                \_ ->
                    let
                        stored =
                            E.object
                                [ ( "windows"
                                  , E.object
                                        [ ( "a", E.object [ ( "x", E.int 0 ), ( "y", E.int 0 ), ( "w", E.int 560 ), ( "h", E.int 640 ) ] ) ]
                                  )
                                ]
                    in
                    Expect.equal
                        (UI.decode stored |> Maybe.map (\d -> Dict.get "a" d.windows))
                        (Just (Just { x = 0, y = 0, w = 560, h = 640, t = 0 }))
            ]
        , describe "eviction (the store outlives the windows, so it must be bounded)"
            [ test "under the cap nothing is dropped" <|
                \_ ->
                    Expect.equal
                        (UI.evict (doc [ ( "a", rect 0 0 1 ) ]) [])
                        ( doc [ ( "a", rect 0 0 1 ) ], 0 )
            , test "exactly at the cap keeps everything" <|
                \_ ->
                    let
                        n =
                            UI.maxStoredWindows

                        windows =
                            List.range 1 n |> List.map (\i -> ( "w" ++ String.fromInt i, rect 0 0 i ))

                        ( out, dropped ) =
                            UI.evict (doc windows) []
                    in
                    Expect.equal ( dropped, Dict.size out.windows ) ( 0, n )
            , test "one over the cap drops the OLDEST touched closed window" <|
                \_ ->
                    let
                        n =
                            UI.maxStoredWindows

                        windows =
                            (List.range 1 (n - 1) |> List.map (\i -> ( "w" ++ String.fromInt i, rect 0 0 (i + 10) )))
                                ++ [ ( "stale", rect 0 0 1 ), ( "fresh", rect 0 0 (n + 100) ) ]

                        ( out, dropped ) =
                            UI.evict (doc windows) []
                    in
                    Expect.all
                        [ \_ -> Expect.equal dropped 1
                        , \_ -> Expect.equal (Dict.member "stale" out.windows) False
                        , \_ -> Expect.equal (Dict.member "fresh" out.windows) True
                        ]
                        ()
            , test "an OPEN window is never evicted, however stale" <|
                -- Dropping the rect of a window on screen would make the next
                -- save describe a board that no longer matches the screen.
                \_ ->
                    let
                        n =
                            UI.maxStoredWindows

                        windows =
                            (List.range 1 n |> List.map (\i -> ( "w" ++ String.fromInt i, rect 0 0 (i + 10) )))
                                ++ [ ( "open-stale", rect 3 4 1 ) ]

                        ( out, dropped ) =
                            UI.evict (doc windows) [ "open-stale" ]
                    in
                    Expect.all
                        [ \_ -> Expect.equal dropped 1
                        , \_ -> Expect.equal (Dict.get "open-stale" out.windows) (Just (rect 3 4 1))
                        , \_ -> Expect.equal (Dict.member "w1" out.windows) False
                        ]
                        ()
            , test "eviction is deterministic: same input, same survivors" <|
                -- Both backends read the same file, and a Dict's iteration order
                -- is not a fact about the layout. The key breaks ties, ascending.
                \_ ->
                    let
                        n =
                            UI.maxStoredWindows

                        -- All three share the oldest touch, so the tie-break is
                        -- the only thing that can decide — and exactly one entry
                        -- is over the cap, so a non-deterministic rule would
                        -- show up as a different survivor set per run.
                        old =
                            [ ( "zz", rect 0 0 1 ), ( "mm", rect 0 0 1 ), ( "bb", rect 0 0 1 ) ]

                        fresh =
                            List.range 1 (n - 2) |> List.map (\i -> ( "a" ++ String.fromInt i, rect 0 0 (i + 10) ))

                        ( out, dropped ) =
                            UI.evict (doc (fresh ++ old)) []

                        ( again, _ ) =
                            UI.evict (doc (List.reverse fresh ++ List.reverse old)) []
                    in
                    Expect.all
                        [ \_ -> Expect.equal dropped 1
                        , \_ -> Expect.equal (Dict.member "bb" out.windows) False
                        , \_ -> Expect.equal (Dict.member "mm" out.windows) True
                        , \_ -> Expect.equal (Dict.member "zz" out.windows) True
                        , \_ -> Expect.equal (Dict.keys again.windows) (Dict.keys out.windows)
                        ]
                        ()
            ]
        , describe "the constants duplicated by design"
            [ test "version 1, cap 200" <|
                -- scripts/check-backend-parity.sh compares these three files;
                -- pinning them here too means a rename breaks the Elm suite,
                -- not only a shell script nobody runs locally.
                \_ ->
                    Expect.equal ( UI.version, UI.maxStoredWindows ) ( 1, 200 )
            , test "the encoder writes exactly the known keys plus extras" <|
                \_ ->
                    Expect.equal
                        (UI.encode (doc []) |> keysIn)
                        [ "canvasOffset", "canvasScale", "soloWin", "version", "windows" ]
            ]
        ]


rectValue : UI.Entry -> E.Value
rectValue e =
    E.object
        [ ( "x", E.int e.x )
        , ( "y", E.int e.y )
        , ( "w", E.int e.w )
        , ( "h", E.int e.h )
        , ( "t", E.int e.t )
        ]
