module PendingEventsTest exposing (suite)

{-| H1: the `pendingEvents` buffer bound.

Frames the backend broadcasts for a session this client never created are
buffered in case the session appears a moment later. Before the cap that was an
unbounded `Dict String (List Value)`: with the Go backend, any other tab or SSH
client opening sessions makes this page accumulate frames for keys it will
never drain, for the lifetime of the tab. These tests pin the bound, the
drop-OLDEST direction (the replay needs the NEWEST state), and the one-warning
rule.

The buffer lives in `Session/Events.elm`, with the routing that fills it. Only
the model half is asserted here: `Session.Events` returns the warning as
`Action` data, and `elm-explorations/test` has no way to open a `Cmd` — which
is the reason the data shape exists.
-}

import Dict
import Expect
import Json.Decode as D
import Json.Encode as E
import Set
import App.Types as AT
import Session.Events as SE
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


frame : Int -> E.Value
frame n =
    E.object [ ( "session_id", E.string "ghost" ), ( "n", E.int n ) ]


feed : Int -> Int -> AT.Model -> AT.Model
feed from to model =
    List.foldl
        (\n m ->
            SE.bufferPendingEvent m "ghost" (frame n) |> Tuple.first
        )
        model
        (List.range from to)


keptNumbers : AT.Model -> List Int
keptNumbers model =
    Dict.get "ghost" model.pendingEvents
        |> Maybe.withDefault []
        |> List.filterMap (\v -> D.decodeValue (D.field "n" D.int) v |> Result.toMaybe)


suite : Test
suite =
    describe "pendingEvents cap (H1)"
        [ test "below the cap nothing is dropped and nothing is logged" <|
            \_ ->
                let
                    m =
                        feed 1 (SE.pendingEventsCap - 1) initModelWithSession
                in
                Expect.all
                    [ \_ -> Expect.equal (List.length (keptNumbers m)) (SE.pendingEventsCap - 1)
                    , \_ -> Expect.equal (Set.member "ghost" m.pendingOverflow) False
                    ]
                    ()
        , test "the cap holds, exactly" <|
            \_ ->
                let
                    m =
                        feed 1 (SE.pendingEventsCap * 3) initModelWithSession
                in
                Expect.equal (List.length (keptNumbers m)) SE.pendingEventsCap
        , test "the NEWEST frames survive (drop oldest)" <|
                \_ ->
                    -- Replaying a session start out of the buffer only helps if
                    -- what is left is where the session IS now: the tail, not
                    -- the head.
                    let
                        total =
                            SE.pendingEventsCap + 100

                        m =
                            feed 1 total initModelWithSession

                        kept =
                            keptNumbers m
                    in
                    Expect.all
                        [ \_ -> Expect.equal (List.length kept) SE.pendingEventsCap
                        , \_ -> Expect.equal (List.head kept) (Just 101)
                        , \_ -> Expect.equal (List.head (List.reverse kept)) (Just total)
                        ]
                        ()
        , test "one overflow warning per session key, not one per frame" <|
                \_ ->
                    -- `pendingOverflow` IS the warning record: the Cmd fires
                    -- exactly when a key is added to it, so a key that overflows
                    -- 300 times past the cap still logs once.
                    let
                        first =
                            feed 1 (SE.pendingEventsCap + 1) initModelWithSession

                        later =
                            feed (SE.pendingEventsCap + 2) (SE.pendingEventsCap + 300) first
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Set.member "ghost" first.pendingOverflow) True
                        , \_ -> Expect.equal (Set.member "ghost" later.pendingOverflow) True
                        , \_ -> Expect.equal (Set.size later.pendingOverflow) 1
                        ]
                        ()
        , test "keys are independent" <|
                \_ ->
                    let
                        m =
                            List.foldl
                                (\( key, n ) acc ->
                                    Tuple.first (SE.bufferPendingEvent acc key (E.object [ ( "n", E.int n ) ]))
                                )
                                initModelWithSession
                                [ ( "a", 1 ), ( "a", 2 ), ( "b", 3 ) ]
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Dict.get "a" m.pendingEvents |> Maybe.map List.length) (Just 2)
                        , \_ -> Expect.equal (Dict.get "b" m.pendingEvents |> Maybe.map List.length) (Just 1)
                        , \_ -> Expect.equal Set.empty m.pendingOverflow
                        ]
                        ()
        ]
