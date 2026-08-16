module CloseConfirmTest exposing (tests)

-- Close-session confirmation: clicking a session window's ✕ or pressing
-- Ctrl+W no longer closes directly — a confirm overlay offers Close
-- (keep the conversation on disk) / Close and Delete (remove files) /
-- Cancel, with Close as the default. Internal closes (plans, runners)
-- still go through CloseSession directly and never prompt.

import Dict
import Expect
import App.Types as AT
import App.Update
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


tests : Test
tests =
    describe "close-session confirmation"
        [ describe "request opens the overlay (no close yet)"
            [ test "window ✕ / Ctrl+W opens the confirmation, session stays open" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal (Just "s1") mm.closeConfirm
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
                        [ \mm -> Expect.equal (Just "s1") mm.closeConfirm
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m1
            , test "a new request replaces a pending one" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") m1
                    in
                    Expect.equal (Just "s1") m2.closeConfirm
            ]
        , describe "choices"
            [ test "Close keeps the session window closed and clears the overlay" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.ConfirmCloseSession "s1") m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing mm.closeConfirm
                        , \mm -> Expect.equal False (Dict.member "s1" mm.sessions)
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
                        [ \mm -> Expect.equal Nothing mm.closeConfirm
                        , \mm -> Expect.equal False (Dict.member "s1" mm.sessions)
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
                            App.Update.update AT.DismissCloseConfirm m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing mm.closeConfirm
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m2
            , test "Escape cancels the confirmation" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.RequestCloseSession "s1") initModelWithSession

                        ( m2, _ ) =
                            App.Update.update (AT.KeyDown "Escape" False False False) m1
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing mm.closeConfirm
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m2
            , test "Escape with no confirmation pending does not disturb the session" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.KeyDown "Escape" False False False) initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing mm.closeConfirm
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        ]
                        m1
            , test "closing an already-gone session is a safe no-op" <|
                \_ ->
                    let
                        m0 =
                            { initModelWithSession | closeConfirm = Just "gone" }

                        ( m1, _ ) =
                            App.Update.update (AT.ConfirmCloseSession "gone") m0
                    in
                    Expect.equal Nothing m1.closeConfirm
            ]
        ]
