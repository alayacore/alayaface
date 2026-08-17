module CancelShortcutTest exposing (tests)

-- Ctrl+G requests a cancel-task CONFIRMATION for the active session's
-- running task — the keyboard equivalent of the send button while it
-- shows "Cancel task". It must be a strict no-op when nothing is
-- running (never a send) and safe with no active session. The
-- confirmation itself (ConfirmCancelTask / DismissCancelTask / Escape)
-- is covered here too.

import Dict
import Expect
import App.Types as AT
import App.Update
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


withTaskRunning : AT.Model -> AT.Model
withTaskRunning model =
    { model
        | sessions =
            Dict.update "s1"
                (\s -> Maybe.map (\ss -> { ss | taskRunning = True }) s)
                model.sessions
    }


sessionCancelConfirm : String -> AT.Model -> Bool
sessionCancelConfirm sid model =
    case Dict.get sid model.sessions of
        Just s ->
            s.cancelTaskConfirm

        Nothing ->
            False


tests : Test
tests =
    describe "Ctrl+G cancels the running task (with confirmation)"
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
        , test "opens the cancel confirmation when a task is running" <|
            \_ ->
                let
                    ( m1, _ ) =
                        App.Update.update (AT.KeyDown "g" True False False) (withTaskRunning initModelWithSession)
                in
                Expect.all
                    [ \mm -> Expect.equal True (sessionCancelConfirm "s1" mm)
                    , \mm -> Expect.equal (Just "s1") mm.activeId
                    , \mm ->
                        case Dict.get "s1" mm.sessions of
                            Just s ->
                                Expect.equal True s.taskRunning

                            Nothing ->
                                Expect.fail "s1 missing"
                    ]
                    m1
        , test "ConfirmCancelTask aborts and clears the overlay" <|
            \_ ->
                let
                    ( m1, _ ) =
                        App.Update.update (AT.RequestCancelTask "s1") (withTaskRunning initModelWithSession)

                    ( m2, _ ) =
                        App.Update.update (AT.ConfirmCancelTask "s1") m1
                in
                Expect.all
                    [ \mm -> Expect.equal False (sessionCancelConfirm "s1" mm)
                    , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                    ]
                    m2
        , test "DismissCancelTask keeps the task running" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCancelTask "s1") (withTaskRunning initModelWithSession)

                        ( m2, _ ) =
                            App.Update.update (AT.DismissCancelTask "s1") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (sessionCancelConfirm "s1" mm)
                        , \mm ->
                            case Dict.get "s1" mm.sessions of
                                Just s ->
                                    Expect.equal True s.taskRunning

                                Nothing ->
                                    Expect.fail "s1 missing"
                        ]
                        m2
        , test "Escape dismisses the confirmation (task keeps running)" <|
            \_ ->
                let
                    ( m1, _ ) =
                        App.Update.update (AT.RequestCancelTask "s1") (withTaskRunning initModelWithSession)

                    ( m2, _ ) =
                        App.Update.update (AT.KeyDown "Escape" False False False) m1
                in
                Expect.all
                    [ \mm -> Expect.equal False (sessionCancelConfirm "s1" mm)
                    , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                    ]
                    m2
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
