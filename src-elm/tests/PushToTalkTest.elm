module PushToTalkTest exposing (tests)

-- Push-to-talk (hold ` to talk): a held key opens a NEW session under
-- the built-in "Talk" preset and auto-starts ASR recording; releasing
-- stops it (transcribes into the input). These tests cover the Elm
-- state machine around the async create (keydown → SessionCreated →
-- keyup) and its edge cases.

import Dict
import Expect
import Json.Encode as E
import App.Types as AT
import App.Update
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


tests : Test
tests =
    describe "push-to-talk (hold ` to talk)"
        [ describe "hold → create Talk session → record"
            [ test "keydown arms the PT create under the Talk preset" <|
                \_ ->
                    let
                        ( m, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.ptHeld
                        , \mm -> Expect.equal True mm.ptCreatePending
                        , \mm -> Expect.equal (Just (AT.UserCreate "Talk")) mm.planCreating
                        , \mm -> Expect.equal [] mm.planCreateQueue
                        , \mm -> Expect.equal Nothing mm.ptSessionId
                        ]
                        m
            , test "SessionCreated of the PT create auto-starts recording and takes focus" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.SessionCreated "s9") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.ptHeld
                        , \mm -> Expect.equal False mm.ptCreatePending
                        , \mm -> Expect.equal (Just "s9") mm.ptSessionId
                        , \mm -> Expect.equal (Just "s9") mm.activeId
                        , \mm ->
                            case Dict.get "s9" mm.sessions of
                                Just s ->
                                    Expect.equal True s.voiceActive

                                Nothing ->
                                    Expect.fail "s9 missing"
                        ]
                        m2
            , test "keyup stops the recording (mirrors the ASR mic button)" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.SessionCreated "s9") m1

                        ( m3, _ ) =
                            App.Update.update (AT.PushToTalk False) m2
                    in
                    Expect.all
                        [ \mm -> Expect.equal False mm.ptHeld
                        , \mm -> Expect.equal Nothing mm.ptSessionId
                        , \mm -> Expect.equal False mm.ptCreatePending
                        , \mm ->
                            case Dict.get "s9" mm.sessions of
                                Just s ->
                                    Expect.all
                                        [ \ss -> Expect.equal False ss.voiceActive
                                        , \ss -> Expect.equal True ss.asrBusy
                                        ]
                                        s

                                Nothing ->
                                    Expect.fail "s9 missing"
                        ]
                        m3
            ]
        , describe "edge cases"
            [ test "release before the create finishes → session appears but stays silent" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.PushToTalk False) m1

                        ( m3, _ ) =
                            App.Update.update (AT.SessionCreated "s9") m2
                    in
                    Expect.all
                        [ \mm -> Expect.equal False mm.ptHeld
                        , \mm -> Expect.equal False mm.ptCreatePending
                        , \mm -> Expect.equal Nothing mm.ptSessionId
                        , \mm ->
                            case Dict.get "s9" mm.sessions of
                                Just s ->
                                    Expect.equal False s.voiceActive

                                Nothing ->
                                    Expect.fail "s9 missing"
                        ]
                        m3
            , test "a second keydown while held is ignored (no double queue)" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.PushToTalk True) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.ptHeld
                        , \mm -> Expect.equal [] mm.planCreateQueue
                        ]
                        m2
            , test "a plain menu create of the Talk preset never auto-records" <|
                \_ ->
                    -- CreateSessionWith "Talk" produces the same
                    -- UserCreate "Talk" marker, but ptCreatePending is
                    -- False (no PT keydown) — attribution must reject it.
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.CreateSessionWith "Talk") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.SessionCreated "s9") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False mm.ptCreatePending
                        , \mm -> Expect.equal Nothing mm.ptSessionId
                        , \mm ->
                            case Dict.get "s9" mm.sessions of
                                Just s ->
                                    Expect.equal False s.voiceActive

                                Nothing ->
                                    Expect.fail "s9 missing"
                        ]
                        m2
            , test "a create already in flight queues the PT create behind it" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession | planCreating = Just (AT.RunnerCreate "p1" "n1") }

                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) m0
                    in
                    Expect.all
                        [ \mm -> Expect.equal True mm.ptHeld
                        , \mm -> Expect.equal True mm.ptCreatePending
                        , \mm -> Expect.equal (Just (AT.RunnerCreate "p1" "n1")) mm.planCreating
                        , \mm -> Expect.equal [ AT.UserCreate "Talk" ] mm.planCreateQueue
                        ]
                        m1
            , test "a failed PT create disarms the auto-start" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.SessionCreateError "boom") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False mm.ptCreatePending
                        , \mm -> Expect.equal Nothing mm.ptSessionId
                        , \mm -> Expect.equal True mm.ptHeld -- the key is still held; keyup clears it
                        ]
                        m2
            , test "a mic error unlinks the PT session so keyup cannot double-stop" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk True) initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.SessionCreated "s9") m1

                        ( m3, _ ) =
                            App.Update.update
                                (AT.VoiceError
                                    (E.object
                                        [ ( "sessionId", E.string "s9" )
                                        , ( "message", E.string "denied" )
                                        ]
                                    )
                                )
                                m2
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing mm.ptSessionId
                        , \mm -> Expect.equal True mm.ptHeld
                        ]
                        m3
            , test "keyup with a missing PT session is a safe no-op" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | ptHeld = True
                                , ptSessionId = Just "gone"
                            }

                        ( m1, _ ) =
                            App.Update.update (AT.PushToTalk False) m0
                    in
                    Expect.all
                        [ \mm -> Expect.equal False mm.ptHeld
                        , \mm -> Expect.equal Nothing mm.ptSessionId
                        , \mm -> Expect.equal False mm.ptCreatePending
                        ]
                        m1
            ]
        ]
