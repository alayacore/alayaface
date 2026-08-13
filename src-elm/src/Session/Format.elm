module Session.Format exposing (formatTokens, formatTokenUsage)

{-| Token-count formatting for the session bar readout.

`formatTokens` compacts a raw token count into human units:

    0         -> "0"
    999       -> "999"
    1000      -> "1.0K"
    4096      -> "4.1K"
    1000000   -> "1.0M"

`formatTokenUsage` renders the readout "used/limit pct%" (e.g.
"4.1K/8.2K 50.0%"). Until the limit is known (no SM "model" frame has
arrived yet) only the used count is shown, and with no data at all the
readout is empty (the view hides it).
-}


formatTokens : Int -> String
formatTokens n =
    if n >= 1000000 then
        oneDecimal (toFloat n / 1000000) ++ "M"

    else if n >= 1000 then
        oneDecimal (toFloat n / 1000) ++ "K"

    else
        String.fromInt n


formatTokenUsage : Int -> Int -> String
formatTokenUsage used limit =
    if limit <= 0 then
        if used <= 0 then
            ""

        else
            formatTokens used

    else
        formatTokens used
            ++ "/"
            ++ formatTokens limit
            ++ " "
            ++ oneDecimal (toFloat used * 100 / toFloat limit)
            ++ "%"


{-| One decimal place, always shown: 4.096 -> "4.1", 4.0 -> "4.0",
0.4 -> "0.4" (String.fromFloat would drop the trailing ".0").
-}
oneDecimal : Float -> String
oneDecimal v =
    let
        scaled =
            round (v * 10)

        whole =
            scaled // 10

        frac =
            abs (modBy 10 scaled)
    in
    String.fromInt whole ++ "." ++ String.fromInt frac
