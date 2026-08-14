module VoiceInputTest exposing (tests)

import Dict
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)
import App.Update as AU
import App.Types as AT
import Session.Types as T


{-| Voice input (ASR) update tests: recording toggle on the mic button,
transcript insertion at the caret, failure surfacing, and the ASR
config overlay (endpoint URL / key / model / language).
-}


session : AT.Model -> T.SessionState
session model =
    Dict.get "s1" model.sessions |> Maybe.withDefault (T.emptySession "s1")


updateSession : (T.SessionState -> T.SessionState) -> AT.Model -> AT.Model
updateSession f model =
    { model | sessions = Dict.update "s1" (Maybe.map f) model.sessions }


voiceResult : Bool -> String -> String -> E.Value
voiceResult ok text error =
    E.object
        [ ( "sessionId", E.string "s1" )
        , ( "ok", E.bool ok )
        , ( "text", E.string text )
        , ( "error", E.string error )
        ]


cursorResult : String -> Int -> E.Value
cursorResult sid pos =
    E.object
        [ ( "sessionId", E.string sid )
        , ( "pos", E.int pos )
        ]


asrConfigValue : Bool -> String -> String -> String -> String -> String -> E.Value
asrConfigValue ok url apiKey model language error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "url", E.string url )
        , ( "api_key", E.string apiKey )
        , ( "model", E.string model )
        , ( "language", E.string language )
        , ( "error", E.string error )
        ]


tests : Test
tests =
    describe "voice input"
        [ describe "VoiceInput toggle"
            [ test "first click starts recording (voiceActive, Listening…)" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.VoiceInput initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (session mm).voiceActive
                        , \mm -> Expect.equal "Listening…" (session mm).statusMsg
                        , \mm -> Expect.equal False (session mm).asrBusy
                        ]
                        m
            , test "second click stops and transcribes (asrBusy)" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | voiceActive = True }) initModelWithSession

                        ( m2, _ ) =
                            AU.update AT.VoiceInput m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (session mm).voiceActive
                        , \mm -> Expect.equal True (session mm).asrBusy
                        , \mm -> Expect.equal "Transcribing…" (session mm).statusMsg
                        ]
                        m2
            , test "clicks while asrBusy are ignored" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | asrBusy = True, voiceActive = False }) initModelWithSession

                        ( m2, _ ) =
                            AU.update AT.VoiceInput m1
                    in
                    Expect.equal True (session m2).asrBusy
            ]
        , describe "AsrResult"
            [ test "success with text parks the transcript and asks for the caret" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | asrBusy = True }) initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.AsrResult (voiceResult True "hello" "")) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (session mm).asrBusy
                        , \mm -> Expect.equal (Just { sessionId = "s1", text = "hello" }) mm.pendingVoiceInsert
                        , \mm -> Expect.equal "" (session mm).statusMsg
                        ]
                        m2
            , test "success with empty text reports no speech" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | asrBusy = True }) initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.AsrResult (voiceResult True "" "")) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal "No speech recognized" (session mm).statusMsg
                        , \mm -> Expect.equal Nothing mm.pendingVoiceInsert
                        ]
                        m2
            , test "failure surfaces the reason and clears busy state" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | asrBusy = True, voiceActive = True }) initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.AsrResult (voiceResult False "" "connection refused")) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (session mm).asrBusy
                        , \mm -> Expect.equal False (session mm).voiceActive
                        , \mm -> Expect.equal "Voice input failed: connection refused" (session mm).statusMsg
                        ]
                        m2
            ]
        , describe "cursor insertion"
            [ test "transcript is inserted exactly at the caret" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | input = "hello world" }) initModelWithSession
                                |> \mm -> { mm | pendingVoiceInsert = Just { sessionId = "s1", text = " dear" } }

                        ( m2, _ ) =
                            AU.update (AT.CursorPosResult (cursorResult "s1" 5)) m1
                    in
                    Expect.equal "hello dear world" (session m2).input
            , test "inserting at the end appends" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | input = "hello" }) initModelWithSession
                                |> \mm -> { mm | pendingVoiceInsert = Just { sessionId = "s1", text = " world" } }

                        ( m2, _ ) =
                            AU.update (AT.CursorPosResult (cursorResult "s1" 5)) m1
                    in
                    Expect.equal "hello world" (session m2).input
            , test "a caret result for another session is ignored" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | input = "hello" }) initModelWithSession
                                |> \mm -> { mm | pendingVoiceInsert = Just { sessionId = "s1", text = "X" } }

                        ( m2, _ ) =
                            AU.update (AT.CursorPosResult (cursorResult "other" 0)) m1
                    in
                    Expect.equal "hello" (session m2).input
            , test "insertion clears the pending slot" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | input = "" }) initModelWithSession
                                |> \mm -> { mm | pendingVoiceInsert = Just { sessionId = "s1", text = "hi" } }

                        ( m2, _ ) =
                            AU.update (AT.CursorPosResult (cursorResult "s1" 0)) m1
                    in
                    Expect.equal Nothing m2.pendingVoiceInsert
            ]
        , describe "VoiceError"
            [ test "resets recording state and surfaces the mic error" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | voiceActive = True }) initModelWithSession

                        ( m2, _ ) =
                            AU.update
                                (AT.VoiceError
                                    (E.object
                                        [ ( "sessionId", E.string "s1" )
                                        , ( "message", E.string "permission denied" )
                                        ]
                                    )
                                )
                                m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (session mm).voiceActive
                        , \mm -> Expect.equal "Voice input error: permission denied" (session mm).statusMsg
                        ]
                        m2
            ]
        , describe "ASR config overlay"
            [ test "open loads the config" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.OpenAsrConfig initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.asrConfigEditor.show
                        , \mm -> Expect.equal True mm.asrConfigEditor.loading
                        , \mm -> Expect.equal False mm.showGlobalMenu
                        ]
                        m
            , test "save without a URL is rejected" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, url = "" }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update AT.AsrConfigSave m1
                    in
                    Expect.equal (Just "Endpoint URL is required (local: http://127.0.0.1:PORT/v1, remote: https://…/v1)") m2.asrConfigEditor.error
            , test "save with a URL syncs and marks syncing" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, url = "http://127.0.0.1:8080/v1" }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update AT.AsrConfigSave m1
                    in
                    Expect.equal True m2.asrConfigEditor.syncing
            , test "get result fills the editor" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, loading = True }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update
                                (AT.AsrConfigGetResult
                                    (asrConfigValue True "http://127.0.0.1:8080/v1" "k" "whisper-1" "zh" "")
                                )
                                m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal "http://127.0.0.1:8080/v1" mm.asrConfigEditor.url
                        , \mm -> Expect.equal "zh" mm.asrConfigEditor.language
                        , \mm -> Expect.equal False mm.asrConfigEditor.loading
                        , \mm -> Expect.equal "http://127.0.0.1:8080/v1" mm.asrConfig.url
                        ]
                        m2
            , test "sync result closes the editor on success" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, syncing = True }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update
                                (AT.AsrConfigSyncResult
                                    (asrConfigValue True "http://127.0.0.1:8080/v1" "k" "whisper-1" "auto" "")
                                )
                                m1
                    in
                    Expect.equal False m2.asrConfigEditor.show
            ]
        ]
