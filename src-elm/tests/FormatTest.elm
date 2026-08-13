module FormatTest exposing (suite)

import Expect
import Session.Format exposing (formatTokens, formatTokenUsage)
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Session.Format"
        [ describe "formatTokens"
            [ test "zero stays a plain integer" <|
                \_ -> Expect.equal "0" (formatTokens 0)
            , test "small counts stay plain integers" <|
                \_ -> Expect.equal "999" (formatTokens 999)
            , test "one thousand gets one decimal K" <|
                \_ -> Expect.equal "1.0K" (formatTokens 1000)
            , test "4096 -> 4.1K" <|
                \_ -> Expect.equal "4.1K" (formatTokens 4096)
            , test "decimal rounding at the tenth" <|
                \_ -> Expect.equal "4.2K" (formatTokens 4199)
            , test "trailing zero in the tenth is kept" <|
                \_ -> Expect.equal "4.0K" (formatTokens 4000)
            , test "one million gets one decimal M" <|
                \_ -> Expect.equal "1.0M" (formatTokens 1000000)
            , test "1.5M" <|
                \_ -> Expect.equal "1.5M" (formatTokens 1500000)
            ]
        , describe "formatTokenUsage"
            [ test "no data at all renders empty (view hides it)" <|
                \_ -> Expect.equal "" (formatTokenUsage 0 0)
            , test "unknown limit shows only the used count" <|
                \_ -> Expect.equal "4.1K" (formatTokenUsage 4096 0)
            , test "full readout with used, limit and percentage" <|
                \_ -> Expect.equal "4.1K/8.2K 50.0%" (formatTokenUsage 4096 8192)
            , test "small percentage keeps one decimal" <|
                \_ -> Expect.equal "4.0K/1.0M 0.4%" (formatTokenUsage 4000 1000000)
            , test "100 percent renders 100.0%" <|
                \_ -> Expect.equal "8.2K/8.2K 100.0%" (formatTokenUsage 8192 8192)
            , test "over-limit usage is shown honestly" <|
                \_ -> Expect.equal "9.0K/8.2K 109.9%" (formatTokenUsage 9000 8192)
            ]
        ]
