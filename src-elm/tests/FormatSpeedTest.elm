module FormatSpeedTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Session.Format as F


tests : Test
tests =
    describe "Session.Format.formatSpeed"
        [ test "empty until a step with output tokens completes" <|
            \_ ->
                Expect.equal "" (F.formatSpeed 0 1200)
        , test "tok/s only when no TTFT is reported" <|
            \_ ->
                Expect.equal "12.5 tok/s" (F.formatSpeed 12.5 0)
        , test "tok/s with TTFT when both are reported" <|
            \_ ->
                Expect.equal "12.5 tok/s · ttft 1.2s" (F.formatSpeed 12.5 1200)
        , test "TTFT below a second renders with a leading zero" <|
            \_ ->
                Expect.equal "42.0 tok/s · ttft 0.3s" (F.formatSpeed 42 300)
        , test "integer tok/s keeps one decimal place" <|
            \_ ->
                Expect.equal "7.0 tok/s" (F.formatSpeed 7 0)
        ]
