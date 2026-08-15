module AttachmentDropTest exposing (suite)

import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import App.Update
import App.Types as AT
import Dict
import Session.Types as T
import TestHelpers exposing (initModelWithSession)


suite : Test
suite =
    describe "Attachment drag-drop onto the prompt input (DroppedFiles)"
        [ test "stages dropped files with detected media type and name" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "sessionId", E.string "s1" )
                            , ( "files"
                              , E.list identity
                                    [ E.object [ ( "name", E.string "photo.png" ), ( "uri", E.string "data:image/png;base64,xxx" ) ]
                                    , E.object [ ( "name", E.string "voice.mp3" ), ( "uri", E.string "data:audio/mpeg;base64,yyy" ) ]
                                    , E.object [ ( "name", E.string "notes.txt" ), ( "uri", E.string "data:text/plain;base64,zzz" ) ]
                                    ]
                              )
                            , ( "errors", E.list E.string [] )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.DroppedFiles raw) model
                in
                case Dict.get "s1" updated.sessions of
                    Just s ->
                        Expect.equal
                            (List.map (\m -> ( m.id, T.mediaTypeToString m.mediaType, m.name )) s.staged)
                            [ ( "drop-0", "image", Just "photo.png" )
                            , ( "drop-1", "audio", Just "voice.mp3" )
                            , ( "drop-2", "document", Just "notes.txt" )
                            ]

                    Nothing ->
                        Expect.fail "session s1 missing"
        , test "staged ids continue after existing staged items" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    modelWithStaged =
                        { model
                            | sessions =
                                Dict.update "s1"
                                    (\maybe ->
                                        Maybe.map
                                            (\s ->
                                                { s
                                                    | staged =
                                                        [ { id = "url-0"
                                                          , mediaType = T.Document
                                                          , uri = "https://example.com/a.pdf"
                                                          , name = Just "a.pdf"
                                                          }
                                                        ]
                                                }
                                            )
                                            maybe
                                    )
                                    model.sessions
                        }

                    raw =
                        E.object
                            [ ( "sessionId", E.string "s1" )
                            , ( "files"
                              , E.list identity
                                    [ E.object [ ( "name", E.string "shot.jpg" ), ( "uri", E.string "data:image/jpeg;base64,qqq" ) ]
                                    ]
                              )
                            , ( "errors", E.list E.string [] )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.DroppedFiles raw) modelWithStaged
                in
                case Dict.get "s1" updated.sessions of
                    Just s ->
                        Expect.equal
                            (List.map .id s.staged)
                            [ "url-0", "drop-1" ]

                    Nothing ->
                        Expect.fail "session s1 missing"
        , test "drop errors surface as an error message while good files still stage" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "sessionId", E.string "s1" )
                            , ( "files"
                              , E.list identity
                                    [ E.object [ ( "name", E.string "ok.png" ), ( "uri", E.string "data:image/png;base64,ok" ) ]
                                    ]
                              )
                            , ( "errors"
                              , E.list E.string
                                    [ "huge.bin (128 MiB) exceeds the 64 MiB limit" ]
                              )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.DroppedFiles raw) model
                in
                case Dict.get "s1" updated.sessions of
                    Just s ->
                        Expect.all
                            [ \ss -> Expect.equal (List.length ss.staged) 1
                            , \ss -> Expect.equal (List.length ss.messages) 1
                            , \ss ->
                                case List.head ss.messages of
                                    Just m ->
                                        Expect.equal
                                            ( m.isError, m.content )
                                            ( True, "Drop failed: huge.bin (128 MiB) exceeds the 64 MiB limit" )

                                    Nothing ->
                                        Expect.fail "error message missing"
                            ]
                            s

                    Nothing ->
                        Expect.fail "session s1 missing"
        , test "unknown session is ignored" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "sessionId", E.string "nope" )
                            , ( "files", E.list identity [] )
                            , ( "errors", E.list E.string [] )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.DroppedFiles raw) model
                in
                Expect.equal updated.sessions model.sessions
        ]
