module CancelShortcutTest exposing (tests)

-- Ctrl+G cancels the active session's running task — the keyboard
-- equivalent of the send button while it shows "Cancel task". It must
-- be a strict no-op when nothing is running (never a send) and safe
-- with no active session.

import Dict
import Expect
import App.Types as AT
import App.Update
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


tests : Test
tests =
    describe "Ctrl+G cancels the running task"
        [ test "no-op when no session is active" <|
            \_ ->
                let
                    m0 =
                        { initModelWithSession | activeId = Nothing }

                    ( m1, _ ) =
                        App.Update.update (AT.KeyDown "g" True False False) m0
                in
                Expect.equal m0 m1
        , test "no-op when the active session has no running task (never sends)" <|
            \_ ->
                let
                    m0 =
                        initModelWithSession

                    ( m1, _ ) =
                        App.Update.update (AT.KeyDown "g" True False False) m0
                in
                Expect.equal m0 m1
        , test "cancels when the active session has a running task" <|
            \_ ->
                let
                    m0 =
                        { initModelWithSession
                            | sessions =
                                Dict.update "s1"
                                    (\s -> Maybe.map (\ss -> { ss | taskRunning = True }) s)
                                    initModelWithSession.sessions
                        }

                    ( m1, _ ) =
                        App.Update.update (AT.KeyDown "g" True False False) m0
                in
                -- The cancel is a port command (can't inspect the Cmd),
                -- but the model must be untouched and the session kept.
                Expect.all
                    [ \mm -> Expect.equal m0 mm
                    , \mm ->
                        case Dict.get "s1" mm.sessions of
                            Just s ->
                                Expect.equal True s.taskRunning

                            Nothing ->
                                Expect.fail "s1 missing"
                    ]
                    m1
        , test "plain 'g' without Ctrl is not intercepted" <|
            \_ ->
                let
                    m0 =
                        initModelWithSession

                    ( m1, _ ) =
                        App.Update.update (AT.KeyDown "g" False False False) m0
                in
                Expect.equal m0 m1
        ]
