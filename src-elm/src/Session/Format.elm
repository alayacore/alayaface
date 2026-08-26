module Session.Format exposing (formatTokens, formatTokenUsage, formatSpeed)

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


{-| Speed readout for the session bar, mirroring the terminal adapter's
status-bar speed segment: the latest completed step's end-to-end
throughput, with TTFT when the core reported it.

    12.5 0      -> "12.5 tok/s"
    12.5 1200   -> "12.5 tok/s · ttft 1.2s"
    0    1200   -> ""        (no step with output tokens yet)

`step_tps` / `ttft_ms` come from SM task frames (adapter-guide); they are
absent (0) until the first step with output tokens completes.
-}
formatSpeed : Float -> Int -> String
formatSpeed stepTps ttftMs =
    if stepTps <= 0 then
        ""

    else if ttftMs > 0 then
        oneDecimal stepTps ++ " tok/s · ttft " ++ oneDecimal (toFloat ttftMs / 1000) ++ "s"

    else
        oneDecimal stepTps ++ " tok/s"


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
