module Conf exposing
    ( Block
    , blocks
    , quote
    , rawLine
    , stringLine
    , toJsonText
    , toString
    )

{-| The key-value config text format AlayaCore reads.

Two files this client WRITES use it — `model.conf` and `mcp.conf` — so the
rules live here instead of in each schema module. That is not tidiness:
before this module existed the MCP writer quoted values with JSON escaping
(Go's `json.Marshal` escapes `&`, `<` and `>` as `\u0026`/`\u003c`/`\u003e`)
while the core's `config.unescapeQuoted` only knows `\\`, `\"`, `\n` and
`\r` — so a URL with a query string was corrupted on save, differently on
each backend. There is exactly one escaping rule, and it is AlayaCore's.

Format, matching `internal/config`:

  * one `key: value` line per field;
  * strings double-quoted, with `\\`, `\"`, `\n`, `\r` escaped;
  * numbers and booleans written literally;
  * slices/maps written as compact JSON (`["a"]`, `{"K":"v"}`);
  * `---` on its own line separates blocks;
  * `#` at the start of a line is a comment;
  * the first colon separates the key from the value, so a JSON value may
    contain colons.

-}

import Json.Decode as D
import Json.Encode as E


{-| One `---`-separated block: keys in file order, each with the value text
exactly as written (quotes included), so a schema module can decide whether
it holds a string, raw JSON, or something to carry through untouched.
-}
type alias Block =
    List ( String, String )


{-| Split a config file into blocks.

Mirrors AlayaCore's `ParseKeyValueBlocks`: CRLF is normalised to LF, then the
file splits on the exact `"\n---\n"` separator (a `---` with trailing spaces
does not split, which is also what the core does). Inside a block, blank lines
and `#` comments are skipped, and a line without a colon is ignored rather
than failing the whole file — a hand-edited config must still open in the
editor.
-}
blocks : String -> List Block
blocks text =
    text
        |> String.replace "\r\n" "\n"
        |> String.split "\n---\n"
        |> List.map blockLines
        |> List.filter (not << List.isEmpty)


blockLines : String -> Block
blockLines block =
    block
        |> String.split "\n"
        |> List.filterMap line


line : String -> Maybe ( String, String )
line raw =
    let
        trimmed =
            String.trim raw
    in
    if String.isEmpty trimmed || String.startsWith "#" trimmed then
        Nothing

    else
        case String.indexes ":" trimmed |> List.head of
            Just i ->
                Just
                    ( String.trim (String.left i trimmed)
                    , String.trim (String.dropLeft (i + 1) trimmed)
                    )

            Nothing ->
                Nothing


{-| Quote and escape a string the way AlayaCore's `config.EscapeQuoted` does —
backslashes first, then the quote, then the two control characters it knows.
Order matters: escaping a newline after the backslash pass is what keeps the
inserted `\` from being doubled.
-}
quote : String -> String
quote value =
    "\""
        ++ (value
                |> String.replace "\\" "\\\\"
                |> String.replace "\"" "\\\""
                |> String.replace "\n" "\\n"
                |> String.replace "\r" "\\r"
           )
        ++ "\""


{-| One `key: "value"` line.
-}
stringLine : String -> String -> String
stringLine key value =
    key ++ ": " ++ quote value


{-| One `key: <json>` line for a field that travels as raw JSON text
(`reasoning_N`, `args`, `env`, `auth-scopes`, and carried-through extras).

Empty text and JSON `null` yield `Nothing` ("not stated"). A JSON string is
re-quoted with the conf escaping, so it round-trips through a parser that knows
only the four escapes; numbers, booleans, arrays and objects are already the
literal value.

Unparsable text is written VERBATIM rather than dropped. It cannot reach here
from a validated draft, but a value carried through from a hand-edited file can
be invalid — and silently deleting it is the failure mode this whole layer
exists to prevent. The core reports the parse error on the line instead.
-}
rawLine : String -> String -> Maybe String
rawLine key text =
    if String.isEmpty (String.trim text) then
        Nothing

    else
        case D.decodeString (D.nullable D.value) text of
            Ok Nothing ->
                Nothing

            Ok (Just value) ->
                case D.decodeValue D.string value of
                    Ok string ->
                        Just (stringLine key string)

                    Err _ ->
                        Just (key ++ ": " ++ E.encode 0 value)

            Err _ ->
                Just (key ++ ": " ++ String.trim text)


{-| The decoded value of a raw config value: double quotes are stripped and
the four escapes are applied; anything else (single quotes, a bare number, a
JSON array) is returned as written.

Unknown escapes keep both characters, exactly like the core's
`unescapeQuoted` — guessing at them would rewrite a user's value.
-}
toString : String -> String
toString raw =
    let
        trimmed =
            String.trim raw
    in
    if String.length trimmed >= 2 && String.startsWith "\"" trimmed && String.endsWith "\"" trimmed then
        unescape (String.slice 1 -1 trimmed)

    else if String.length trimmed >= 2 && String.startsWith "'" trimmed && String.endsWith "'" trimmed then
        String.slice 1 -1 trimmed

    else
        trimmed


unescape : String -> String
unescape text =
    unescapeHelp (String.toList text) []


unescapeHelp : List Char -> List Char -> String
unescapeHelp chars acc =
    case chars of
        [] ->
            String.fromList (List.reverse acc)

        '\\' :: next :: rest ->
            case next of
                '\\' ->
                    unescapeHelp rest ('\\' :: acc)

                '"' ->
                    unescapeHelp rest ('"' :: acc)

                'n' ->
                    unescapeHelp rest ('\n' :: acc)

                'r' ->
                    unescapeHelp rest ('\r' :: acc)

                _ ->
                    -- Unknown escape: keep both characters, as the core does.
                    unescapeHelp rest (next :: '\\' :: acc)

        c :: rest ->
            unescapeHelp rest (c :: acc)


{-| Normalise JSON text to its compact form, so a value read from a hand-edited
file is re-emitted the way the core would write it. Unparsable text is left
alone (the editor shows it and `draftProblems` refuses to save it).
-}
toJsonText : String -> String
toJsonText raw =
    let
        -- The core unquotes the config value BEFORE handing it to the JSON
        -- decoder for a slice/map field, so `args: "[]"` is an empty array,
        -- not a JSON string.
        value =
            String.trim (toString raw)
    in
    if String.isEmpty value then
        ""

    else
        case D.decodeString D.value value of
            Ok parsed ->
                E.encode 0 parsed

            Err _ ->
                value
