module Session.FilePicker exposing
    ( decodeDirEntry
    , parsePathInput
    , filterEntries
    , appendDirToInput
    , detectMediaType
    )

{-| Pure file-picker logic: path parsing, entry filtering, and the
"append a directory to the current input" step that the three picker
handlers (navigate, confirm, click) used to re-implement separately.

The state record itself lives in `Session.Types` (`FilePickerState`) —
this module only operates on it, which keeps the module dependency
graph acyclic (Session.Types cannot import this module).
-}

import Fuzzy
import Json.Decode as D
import Json.Encode as E
import Session.Types as T


-- ─── Entry decoding ──────────────────────────────────────────────────

decodeDirEntry : E.Value -> Maybe T.DirEntry
decodeDirEntry val =
    case D.decodeValue (D.map2 T.DirEntry (D.field "name" D.string) (D.field "isDir" D.bool)) val of
        Ok entry ->
            Just entry

        Err _ ->
            Nothing


-- ─── Filtering ───────────────────────────────────────────────────────

filterEntries : T.FilePickerState -> List T.DirEntry
filterEntries fp =
    let
        term =
            String.trim fp.filter
    in
    if String.isEmpty term then
        fp.entries

    else
        List.filter (\e -> Fuzzy.fuzzyMatch term (String.toLower e.name)) fp.entries


-- ─── Path input parsing ──────────────────────────────────────────────

-- Parse file picker input into (needsResolve, resolvePath, filterText)
-- Matches alayacore terminal adapter's navigateByPath logic.
--
-- ~             → resolve "~",          filter ""
-- ~/path        → resolve "~",          filter "path"
-- ~/dir/        → resolve "~/dir",      filter ""
-- ~/dir/sub     → resolve "~/dir",      filter "sub"
-- /abs/path     → resolve "/abs/path",  filter ""  (if ends with /)
-- /abs/foo      → resolve "/abs",       filter "foo"
-- ../rel        → resolve baseDir/..,   filter "rel"
-- foo           → no resolve,           filter "foo"  (fuzzy search)

parsePathInput : String -> String -> String -> ( Bool, String, String )
parsePathInput input currentDir baseDir =
    if String.isEmpty input then
        ( False, "", "" )

    else if String.startsWith "~" input then
        parseTildePath input

    else if String.startsWith "/" input then
        parseAbsolutePath input

    else if String.contains "/" input || input == ".." then
        parseRelativePath input baseDir

    else
        -- Plain text: no navigation, use as filter
        ( False, "", input )


parseTildePath : String -> ( Bool, String, String )
parseTildePath input =
    let
        rest =
            String.dropLeft 1 input
    in
    if rest == "" || rest == "/" then
        -- "~" or "~/" → navigate to home
        ( True, "~", "" )

    else if String.endsWith "/" rest then
        -- "~/dir/" → navigate to ~/dir
        ( True, input, "" )

    else
        -- "~/dir/file" → navigate to ~/dir, filter "file"
        let
            dirPart =
                "~/" ++ (String.join "/" (List.take (List.length (String.split "/" rest) - 1) (String.split "/" rest)))

            filePart =
                Maybe.withDefault "" (List.head (List.reverse (String.split "/" rest)))
        in
        if dirPart == "~/" then
            -- "~/file" → navigate to ~, filter "file"
            ( True, "~", filePart )
        else
            ( True, dirPart, filePart )


parseAbsolutePath : String -> ( Bool, String, String )
parseAbsolutePath input =
    let
        trimmed =
            if String.endsWith "/" input && input /= "/" then
                String.dropRight 1 input
            else
                input
    in
    if trimmed == "/" || String.endsWith "/" input then
        -- "/" or "/path/" → navigate to that dir
        ( True, trimmed, "" )

    else
        -- "/path/to/file" → navigate to /path/to, filter "file"
        let
            parts =
                String.split "/" trimmed

            filePart =
                Maybe.withDefault "" (List.head (List.reverse parts))

            dirPart =
                String.join "/" (List.take (List.length parts - 1) parts)
        in
        if dirPart == "" then
            -- "/file" → navigate to /, filter "file"
            ( True, "/", filePart )
        else
            ( True, dirPart, filePart )


parseRelativePath : String -> String -> ( Bool, String, String )
parseRelativePath input baseDir =
    if input == ".." then
        -- Navigate to parent
        ( True, baseDir ++ "/..", "" )

    else if String.endsWith "/" input then
        -- "dir/" → navigate to baseDir/dir
        ( True, baseDir ++ "/" ++ (String.dropRight 1 input), "" )

    else
        -- "dir/file" → navigate to baseDir/dir, filter "file"
        let
            filePart =
                Maybe.withDefault "" (List.head (List.reverse (String.split "/" input)))

            dirPart =
                String.join "/" (List.take (List.length (String.split "/" input) - 1) (String.split "/" input))
        in
        if dirPart == "" then
            -- "file" (shouldn't happen since input contains "/" but just in case)
            ( False, "", input )
        else
            ( True, baseDir ++ "/" ++ dirPart, filePart )


-- ─── Directory navigation ────────────────────────────────────────────

-- Append a directory name (from the file list) to the current input
-- path and update the picker state. Returns the new state plus the
-- directory path to resolve (for fsResolvePath).
--
-- Handles two shapes of input:
--   "…/prefix/"      → append "name/"           (dir at end of path)
--   "…/prefix/filter" → replace "filter" with "name/" (filter text)
appendDirToInput : T.FilePickerState -> String -> ( T.FilePickerState, String )
appendDirToInput fp name =
    let
        newInput =
            if String.endsWith "/" fp.input then
                fp.input ++ name ++ "/"

            else
                case lastIndexOf '/' fp.input of
                    Just idx ->
                        String.left (idx + 1) fp.input ++ name ++ "/"

                    Nothing ->
                        name ++ "/"

        newDir =
            if fp.dir == "" then
                name

            else
                fp.dir ++ "/" ++ name
    in
    ( { fp | input = newInput, filter = "", loading = True }, newDir )


lastIndexOf : Char -> String -> Maybe Int
lastIndexOf char str =
    lastIndexOfHelp char str 0 Nothing


lastIndexOfHelp : Char -> String -> Int -> Maybe Int -> Maybe Int
lastIndexOfHelp char str idx found =
    case String.uncons str of
        Just ( c, rest ) ->
            if c == char then
                lastIndexOfHelp char rest (idx + 1) (Just idx)

            else
                lastIndexOfHelp char rest (idx + 1) found

        Nothing ->
            found


-- ─── Media type detection ────────────────────────────────────────────

detectMediaType : String -> T.MediaType
detectMediaType name =
    let
        lower =
            String.toLower name
    in
    if
        List.any (\ext -> String.endsWith ext lower)
            [ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg" ]
    then
        T.Image

    else if List.any (\ext -> String.endsWith ext lower) [ ".mp3", ".wav", ".ogg", ".flac", ".m4a" ] then
        T.Audio

    else if List.any (\ext -> String.endsWith ext lower) [ ".mp4", ".webm", ".mov", ".avi", ".mkv" ] then
        T.Video

    else
        T.Document
