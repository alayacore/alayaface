module CloseConfirmTest exposing (tests)

-- Close-session confirmation — PER-SESSION: the pending state lives on
-- SessionState.closeConfirm and the overlay renders inside the session's
-- panel (like the tool-confirm overlay). Clicking a session window's ✕
-- or pressing the ✕ offers Close (keep the conversation on disk) /
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
            [ test "window ✕ opens the session's confirmation, session stays open" <|
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
            -- The user's decision, revising SD10: Ctrl+W is NOT a close key at
            -- all anymore. The old binding asked "close the topmost window"
            -- (the active plan when it was on top, else the active session's
            -- confirmation), so a reflex borrowed from the browser could take a
            -- session out of the board — with the windows now cascading in the
            -- same shape as browser tabs, that accident stopped being rare.
            , test "Ctrl+W closes nothing and confirms nothing in canvas view" <|
                \_ ->
                    let
                        ( m1, _ ) =
                            App.Update.update (AT.KeyDown "w" True False False False) initModelWithSession
                    in
                    Expect.all
                        [ \mm -> Expect.equal False (sessionCloseConfirm "s1" mm)
                        , \mm -> Expect.equal True (Dict.member "s1" mm.sessions)
                        -- the whole model is untouched: Ctrl+W has no meaning
                        -- outside solo, so the browser/OS keeps its own
                        , \mm -> Expect.equal mm initModelWithSession
                        ]
                        m1
            -- SD18: no keyboard chord leaves solo. The revised SD10 kept this
            -- one, then the user removed it too — the argument that settled it
            -- is that in solo the panel IS the window, so "Ctrl+W changed what
            -- I was looking at" is indistinguishable from "Ctrl+W closed my
            -- window" no matter which one the code did.
            , test "Ctrl+W in solo leaves solo alone (and closes nothing)" <|
                \_ ->
                    let
                        solo =
                            { initModelWithSession
                                | soloWin = Just "s1"
                                , windowPositions =
                                    Dict.insert "s1" { x = 0, y = 0, w = 1400, h = 900, z = 1 } Dict.empty
                            }

                        ( m1, _ ) =
                            App.Update.update (AT.KeyDown "w" True False False False) solo
                    in
                    Expect.all
                        [ \mm -> Expect.equal mm.soloWin (Just "s1")
                        , \_ -> Expect.equal m1 solo
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
                            App.Update.update (AT.KeyDown "Escape" False False False False) m1
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
                            App.Update.update (AT.KeyDown "Escape" False False False False) m2
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
                            App.Update.update (AT.KeyDown "Escape" False False False False) initModelWithSession
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
