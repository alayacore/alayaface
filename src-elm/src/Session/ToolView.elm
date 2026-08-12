module Session.ToolView exposing
    ( DiffLine(..)
    , diffBlocks
    , editFileDecoder
    , viewToolCall
    )

{-| Per-tool rendering for tool-call windows.

The transcript used to render every tool message as plain text
(`Html.text msg.content`). This module gives each tool its own input
display — e.g. `edit_file` becomes a red/green line diff — while the
output keeps the plain-text treatment. It is pure (no App.* dependency)
so the diff/decoder logic is unit-testable.

Input lives in `SessionState.toolCalls[id].input` (in-memory, replayed
on history replay via AF frames), so the caller passes the resolved
`Maybe ToolCall` together with the message.

Per-tool dispatch:
  * `edit_file`        → line diff: red = removed, green = added
  * `write_file`       → all lines green (new file)
  * `execute_command`  → terminal-style command block
  * `read_file`        → path header
  * `search_content`   → pattern header
  * anything else      → pretty-printed JSON fallback
-}

import Dict
import Html exposing (Html)
import Html.Attributes as Attr
import Json.Decode as D
import Json.Encode as E
import Session.Types as T


-- Diff

type DiffLine
    = Context String
    | Deleted String
    | Added String


{-| Line diff for edit_file's block-replacement semantics: old_string is
a contiguous block replaced by new_string, so unchanged lines can only
form a common prefix and/or a common suffix. Trim those (Context), then
the middle is the Deleted old lines followed by the Added new lines.
No LCS, no syntax highlighting — just red/green per line as requested.
-}
diffBlocks : String -> String -> List DiffLine
diffBlocks old new =
    let
        -- String.lines "" returns [""]; treat the empty string as no lines
        -- so a pure insertion shows only green lines, not a stray red one.
        oldLines =
            if old == "" then
                []

            else
                String.lines old

        newLines =
            if new == "" then
                []

            else
                String.lines new

        pre =
            commonPrefix oldLines newLines 0

        oldMid =
            List.drop pre oldLines

        newMid =
            List.drop pre newLines

        suf =
            commonPrefix (List.reverse oldMid) (List.reverse newMid) 0

        oldCore =
            List.take (List.length oldMid - suf) oldMid

        newCore =
            List.take (List.length newMid - suf) newMid

        tailCtx =
            List.drop (List.length oldMid - suf) oldMid
    in
    List.map Context (List.take pre oldLines)
        ++ List.map Deleted oldCore
        ++ List.map Added newCore
        ++ List.map Context tailCtx


commonPrefix : List String -> List String -> Int -> Int
commonPrefix a b n =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            if x == y then
                commonPrefix xs ys (n + 1)

            else
                n

        _ ->
            n


-- Input decoders

type alias EditFileInput =
    { path : String
    , oldString : String
    , newString : String
    }


editFileDecoder : D.Decoder EditFileInput
editFileDecoder =
    D.map3 EditFileInput
        (D.field "path" D.string)
        (D.field "old_string" D.string)
        (D.field "new_string" D.string)


writeFileDecoder : D.Decoder ( String, String )
writeFileDecoder =
    D.map2 Tuple.pair
        (D.field "path" D.string)
        (D.field "content" D.string)


-- Entry point

{-| Render one tool message window body: a per-tool input section (when
the tool call has input) followed by the plain-text output section.
Falls back to plain output text when the tool call is missing (e.g. a
legacy message or while the input is still streaming via Af deltas).
-}
viewToolCall : Maybe T.ToolCall -> T.Message -> Html msg
viewToolCall maybeTc msg =
    case maybeTc of
        Just tc ->
            Html.div [ Attr.class "tool-body" ]
                [ viewInput tc
                , viewOutput msg
                ]

        Nothing ->
            Html.div [ Attr.class "tool-body" ]
                [ viewOutput msg ]


viewInput : T.ToolCall -> Html msg
viewInput tc =
    case tc.input |> Maybe.andThen (Dict.get "raw") of
        Just raw ->
            viewToolInput tc.name raw

        Nothing ->
            Html.text ""


viewToolInput : String -> E.Value -> Html msg
viewToolInput name raw =
    case name of
        "edit_file" ->
            editFileView raw

        "write_file" ->
            writeFileView raw

        "execute_command" ->
            executeCommandView raw

        "read_file" ->
            readFileView raw

        "search_content" ->
            searchContentView raw

        _ ->
            fallbackJsonView raw


-- Per-tool input views

editFileView : E.Value -> Html msg
editFileView raw =
    case D.decodeValue editFileDecoder raw of
        Ok inp ->
            Html.div [ Attr.class "tool-input" ]
                [ Html.div [ Attr.class "tool-input-head" ]
                    [ Html.span [ Attr.class "tool-tag" ] [ Html.text "edit" ]
                    , Html.span [ Attr.class "tool-path" ] [ Html.text inp.path ]
                    ]
                , Html.div [ Attr.class "tool-diff" ]
                    (List.map diffLineHtml (diffBlocks inp.oldString inp.newString))
                ]

        Err _ ->
            fallbackJsonView raw


writeFileView : E.Value -> Html msg
writeFileView raw =
    case D.decodeValue writeFileDecoder raw of
        Ok ( path, content ) ->
            Html.div [ Attr.class "tool-input" ]
                [ Html.div [ Attr.class "tool-input-head" ]
                    [ Html.span [ Attr.class "tool-tag" ] [ Html.text "write" ]
                    , Html.span [ Attr.class "tool-path" ] [ Html.text path ]
                    ]
                , Html.div [ Attr.class "tool-diff" ]
                    (List.map diffLineHtml (List.map Added (String.lines content)))
                ]

        Err _ ->
            fallbackJsonView raw


executeCommandView : E.Value -> Html msg
executeCommandView raw =
    case D.decodeValue (D.field "command" D.string) raw of
        Ok cmd ->
            Html.div [ Attr.class "tool-input" ]
                [ Html.div [ Attr.class "tool-input-head" ]
                    [ Html.span [ Attr.class "tool-tag" ] [ Html.text "command" ]
                    ]
                , Html.div [ Attr.class "tool-cmd" ] [ Html.text cmd ]
                ]

        Err _ ->
            fallbackJsonView raw


readFileView : E.Value -> Html msg
readFileView raw =
    case D.decodeValue (D.field "path" D.string) raw of
        Ok path ->
            Html.div [ Attr.class "tool-input" ]
                [ Html.div [ Attr.class "tool-input-head" ]
                    [ Html.span [ Attr.class "tool-tag" ] [ Html.text "read" ]
                    , Html.span [ Attr.class "tool-path" ] [ Html.text path ]
                    ]
                ]

        Err _ ->
            fallbackJsonView raw


searchContentView : E.Value -> Html msg
searchContentView raw =
    case D.decodeValue (D.field "pattern" D.string) raw of
        Ok pattern ->
            Html.div [ Attr.class "tool-input" ]
                [ Html.div [ Attr.class "tool-input-head" ]
                    [ Html.span [ Attr.class "tool-tag" ] [ Html.text "search" ]
                    , Html.span [ Attr.class "tool-pattern" ] [ Html.text pattern ]
                    ]
                ]

        Err _ ->
            fallbackJsonView raw


fallbackJsonView : E.Value -> Html msg
fallbackJsonView raw =
    Html.div [ Attr.class "tool-input" ]
        [ Html.pre [ Attr.class "tool-fallback" ]
            [ Html.text (E.encode 2 raw) ]
        ]


-- Diff line rendering (red = deleted, green = added, no highlighting)

diffLineHtml : DiffLine -> Html msg
diffLineHtml line =
    case line of
        Context s ->
            Html.div [ Attr.class "tool-diff-line tool-diff-ctx" ]
                [ Html.span [ Attr.class "tool-diff-marker" ] [ Html.text " " ]
                , Html.text s
                ]

        Deleted s ->
            Html.div [ Attr.class "tool-diff-line tool-diff-del" ]
                [ Html.span [ Attr.class "tool-diff-marker" ] [ Html.text "−" ]
                , Html.text s
                ]

        Added s ->
            Html.div [ Attr.class "tool-diff-line tool-diff-add" ]
                [ Html.span [ Attr.class "tool-diff-marker" ] [ Html.text "+" ]
                , Html.text s
                ]


-- Output section: plain text (pre-wrap preserves the existing newlines;
-- errors get a red tint). No markdown, no code fences.

viewOutput : T.Message -> Html msg
viewOutput msg =
    if String.isEmpty (String.trim msg.content) then
        Html.text ""

    else
        Html.div
            [ Attr.class
                ("tool-output"
                    ++ (if msg.isError then " tool-output-error" else "")
                )
            ]
            [ Html.text msg.content ]
