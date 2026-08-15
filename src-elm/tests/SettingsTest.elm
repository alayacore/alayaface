module SettingsTest exposing (tests)

{-| Pins the System prompt textarea sizing: its height follows the
content (auto-grow) with a MAXIMUM, never a fixed height — a short
prompt stays small and a long one (the seeded plan-mode contract)
scrolls instead of taking over the page.
-}

import Expect
import Overlay.Settings as S
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Overlay/Settings systemPromptRows"
        [ test "empty prompt uses the minimum height (4 rows)" <|
            \_ ->
                S.systemPromptRows ""
                    |> Expect.equal 4
        , test "short prompt stays at the minimum height" <|
            \_ ->
                S.systemPromptRows "You are a helpful assistant."
                    |> Expect.equal 4
        , test "row count follows the content within the bounds" <|
            \_ ->
                S.systemPromptRows (String.repeat 6 "line\n" ++ "end")
                    |> Expect.equal 8
        , test "a one-line prompt stays at the minimum height even when it wraps" <|
            \_ ->
                S.systemPromptRows "a very long single line that wraps"
                    |> Expect.equal 4
        , test "long prompt is capped at the maximum height (20 rows)" <|
            \_ ->
                S.systemPromptRows (String.repeat 50 "line\n")
                    |> Expect.equal 20
        ]
