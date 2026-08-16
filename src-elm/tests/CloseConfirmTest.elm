module CloseConfirmTest exposing (tests)

-- Close-session confirmation — PER-SESSION: the pending state lives on
-- SessionState.closeConfirm and the overlay renders inside the session's
-- panel (like the tool-confirm overlay). Clicking a session window's ✕
-- or pressing Ctrl+W offers Close (keep the conversation on disk) /
-- Close and Delete (remove files) / Cancel, with Close as the default.
-- Internal closes (plans, runners) still go through CloseSession
-- directly and never prompt.

import Dict
import Expect
import App.Types as AT
import App.Update
import Session.Types
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


sessionCloseConfirm : String -> AT.Model -> Bool
sessionCloseConfirm sid model =
    case Dict.get sid model.sessions of
        Just s ->
            s.closeConfirm

        Nothing ->
            False


tests : Test
tests =
    describe "close-session confirmation (per-session)"
        [ describe "request opens the overlay (no close yet)"
            [ test "window ✕ / Ctrl+W opens the session's confirmation, session stays open" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal (Just "s1") mm.activeId
                        , \mm ->
                            case Dict.get "s1" mm.sessions of
                                Just _ ->
                                    Expect.pass

                                Nothing ->
                                    Expect.fail "s1 must still be open"
                        ]
                        m1
            , test "Ctrl+W requests confirmation instead of closing" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.KeyDown "w" True False False) initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m1
            , test "a second request on the same session is idempotent" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") m1
                    in
                    Expect.equal True (sessionCloseConfirm "s1" m2)
            , test "the state is per-session: other sessions stay quiet" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | sessions =
                                    Dict.insert "s2" (Session.Types.emptySession "s2") initModelWithSession.sessions
                            }

                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") m0
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal False (sessionCloseConfirm "s2" mm)
                        ]
                        m1
            ]
        , describe "choices"
            [ test "Close closes the session window and clears the overlay" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.ConfirmCloseSession "s1") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (Dict.member "s1" mm.sessions)
                        , \mm -> Expect.equal Nothing mm.activeId
                        ]
                        m2
            , test "Close and Delete removes the session too" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.ConfirmDeleteSession "s1") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (Dict.member "s1" mm.sessions)
                        , \mm -> Expect.equal False (Dict.member "s1" mm.sessionRefs)
                        , \mm -> Expect.equal False (Dict.member "s1" mm.sessionWorkCopies)
                        ]
                        m2
            , test "Cancel clears the overlay and keeps the session" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.DismissCloseConfirm "s1") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m2
            , test "Escape cancels the active session's confirmation" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.KeyDown "Escape" False False False) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m2
            , test "Escape cancels a lingering non-active confirmation too" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession
                                | sessions =
                                    Dict.insert "s2" (Session.Types.emptySession "s2") initModelWithSession.sessions
                            }

                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") m0

                        -- Switch focus to s2; s1's overlay is still open.
                        ( m2, _ ) =
                            App.Update.update (AT.SwitchSession "s2") m1

                        ( m3, _ ) =
                            App.Update.update (AT.KeyDown "Escape" False False False) m2
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal False (sessionCloseConfirm "s2" mm)
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m3
            , test "Escape with no confirmation pending does not disturb the session" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.KeyDown "Escape" False False False) initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m1
            , test "closing an already-gone session is a safe no-op" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.ConfirmCloseSession "gone") initModelWithSession
                    in
                    Expect.equal True (Dict.member "s1" m1.sessions)
            ]
        ]
