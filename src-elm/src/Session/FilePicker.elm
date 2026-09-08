module Session.FilePicker exposing
    ( decodeDirEntry
    , filterEntries
    , detectMediaType
    , Op(..)
    , openPicker
    , setInput
    , navigateDir
    , navigateUp
    , pickAt
    , toggleMode
    , closePicker
    )

{-| Pure file-picker logic (P-series): entry decoding, filtering,
path parsing, and the update transitions of the picker state machine.

Two layers:

  * helpers — entry decoding / fuzzy filtering / media detection, used
    by the views and the result handlers;
  * transitions — the user-action update glue (open, typing, directory
    navigation, confirm/pick, mode toggle, close). Each returns the
    new state plus an `Op` describing the fs request the caller should
    issue. App/Update's picker arms are delegations over these; the
    async result handlers (home / listing / resolve / read) stay in
    App/Update because they route the shared fs reqIds and allocate
    new ones.

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


-- ─── Update transitions ──────────────────────────────────────────────

{-| The fs request a transition wants the caller to issue. Ports are
mapped by the caller (App/Update.fpCmd) — the module stays pure.
-}
type Op
    = None
    | FetchHome
    -- ^ fs_home_dir (no args).
    | Resolve String
    -- ^ fs_resolve_path for the directory path.
    | ReadDataUri String
    -- ^ fs_read_file_data_uri for the picked file's full path.


{-| Open the picker: reset to a fresh local listing and resolve the
home directory (the caller then focuses the input).
-}
openPicker : T.FilePickerState -> ( T.FilePickerState, Op )
openPicker fp =
    ( { fp
        | show = True
        , mode = T.Local
        , input = ""
        , filter = ""
        , selected = 0
        , loading = True
      }
    , FetchHome
    )


{-| The input changed. URL mode stores it verbatim; local mode parses
it into a directory part + filter text, resolving when the path
changed. The selection is clamped to the filtered listing so a
shrunken list never leaves the cursor past the last entry.
-}
setInput : String -> T.FilePickerState -> ( T.FilePickerState, Op )
setInput val fp =
    if fp.mode == T.Url then
        -- URL mode: just update input, no path parsing
        ( { fp | input = val }, None )

    else
        -- If input was cleared (select-all + delete, etc.), restore to
        -- current directory path
        let
            safeVal =
                if val == "" then
                    "/"
                else
                    val

            ( needsResolve, resolvePath, filterText ) =
                parsePathInput safeVal fp.dir fp.baseDir

            op =
                if needsResolve then
                    Resolve resolvePath

                else
                    None

            preview =
                { fp | input = safeVal, filter = filterText }

            filteredLen =
                List.length (filterEntries preview)

            clampedIdx =
                if fp.selected >= filteredLen then
                    max 0 (filteredLen - 1)

                else
                    fp.selected
        in
        ( { fp | input = safeVal, filter = filterText, selected = clampedIdx }, op )


{-| A directory from the list was clicked: append it to the path and
resolve the new directory.
-}
navigateDir : String -> T.FilePickerState -> ( T.FilePickerState, Op )
navigateDir name fp =
    let
        ( fp1, newDir ) =
            appendDirToInput fp name
    in
    ( fp1, Resolve newDir )


{-| The up button: go to the parent of the current directory. A no-op
when no directory/base is known yet.
-}
navigateUp : T.FilePickerState -> ( T.FilePickerState, Op )
navigateUp fp =
    if fp.dir /= "" && fp.baseDir /= "" then
        let
            cleanPath =
                if String.endsWith "/" fp.dir then
                    String.dropRight 1 fp.dir

                else
                    fp.dir

            parts =
                String.split "/" cleanPath

            parentDir =
                case List.reverse parts of
                    _ :: rest ->
                        String.join "/" (List.reverse rest)

                    [] ->
                        "/"
        in
        ( { fp | loading = True, input = parentDir ++ "/", filter = "" }, Resolve parentDir )

    else
        ( fp, None )


{-| Confirm/pick an entry by its index in the FILTERED list (Confirm
passes fp.selected; a click passes the clicked index — one function,
two entry points). A directory navigates into it; a file starts the
data-uri read that stages it as media.
-}
pickAt : Int -> T.FilePickerState -> ( T.FilePickerState, Op )
pickAt idx fp =
    case List.head (List.drop idx (filterEntries fp)) of
        Just entry ->
            if entry.isDir then
                let
                    ( fp1, newDir ) =
                        appendDirToInput fp entry.name
                in
                ( { fp1 | selected = idx }, Resolve newDir )

            else
                let
                    fullPath =
                        if fp.dir == "" then
                            entry.name

                        else
                            fp.dir ++ "/" ++ entry.name
                in
                ( { fp | loading = True, selected = idx, pendingFileName = entry.name }
                , ReadDataUri fullPath
                )

        Nothing ->
            ( fp, None )


{-| Switch local ⇄ URL, keeping each mode's path so toggling back
restores it (savedLocalPath / savedUrlPath).
-}
toggleMode : T.FilePickerState -> T.FilePickerState
toggleMode fp =
    let
        ( newMode, newInput ) =
            case fp.mode of
                T.Local ->
                    -- Switching FROM local TO URL: restore the saved URL
                    ( T.Url, fp.savedUrlPath )

                T.Url ->
                    -- Switching FROM URL TO local: restore the saved
                    -- local path (or fall back to the current dir).
                    let
                        restoredLocal =
                            if fp.savedLocalPath /= "" then
                                fp.savedLocalPath

                            else if fp.dir /= "" then
                                fp.dir ++ "/"

                            else
                                ""
                    in
                    ( T.Local, restoredLocal )

        ( savedLocal, savedUrl ) =
            case fp.mode of
                T.Local ->
                    ( fp.input, "" )

                T.Url ->
                    ( "", fp.input )
    in
    { fp
        | mode = newMode
        , input = newInput
        , filter = ""
        , savedLocalPath = savedLocal
        , savedUrlPath = savedUrl
    }


{-| Close the picker and drop the saved cross-mode paths (they only
make sense while the overlay stays open).
-}
closePicker : T.FilePickerState -> T.FilePickerState
closePicker fp =
    { fp | show = False, savedLocalPath = "", savedUrlPath = "" }


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
