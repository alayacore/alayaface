module Plan.Detect exposing
    ( extractPlanJson
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
