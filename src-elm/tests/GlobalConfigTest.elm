module GlobalConfigTest exposing (tests)

{-| `App.GlobalConfig`: the cross-preset overlay (`global.conf`).

One field, and the tests are about the two things that field can go wrong on:
what gets refused before a write (the backend would silently normalize a bad value
into the default, so "0" becoming 8 is a change the user did not ask for), and what
an unreadable reply must NOT do — clear the form, or claim a limit the file never
had.

`defaultRecursionLimit` is asserted against the literal 8 because that number is
triplicated across Go, Rust and here; `scripts/check-backend-parity.sh` compares
the three, and this is the client's side of that pin.
-}

import App.GlobalConfig as GC exposing (Action(..))
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)


blank : GC.Editor
blank =
    GC.emptyEditor


reply : Bool -> Int -> String -> E.Value
reply ok limit error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "recursion_limit", E.int limit )
        , ( "error", E.string error )
        ]


kinds : List GC.Action -> List String
kinds actions =
    List.map
        (\action ->
            case action of
                GC.Get ->
                    "Get"

                GC.Sync n ->
                    "Sync " ++ String.fromInt n
        )
        actions


tests : Test
tests =
    describe "App.GlobalConfig — the recursion limit"
        [ test "the default is the value both backends fall back to" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal 8 GC.defaultRecursionLimit
                    , \_ -> Expect.equal 8 GC.emptyDocument.recursionLimit
                    ]
                    ()
        , test "open marks loading and asks for the file" <|
            \_ ->
                let
                    ( ed, actions ) =
                        GC.open
                in
                Expect.all
                    [ \p -> Expect.equal True p.show
                    , \p -> Expect.equal True p.loading
                    , \p -> Expect.equal "" p.input
                    , \_ -> Expect.equal [ "Get" ] (kinds actions)
                    ]
                    ed
        , test "close refuses while a sync is in flight" <|
            \_ ->
                let
                    wedged =
                        { blank | show = True, syncing = True, input = "12" }
                in
                GC.close wedged |> Expect.equal wedged
        , test "close from a quiet overlay clears it" <|
            \_ ->
                GC.close { blank | show = True, input = "12", error = Just "x" }
                    |> Expect.equal GC.emptyEditor
        , test "typing clears the error line" <|
            \_ ->
                { blank | error = Just "stale" } |> GC.setInput "7" |> .error |> Expect.equal Nothing
        , test "a plain number is written as-is" <|
            \_ ->
                GC.save { blank | input = "8" }
                    |> Tuple.second
                    |> kinds
                    |> Expect.equal [ "Sync 8" ]
        , test "surrounding whitespace is not an error" <|
            \_ ->
                GC.save { blank | input = "  12  " }
                    |> Tuple.second
                    |> kinds
                    |> Expect.equal [ "Sync 12" ]
        , test "a non-number is refused with the parse message, and nothing is written" <|
            \_ ->
                -- The backend would answer with its own default; a silent 8 here
                -- would look like the user's "eight" took effect.
                let
                    ( ed, actions ) =
                        GC.save { blank | input = "eight" }
                in
                Expect.all
                    [ \_ -> Expect.equal [] actions
                    , \p -> Expect.equal (Just "Recursion limit must be a positive integer") p.error
                    , \p -> Expect.equal False p.syncing
                    ]
                    ed
        , test "an empty field is refused the same way, not as zero" <|
            \_ ->
                GC.save { blank | input = "" }
                    |> Tuple.second
                    |> Expect.equal []
        , test "zero is refused with the range message" <|
            \_ ->
                -- 0 means "absent = default" to the backend, which is a different
                -- number from the one typed.
                let
                    ( ed, actions ) =
                        GC.save { blank | input = "0" }
                in
                Expect.all
                    [ \_ -> Expect.equal [] actions
                    , \p -> Expect.equal (Just "Recursion limit must be >= 1") p.error
                    ]
                    ed
        , test "a negative number gets the range message, not the parse one" <|
            \_ ->
                GC.save { blank | input = "-3" }
                    |> Tuple.first
                    |> .error
                    |> Expect.equal (Just "Recursion limit must be >= 1")
        , test "a good read sets the document AND the text shown" <|
            \_ ->
                -- Both, because the field is edited as text: setting only the
                -- document would leave the box empty next to a real limit.
                let
                    ( doc, ed ) =
                        GC.adoptGet (reply True 12 "") ( GC.emptyDocument, { blank | loading = True } )
                            |> Maybe.withDefault ( GC.emptyDocument, blank )
                in
                Expect.all
                    [ \_ -> Expect.equal 12 doc.recursionLimit
                    , \p -> Expect.equal "12" p.input
                    , \p -> Expect.equal False p.loading
                    , \p -> Expect.equal Nothing p.error
                    ]
                    ed
        , test "a failed read keeps the document and stops loading" <|
            \_ ->
                let
                    ( doc, ed ) =
                        GC.adoptGet (reply False 99 "boom") (GC.Document 5, { blank | loading = True })
                            |> Maybe.withDefault ( GC.Document 0, blank )
                in
                Expect.all
                    [ \_ -> Expect.equal 5 doc.recursionLimit
                    , \p -> Expect.equal (Just "boom") p.error
                    , \p -> Expect.equal False p.loading
                    , \p -> Expect.equal "" p.input
                    ]
                    ed
        , test "an unreadable read reply changes nothing rather than guessing" <|
            \_ ->
                GC.adoptGet (E.object []) ( GC.Document 5, { blank | loading = True } )
                    |> Expect.equal Nothing
        , test "a good save adopts the EFFECTIVE limit and closes the overlay" <|
            \_ ->
                -- The reply is the normalized value; adopting it is what makes a
                -- backend adjustment visible immediately instead of at the next open.
                let
                    ( doc, ed ) =
                        GC.adoptSync (reply True 7 "") ( GC.Document 3, { blank | syncing = True, input = "7" } )
                            |> Maybe.withDefault ( GC.Document 0, blank )
                in
                Expect.all
                    [ \_ -> Expect.equal 7 doc.recursionLimit
                    , \p -> Expect.equal GC.emptyEditor p
                    ]
                    ed
        , test "a failed save unsticks syncing and keeps the typed text" <|
            \_ ->
                -- Keeping the input is what makes the retry possible; the user
                -- should not have to retype a value that may already be right.
                let
                    ( doc, ed ) =
                        GC.adoptSync (reply False 0 "disk full") ( GC.Document 3, { blank | syncing = True, input = "abc" } )
                            |> Maybe.withDefault ( GC.Document 0, blank )
                in
                Expect.all
                    [ \_ -> Expect.equal 3 doc.recursionLimit
                    , \p -> Expect.equal False p.syncing
                    , \p -> Expect.equal (Just "disk full") p.error
                    , \p -> Expect.equal "abc" p.input
                    ]
                    ed
        , test "an unreadable save reply leaves syncing set rather than guessing" <|
            \_ ->
                GC.adoptSync (E.object []) ( GC.Document 3, { blank | syncing = True } )
                    |> Expect.equal Nothing
        ]
