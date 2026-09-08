module FilePickerTest exposing (suite)

{-| Message-level behavioral tests for the file-picker flow (the only
flow that had no behavioral coverage — just the fs routing tests).
They drive App.Update with the same wire payloads the ports deliver
and assert the picker state / staged media / scan arming, so a
refactor of the update glue cannot silently change the flow.
-}

import Dict
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import App.Update as AU
import App.Types as AT
import Session.Types as T
import TestHelpers exposing (initModelWithSession)


fpOf : AT.Model -> T.FilePickerState
fpOf model =
    case Dict.get "s1" model.sessions of
        Just s ->
            s.filePicker

        Nothing ->
            T.emptyFilePicker


stagedOf : AT.Model -> List T.StagedMedia
stagedOf model =
    case Dict.get "s1" model.sessions of
        Just s ->
            s.staged

        Nothing ->
            []


setFp : T.FilePickerState -> AT.Model -> AT.Model
setFp fp model =
    { model | sessions = Dict.update "s1" (Maybe.map (\s -> { s | filePicker = fp })) model.sessions }


-- Apply a picker-state update to the fixture model.
withFp : (T.FilePickerState -> T.FilePickerState) -> AT.Model -> AT.Model
withFp f model =
    setFp (f (fpOf model)) model


-- A picker already opened onto /home/u with a populated listing.
pickerAtHome : AT.Model
pickerAtHome =
    let
        base =
            T.emptyFilePicker
    in
    setFp
        { base
            | show = True
            , mode = T.Local
            , input = "/home/u/"
            , filter = ""
            , entries =
                [ T.DirEntry "Docs" True
                , T.DirEntry "photo.png" False
                , T.DirEntry "notes.txt" False
                ]
            , dir = "/home/u"
            , baseDir = "/home/u"
            , selected = 0
            , loading = False
            , error = Nothing
        }
        initModelWithSession


-- Wire payload builders (field names match the backend decoders).

listResult : String -> Bool -> List ( String, Bool ) -> String -> E.Value
listResult reqId ok entries error =
    E.object
        [ ( "reqId", E.string reqId )
        , ( "ok", E.bool ok )
        , ( "entries"
          , E.list
                (\( n, d ) -> E.object [ ( "name", E.string n ), ( "isDir", E.bool d ) ])
                entries
          )
        , ( "error", E.string error )
        ]


homeResult : Bool -> String -> String -> E.Value
homeResult ok home error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "home", E.string home )
        , ( "error", E.string error )
        ]


resolveResult : Bool -> String -> Bool -> Bool -> String -> E.Value
resolveResult ok resolved exists isDir error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "resolved", E.string resolved )
        , ( "exists", E.bool exists )
        , ( "isDir", E.bool isDir )
        , ( "error", E.string error )
        ]


readUriResult : Bool -> String -> String -> E.Value
readUriResult ok uri error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "uri", E.string uri )
        , ( "error", E.string error )
        ]


suite : Test
suite =
    describe "file picker flow"
        [ describe "open + home"
            [ test "OpenFilePicker resets and shows the picker" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.OpenFilePicker initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).show True
                        , \mm -> Expect.equal (fpOf mm).mode T.Local
                        , \mm -> Expect.equal (fpOf mm).input ""
                        , \mm -> Expect.equal (fpOf mm).filter ""
                        , \mm -> Expect.equal (fpOf mm).selected 0
                        , \mm -> Expect.equal (fpOf mm).loading True
                        ]
                        m
            , test "home result seeds the base dir and lists it" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update AT.OpenFilePicker initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.FsHomeDirResult (homeResult True "/home/u" "")) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).baseDir "/home/u"
                        , \mm -> Expect.equal (fpOf mm).dir "/home/u"
                        , \mm -> Expect.equal (fpOf mm).input "/home/u/"
                        , \mm -> Expect.equal (fpOf mm).filter ""
                        , \mm -> Expect.equal (fpOf mm).loading True
                        , \mm -> Expect.equal mm.homeDir "/home/u"
                        , \mm -> Expect.equal mm.fsReqCounter 1
                        -- The rebuild is armed to start after this listing.
                        , \mm -> Expect.equal mm.planMetaScan.pending True
                        ]
                        m2
            , test "home listing populates entries (and starts the rebuild)" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update AT.OpenFilePicker initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.FsHomeDirResult (homeResult True "/home/u" "")) m1

                        ( m3, _ ) =
                            AU.update
                                (AT.FsListDirResult (listResult "fs-1" True [ ( "Docs", True ), ( "readme.md", False ), ( "..", True ) ] ""))
                                m2
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).entries [ T.DirEntry "Docs" True, T.DirEntry "readme.md" False ]
                        , \mm -> Expect.equal (fpOf mm).loading False
                        , \mm -> Expect.equal (fpOf mm).error Nothing
                        -- The scan began with its own listing request.
                        , \mm -> Expect.equal mm.planMetaScan.pending False
                        , \mm -> Expect.equal mm.planMetaScan.scanReqId (Just "fs-2")
                        , \mm -> Expect.equal mm.fsReqCounter 2
                        ]
                        m3
            , test "failed home listing surfaces the error instead of hanging" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            AU.update AT.OpenFilePicker initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.FsHomeDirResult (homeResult True "/home/u" "")) m1

                        ( m3, _ ) =
                            AU.update (AT.FsListDirResult (listResult "fs-1" False [] "backend exploded")) m2
                    in
                    Expect.equal ( (fpOf m3).loading, (fpOf m3).error )
                        ( False, Just "backend exploded" )
            ]
        , describe "input parsing"
            [ test "typing a path splits dir + filter and clamps selection" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update (AT.SetFilePickerInput "/home/u/doc")
                                (withFp (\fp -> { fp | selected = 7 }) pickerAtHome)
                    in
                    -- "doc" filters the listing down to "Docs", so the
                    -- out-of-range selection clamps to the last match (0).
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).input "/home/u/doc"
                        , \mm -> Expect.equal (fpOf mm).filter "doc"
                        , \mm -> Expect.equal (fpOf mm).selected 0
                        ]
                        m
            , test "url-mode input is stored verbatim" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update (AT.SetFilePickerInput "https://example.com/a.png")
                                (withFp (\fp -> { fp | mode = T.Url }) pickerAtHome)
                    in
                    Expect.equal (fpOf m).input "https://example.com/a.png"
            ]
        , describe "navigation"
            [ test "clicking a directory appends it to the path" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update (AT.FilePickerNavigateDir "Docs") pickerAtHome
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).input "/home/u/Docs/"
                        , \mm -> Expect.equal (fpOf mm).filter ""
                        , \mm -> Expect.equal (fpOf mm).loading True
                        ]
                        m
            , test "confirming a directory behaves like clicking it" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.FilePickerConfirmItem pickerAtHome
                    in
                    Expect.equal (fpOf m).input "/home/u/Docs/"
            , test "navigate up goes to the parent directory" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.FilePickerNavigateUp
                                (withFp
                                    (\fp ->
                                        { fp
                                            | dir = "/home/u/Docs"
                                            , input = "/home/u/Docs/"
                                            , baseDir = "/home/u"
                                        }
                                    )
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).input "/home/u/"
                        , \mm -> Expect.equal (fpOf mm).filter ""
                        , \mm -> Expect.equal (fpOf mm).loading True
                        ]
                        m
            ]
        , describe "picking files"
            [ test "confirming a file starts the data-uri read" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.FilePickerConfirmItem
                                (withFp (\fp -> { fp | selected = 1 }) pickerAtHome)
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).loading True
                        , \mm -> Expect.equal (fpOf mm).pendingFileName "photo.png"
                        , \mm -> Expect.equal (fpOf mm).show True
                        ]
                        m
            , test "picking by index works from clicks too" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update (AT.FilePickerPickItem 2) pickerAtHome
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).selected 2
                        , \mm -> Expect.equal (fpOf mm).pendingFileName "notes.txt"
                        , \mm -> Expect.equal (fpOf mm).loading True
                        ]
                        m
            , test "a successful read stages the media and closes the picker" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update
                                (AT.FsReadFileResult (readUriResult True "data:image/png;base64,AAA" ""))
                                (withFp
                                    (\fp -> { fp | selected = 1, loading = True, pendingFileName = "photo.png" })
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (stagedOf mm)
                            [ { id = "file-0", mediaType = T.Image, uri = "data:image/png;base64,AAA", name = Just "photo.png" } ]
                        , \mm -> Expect.equal (fpOf mm).show False
                        , \mm -> Expect.equal (fpOf mm).input ""
                        , \mm -> Expect.equal (fpOf mm).pendingFileName ""
                        ]
                        m
            , test "a failed read keeps the picker open with the error" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update
                                (AT.FsReadFileResult (readUriResult False "" "file too large"))
                                (withFp
                                    (\fp -> { fp | selected = 1, loading = True, pendingFileName = "photo.png" })
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).loading False
                        , \mm -> Expect.equal (fpOf mm).error (Just "file too large")
                        , \mm -> Expect.equal (fpOf mm).show True
                        , \mm -> Expect.equal (stagedOf mm) []
                        ]
                        m
            ]
        , describe "url mode"
            [ test "confirming a URL stages it as a media item" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.ConfirmFilePickerUrl
                                (withFp
                                    (\fp ->
                                        { fp
                                            | mode = T.Url
                                            , input = "https://example.com/photo.png"
                                        }
                                    )
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (stagedOf mm)
                            [ { id = "url-0"
                              , mediaType = T.Image
                              , uri = "https://example.com/photo.png"
                              , name = Just "https://example.com/photo.png"
                              }
                            ]
                        , \mm -> Expect.equal (fpOf mm).show False
                        , \mm -> Expect.equal (fpOf mm).input ""
                        ]
                        m
            , test "mode toggle local→url saves the local path" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.FilePickerToggleMode
                                (withFp
                                    (\fp ->
                                        { fp
                                            | mode = T.Local
                                            , input = "/home/u/a.txt"
                                        }
                                    )
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).mode T.Url
                        , \mm -> Expect.equal (fpOf mm).input ""
                        , \mm -> Expect.equal (fpOf mm).savedLocalPath "/home/u/a.txt"
                        ]
                        m
            , test "mode toggle url→local restores the local path" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.FilePickerToggleMode
                                (withFp
                                    (\fp ->
                                        { fp
                                            | mode = T.Url
                                            , input = "https://example.com/b.png"
                                            , savedLocalPath = "/home/u/a.txt"
                                        }
                                    )
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).mode T.Local
                        , \mm -> Expect.equal (fpOf mm).input "/home/u/a.txt"
                        , \mm -> Expect.equal (fpOf mm).savedUrlPath "https://example.com/b.png"
                        ]
                        m
            ]
        , describe "resolve results"
            [ test "a resolved dir is recorded and listed when it changed" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update
                                (AT.FsResolvePathResult (resolveResult True "/home/u/Docs" True True ""))
                                pickerAtHome
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).dir "/home/u/Docs"
                        , \mm -> Expect.equal (fpOf mm).selected 0
                        , \mm -> Expect.equal mm.fsReqCounter 1
                        ]
                        m
            , test "resolving to the current dir updates nothing but still allocates" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update
                                (AT.FsResolvePathResult (resolveResult True "/home/u" True True ""))
                                pickerAtHome
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).dir "/home/u"
                        , \mm -> Expect.equal mm.fsReqCounter 1
                        ]
                        m
            , test "a non-directory path surfaces the reason" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update
                                (AT.FsResolvePathResult (resolveResult True "/home/u/photo.png" True False ""))
                                pickerAtHome
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).loading False
                        , \mm -> Expect.equal (fpOf mm).error (Just "Not a directory: /home/u/photo.png")
                        ]
                        m
            , test "a failed resolve surfaces the backend error" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update
                                (AT.FsResolvePathResult (resolveResult False "" False False "No such file"))
                                pickerAtHome
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).loading False
                        , \mm -> Expect.equal (fpOf mm).error (Just "No such file")
                        ]
                        m
            ]
        , describe "close"
            [ test "CloseFilePicker hides it and clears saved paths" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.CloseFilePicker
                                (withFp
                                    (\fp ->
                                        { fp
                                            | savedLocalPath = "/home/u/a.txt"
                                            , savedUrlPath = "https://example.com/b.png"
                                        }
                                    )
                                    pickerAtHome
                                )
                    in
                    Expect.all
                        [ \mm -> Expect.equal (fpOf mm).show False
                        , \mm -> Expect.equal (fpOf mm).savedLocalPath ""
                        , \mm -> Expect.equal (fpOf mm).savedUrlPath ""
                        ]
                        m
            ]
        ]
