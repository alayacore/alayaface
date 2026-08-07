module Plan.Detect exposing
    ( extractPlanJson
    , hasPlanTypeMarker
    , isPlanMessage
    )

{-| Detect a plan JSON document inside assistant message text.

The primary capture path: the model answers a planning request with a
fenced ```json code block. This module finds the FIRST ```json fence
pair in the text and returns the content between them (trimmed).

Rules:
  - fence opening line must be exactly ```json (case-insensitive,
    surrounding whitespace tolerated) — other languages are skipped;
  - the FIRST json fence pair wins; earlier non-json fences are skipped;
  - CRLF is tolerated (trailing \r on the fence line is trimmed);
  - content is trimmed; an empty block returns Nothing.
-}

import Plan.Types as PT


{-| Whether the text (the content of a ```json block) carries the AlayaFace
plan marker (`"type": "alayaface-plan"`). Only such blocks get a Create
Plan offer — an ordinary ```json code sample in a normal chat (no marker)
never triggers the button.

Lenient by design: the marker is read TEXTUALLY (locate the `"type"` key
and compare its string value) instead of requiring the whole document to
parse. Models routinely emit plan JSON that is slightly invalid — e.g.
raw newlines inside a long string (JSON forbids them unescaped) — and
such a plan must still be RECOGNIZED so the framework can repair it or
report the parse error, instead of silently dropping the message (no
link, no window, no explanation). Only an exact key+value pair counts.
-}
hasPlanTypeMarker : String -> Bool
hasPlanTypeMarker text =
    case typeValue text of
        Just v ->
            v == PT.planTypeMarker

        Nothing ->
            False


{-| The string value of the first `"type"` key in the text (if any).
Textual scan: find `"type"`, then `:`, then the next quoted string.
Whitespace between `:` and the value is tolerated; already-valid JSON is
not required (that is the point).
-}
typeValue : String -> Maybe String
typeValue text =
    case String.indexes "\"type\"" text |> List.head of
        Nothing ->
            Nothing

        Just keyStart ->
            let
                afterKey =
                    String.dropLeft (keyStart + 6) text
            in
            case String.indexes ":" afterKey |> List.head of
                Nothing ->
                    Nothing

                Just colonIdx ->
                    let
                        afterColon =
                            String.dropLeft (colonIdx + 1) afterKey
                    in
                    case String.indexes "\"" afterColon |> List.head of
                        Nothing ->
                            Nothing

                        Just quoteIdx ->
                            let
                                raw =
                                    String.dropLeft (quoteIdx + 1) afterColon
                            in
                            case String.indexes "\"" raw |> List.head of
                                Nothing ->
                                    Nothing

                                Just endIdx ->
                                    Just (String.left endIdx raw)


{-| Whether a full assistant message content is a detected plan message
(fenced ```json block + explicit type marker). Shared by the auto-create
detection and the status-bar rendering so the "plan index" (which plan
of this session a message is) is counted with the same predicate.
-}
isPlanMessage : String -> Bool
isPlanMessage content =
    case extractPlanJson content of
        Just raw ->
            hasPlanTypeMarker raw

        Nothing ->
            False

extractPlanJson : String -> Maybe String
extractPlanJson text =
    let
        fences =
            String.indexes "```" text
    in
    findJsonBlock fences text


findJsonBlock : List Int -> String -> Maybe String
findJsonBlock fences text =
    case fences of
        [] ->
            Nothing

        start :: rest ->
            case fenceLanguage text start of
                Just "json" ->
                    -- find the closing fence after start
                    case List.filter (\i -> i > start) rest of
                        [] ->
                            Nothing

                        end :: _ ->
                            let
                                content =
                                    contentBetween text start end
                            in
                            if String.isEmpty (String.trim content) then
                                Nothing

                            else
                                Just (String.trim content)

                _ ->
                    findJsonBlock rest text


{-| Language tag of the fence opening at index `start` (the position of
```). Returns Nothing for a closing fence (```\n) or unknown languages.
-}
fenceLanguage : String -> Int -> Maybe String
fenceLanguage text start =
    let
        afterFence =
            String.dropLeft (start + 3) text

        lineLen =
            case String.indexes "\n" afterFence of
                [] ->
                    String.length afterFence

                first :: _ ->
                    first
    in
    if lineLen == 0 then
        Nothing

    else
        let
            lang =
                String.left lineLen afterFence |> String.trim
        in
        if String.isEmpty lang then
            Nothing

        else
            Just (String.toLower lang)


{-| Content between fence open (start) and close (end), skipping the
fence-opening line. If the opening line has no newline (unclosed), the
content is empty.
-}
contentBetween : String -> Int -> Int -> String
contentBetween text start end =
    let
        afterFence =
            String.dropLeft (start + 3) text

        lineEnd =
            case String.indexes "\n" afterFence of
                [] ->
                    -1

                first :: _ ->
                    first
    in
    if lineEnd < 0 then
        ""

    else
        let
            contentStart =
                start + 3 + lineEnd + 1
        in
        if contentStart >= end then
            ""

        else
            String.slice contentStart end text
