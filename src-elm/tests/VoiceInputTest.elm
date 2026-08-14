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


lastMsgText : AT.Model -> String
lastMsgText model =
    case List.reverse (session model).messages of
        msg :: _ ->
            msg.content

        [] ->
            ""


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


asrConfigValue : Bool -> String -> List E.Value -> String -> E.Value
asrConfigValue ok active profiles error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "active", E.string active )
        , ( "profiles", E.list identity profiles )
        , ( "error", E.string error )
        ]


asrProfileValue : String -> String -> String -> String -> String -> String -> String -> E.Value
asrProfileValue id name protocol url apiKey model language =
    E.object
        [ ( "id", E.string id )
        , ( "name", E.string name )
        , ( "protocol", E.string protocol )
        , ( "url", E.string url )
        , ( "api_key", E.string apiKey )
        , ( "model", E.string model )
        , ( "language", E.string language )
        ]


tests : Test
tests =
    describe "voice input"
        [ describe "VoiceInput toggle"
            [ test "first click starts recording (voiceActive)" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.VoiceInput initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (session mm).voiceActive
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
                        ]
                        m2
            , test "success with empty text appends 'No speech recognized' to the display" <|
                \_ ->
                    let
                        m1 =
                            updateSession (\s -> { s | asrBusy = True }) initModelWithSession

                        ( m2, _ ) =
                            AU.update (AT.AsrResult (voiceResult True "" "")) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal "No speech recognized" (lastMsgText mm)
                        , \mm -> Expect.equal Nothing mm.pendingVoiceInsert
                        ]
                        m2
            , test "failure appends the reason to the display and clears busy state" <|
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
                        , \mm -> Expect.equal "Voice input failed: connection refused" (lastMsgText mm)
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
            [ test "resets recording state and appends the mic error to the display" <|
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
                        , \mm -> Expect.equal "Voice input error: permission denied" (lastMsgText mm)
                        ]
                        m2
            ]
        , describe "ASR config overlay (profile list + form)"
            [ test "open loads the config list" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.OpenAsrConfig initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.asrConfigEditor.show
                        , \mm -> Expect.equal True mm.asrConfigEditor.loading
                        , \mm -> Expect.equal False mm.asrConfigEditor.inForm
                        , \mm -> Expect.equal False mm.showGlobalMenu
                        ]
                        m
            , test "get result fills the profile list" <|
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
                                    (asrConfigValue True "p2"
                                        [ asrProfileValue "p1" "Local whisper" "transcriptions" "http://127.0.0.1:8080/v1/audio/transcriptions" "" "whisper-1" "auto"
                                        , asrProfileValue "p2" "MiMo" "chat_completions" "https://api.xiaomimimo.com/v1/chat/completions" "k" "mimo-v2.5-asr" "zh"
                                        ]
                                        ""
                                    )
                                )
                                m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal "p2" mm.asrConfig.active
                        , \mm -> Expect.equal 2 (List.length mm.asrConfig.profiles)
                        , \mm -> Expect.equal False mm.asrConfigEditor.loading
                        ]
                        m2
            , test "Add enters the form for a new profile" <|
                \_ ->
                    let
                        ( m, _ ) =
                            AU.update AT.AsrConfigAdd initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.asrConfigEditor.inForm
                        , \mm -> Expect.equal Nothing mm.asrConfigEditor.editingId
                        ]
                        m
            , test "Edit enters the form pre-filled from the profile" <|
                \_ ->
                    let
                        m1 =
                            { initModelWithSession
                                | asrConfig =
                                    { active = "p1"
                                    , profiles =
                                        [ { id = "p1", name = "MiMo", protocol = "chat_completions", url = "https://api.xiaomimimo.com/v1/chat/completions", apiKey = "k", model = "mimo-v2.5-asr", language = "zh" } ]
                                    }
                            }

                        ( m2, _ ) =
                            AU.update (AT.AsrConfigEdit "p1") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.asrConfigEditor.inForm
                        , \mm -> Expect.equal (Just "p1") mm.asrConfigEditor.editingId
                        , \mm -> Expect.equal "MiMo" mm.asrConfigEditor.name
                        , \mm -> Expect.equal "chat_completions" mm.asrConfigEditor.protocol
                        , \mm -> Expect.equal "zh" mm.asrConfigEditor.language
                        ]
                        m2
            , test "Back returns from the form to the list" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, inForm = True, url = "http://x" }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update AT.AsrConfigBack m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.asrConfigEditor.show
                        , \mm -> Expect.equal False mm.asrConfigEditor.inForm
                        ]
                        m2
            , test "close is blocked while in the form" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, inForm = True }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update AT.CloseAsrConfig m1
                    in
                    Expect.equal True m2.asrConfigEditor.show
            , test "save without a URL is rejected" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, inForm = True, url = "" }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update AT.AsrConfigSave m1
                    in
                    Expect.equal (Just "Endpoint URL is required (full address, e.g. http://127.0.0.1:8080/v1/audio/transcriptions)") m2.asrConfigEditor.error
            , test "save marks syncing" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, inForm = True, name = "Local", url = "http://127.0.0.1:8080/v1/audio/transcriptions" }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update AT.AsrConfigSave m1
                    in
                    Expect.equal True m2.asrConfigEditor.syncing
            , test "delete arms confirm then deletes" <|
                \_ ->
                    let
                        m1 =
                            { initModelWithSession
                                | asrConfig =
                                    { active = "p1"
                                    , profiles =
                                        [ { id = "p1", name = "A", protocol = "transcriptions", url = "http://a", apiKey = "", model = "whisper-1", language = "auto" }
                                        , { id = "p2", name = "B", protocol = "transcriptions", url = "http://b", apiKey = "", model = "whisper-1", language = "auto" }
                                        ]
                                    }
                            }

                        ( m2, _ ) =
                            AU.update (AT.AsrConfigDelete "p2") m1

                        ( m3, _ ) =
                            AU.update AT.AsrConfigDeleteConfirm m2
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just "p2") m2.asrConfigEditor.confirmDelete
                        , \mm -> Expect.equal True m3.asrConfigEditor.syncing
                        ]
                        m3
            , test "sync result returns to the list with the new profiles" <|
                \_ ->
                    let
                        ed =
                            let
                                base =
                                    AT.emptyAsrConfigEditor
                            in
                            { base | show = True, inForm = True, syncing = True }

                        m1 =
                            { initModelWithSession | asrConfigEditor = ed }

                        ( m2, _ ) =
                            AU.update
                                (AT.AsrConfigSyncResult
                                    (asrConfigValue True "p1"
                                        [ asrProfileValue "p1" "MiMo" "chat_completions" "https://api.xiaomimimo.com/v1/chat/completions" "k" "mimo-v2.5-asr" "zh" ]
                                        ""
                                    )
                                )
                                m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.asrConfigEditor.show
                        , \mm -> Expect.equal False mm.asrConfigEditor.inForm
                        , \mm -> Expect.equal "p1" mm.asrConfig.active
                        , \mm -> Expect.equal 1 (List.length mm.asrConfig.profiles)
                        ]
                        m2
            ]
        ]
