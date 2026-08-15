module PresetReorderTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import App.Update


tests : Test
tests =
    describe "App.Update.movePreset (Preset Manager drag-to-reorder)"
        [ test "moves an item down" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 0 2 [ "a", "b", "c" ])
                    [ "b", "c", "a" ]
        , test "moves an item up" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 2 0 [ "a", "b", "c" ])
                    [ "c", "a", "b" ]
        , test "moves an item one step down" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 0 1 [ "a", "b", "c" ])
                    [ "b", "a", "c" ]
        , test "moves an item one step up" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 1 0 [ "a", "b", "c" ])
                    [ "b", "a", "c" ]
        , test "dropping onto its own position is a no-op" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 1 1 [ "a", "b", "c" ])
                    [ "a", "b", "c" ]
        , test "single-element and empty lists are untouched" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 0 0 [ "x" ])
                    [ "x" ]
        , test "out-of-range indices are clamped" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 99 0 [ "a", "b", "c" ])
                    [ "c", "a", "b" ]
        , test "moving a middle item to the end" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 1 2 [ "a", "b", "c" ])
                    [ "a", "c", "b" ]
        , test "four-item shuffle" <|
            \_ ->
                Expect.equal
                    (App.Update.movePreset 3 1 [ "a", "b", "c", "d" ])
                    [ "a", "d", "b", "c" ]
        ]
