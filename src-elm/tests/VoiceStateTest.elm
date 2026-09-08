module VoiceStateTest exposing (suite)

{-| Unit tests for the pure per-session voice/ASR state machine
(Session/Voice): recording toggles, capture auto-stop, failures and
the asr_result / caret-insert paths. The message-level behavior is
covered by VoiceInputTest / PushToTalkTest through App.Update; these
pin the transition table itself so a flag combo can never be
re-arranged silently.
-}

import Expect
import Test exposing (Test, describe, test)
import Session.Types as T
import Session.Voice as Voice


session : T.SessionState
session =
    T.emptySession "s1"


busy : T.SessionState
busy =
    { session | asrBusy = True }


recording : T.SessionState
recording =
    { session | voiceActive = True }


rawRecording : T.SessionState
rawRecording =
    { session | rawRecording = True }


discarding : T.SessionState
discarding =
    { session | asrDiscard = True, asrBusy = True, voiceActive = True }


suite : Test
suite =
    describe "Session.Voice recording state machine"
        [ describe "micToggle (mic button click)"
            [ test "idle -> start recording" <|
                \_ ->
                    Expect.equal (Voice.micToggle session)
                        ( { session | voiceActive = True }, Voice.Start )
            , test "recording -> stop and transcribe" <|
                \_ ->
                    Expect.equal (Voice.micToggle recording)
                        ( { session | voiceActive = False, asrBusy = True }, Voice.Stop )
            , test "transcription in flight -> ignored" <|
                \_ ->
                    Expect.equal (Voice.micToggle busy) ( busy, Voice.None )
            ]
        , describe "rawToggle (raw-audio button click)"
            [ test "idle -> start raw recording" <|
                \_ ->
                    Expect.equal (Voice.rawToggle session)
                        ( { session | rawRecording = True }, Voice.RawStart )
            , test "raw recording -> stop" <|
                \_ ->
                    Expect.equal (Voice.rawToggle rawRecording)
                        ( { session | rawRecording = False }, Voice.RawStop )
            , test "ASR recording -> ignored (mutual exclusion)" <|
                \_ ->
                    Expect.equal (Voice.rawToggle recording) ( recording, Voice.None )
            , test "ASR transcribing -> ignored (mutual exclusion)" <|
                \_ ->
                    Expect.equal (Voice.rawToggle busy) ( busy, Voice.None )
            ]
        , describe "push-to-talk helpers"
            [ test "micStart marks voiceActive" <|
                \_ ->
                    Expect.equal (Voice.micStart session) { session | voiceActive = True }
            , test "micStop clears voiceActive and marks asrBusy" <|
                \_ ->
                    Expect.equal (Voice.micStop recording)
                        { session | voiceActive = False, asrBusy = True }
            ]
        , describe "cancelAsr / captureStopped / failures"
            [ test "cancelAsr marks the pending result as discard" <|
                \_ ->
                    Expect.equal (Voice.cancelAsr busy)
                        { session | asrBusy = False, asrDiscard = True }
            , test "capture auto-stop of the ASR recorder -> transcribe state" <|
                \_ ->
                    Expect.equal (Voice.captureStopped "asr" recording)
                        { session | voiceActive = False, asrBusy = True }
            , test "capture auto-stop of the raw recorder -> idle" <|
                \_ ->
                    Expect.equal (Voice.captureStopped "raw" rawRecording)
                        { session | rawRecording = False }
            , test "voiceError releases every recording flag" <|
                \_ ->
                    Expect.equal (Voice.voiceError discarding) session
            , test "rawError releases the raw recorder only" <|
                \_ ->
                    Expect.equal (Voice.rawError rawRecording) session
            ]
        , describe "asrResult"
            [ test "a discarded transcription is dropped whatever ok says" <|
                \_ ->
                    Expect.equal (Voice.asrResult True "hi" "" discarding)
                        ( session, Voice.AsrDiscarded )
            , test "successful transcript -> AsrText, flags released" <|
                \_ ->
                    Expect.equal (Voice.asrResult True "hello" "" busy)
                        ( { session | asrBusy = False }, Voice.AsrText "hello" )
            , test "empty transcript -> AsrEmpty" <|
                \_ ->
                    Expect.equal (Voice.asrResult True "" "" busy)
                        ( { session | asrBusy = False }, Voice.AsrEmpty )
            , test "failed transcription -> AsrFailed with the error" <|
                \_ ->
                    Expect.equal (Voice.asrResult False "" "boom" busy)
                        ( { session | asrBusy = False }, Voice.AsrFailed "boom" )
            ]
        , describe "insertTranscript"
            [ test "inserts at the caret and returns the new caret offset" <|
                \_ ->
                    let
                        s =
                            { session | input = "hello world", asrDiscard = True }
                    in
                    Expect.equal (Voice.insertTranscript s 6 " there")
                        ( { s | input = "hello  thereworld", asrDiscard = False }, 12 )
            , test "inserting at the end appends" <|
                \_ ->
                    Expect.equal (Voice.insertTranscript session 0 "abc")
                        ( { session | input = "abc" }, 3 )
            ]
        ]
