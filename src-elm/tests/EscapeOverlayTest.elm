module EscapeOverlayTest exposing (tests)

{-| Escape (and Ctrl+[) closes the topmost open overlay: context menu →
global overlays → active session's overlays → media preview fallback.
The tool-confirm dialog must NOT be closed by Escape.
-}

import Dict
import Expect
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)
import App.Update as AU
import App.Types as AT
import Session.Types as T


escape : AT.Model -> AT.Model
escape model =
    AU.update (AT.KeyDown "Escape" False False False False) model |> Tuple.first


setSession : (T.SessionState -> T.SessionState) -> AT.Model -> AT.Model
setSession fn model =
    { model
        | sessions =
            Dict.update (Maybe.withDefault "" model.activeId) (Maybe.map fn) model.sessions
    }


withSettingsEditor : AT.Model -> AT.Model
withSettingsEditor m0 =
    let
        ed =
            m0.settingsEditor
    in
    { m0 | settingsEditor = { ed | show = True } }


withPresetManager : AT.Model -> AT.Model
withPresetManager m0 =
    let
        pm =
            m0.presetManager
    in
    { m0 | presetManager = { pm | show = True } }


withFilePickerOpen : T.SessionState -> T.SessionState
withFilePickerOpen s =
    let
        fp =
            s.filePicker
    in
    { s | filePicker = { fp | show = True } }


tests : Test
tests =
    describe "Escape closes overlays"
        [ test "closes the session manager" <|
            \_ ->
                let
                    m0 =
                        initModelWithSession
                in
                escape { m0 | showSessionManager = True }
                    |> .showSessionManager
                    |> Expect.equal False
        , test "closes the settings editor" <|
            \_ ->
                initModelWithSession
                    |> withSettingsEditor
                    |> escape
                    |> .settingsEditor
                    |> .show
                    |> Expect.equal False
        , test "closes the preset manager" <|
            \_ ->
                initModelWithSession
                    |> withPresetManager
                    |> escape
                    |> .presetManager
                    |> .show
                    |> Expect.equal False
        , test "closes only the FIRST global overlay when several are open" <|
            \_ ->
                initModelWithSession
                    |> withSettingsEditor
                    |> (\m -> { m | showSessionManager = True })
                    |> escape
                    |> (\m -> ( m.showSessionManager, m.settingsEditor.show ))
                    |> Expect.equal ( False, True )
        , test "closes the active session's file picker" <|
            \_ ->
                initModelWithSession
                    |> setSession withFilePickerOpen
                    |> escape
                    |> (\m -> Dict.get "s1" m.sessions)
                    |> Maybe.map (.filePicker >> .show)
                    |> Expect.equal (Just False)
        , test "closes the active session's model selector" <|
            \_ ->
                initModelWithSession
                    |> setSession (\s -> { s | showModelSelector = True })
                    |> escape
                    |> (\m -> Dict.get "s1" m.sessions)
                    |> Maybe.map .showModelSelector
                    |> Expect.equal (Just False)
        , test "clears the media preview as fallback" <|
            \_ ->
                initModelWithSession
                    |> setSession (\s -> { s | mediaPreview = Just { mediaType = T.Image, uri = "x", name = Nothing } })
                    |> escape
                    |> (\m -> Dict.get "s1" m.sessions)
                    |> Maybe.map .mediaPreview
                    |> Expect.equal (Just Nothing)
        , test "closes the file picker before falling back to the media preview" <|
            \_ ->
                initModelWithSession
                    |> setSession (\s ->
                        let
                            fp =
                                s.filePicker
                        in
                        { s
                            | filePicker = { fp | show = True }
                            , mediaPreview = Just { mediaType = T.Image, uri = "x", name = Nothing }
                        }
                      )
                    |> escape
                    |> (\m -> Dict.get "s1" m.sessions)
                    |> Maybe.map (\s -> ( s.filePicker.show, s.mediaPreview ))
                    |> Expect.equal (Just ( False, Just { mediaType = T.Image, uri = "x", name = Nothing } ))        , test "does NOT close the tool-confirm dialog" <|
                \_ ->
                    initModelWithSession
                        |> setSession (\s -> { s | pendingConfirm = [ { id = "p1", toolName = Just "edit_file", toolInput = Nothing } ] })
                        |> escape
                        |> (\m -> Dict.get "s1" m.sessions)
                        |> Maybe.map (.pendingConfirm >> List.length)
                        |> Expect.equal (Just 1)
        -- SD18: Escape is not a solo exit. The revised SD12 kept it as the
        -- LAST step of this chain; the user then ruled that no keyboard chord
        -- may leave solo at all, so the chain ends where it ended before solo
        -- existed. Both cases are pinned: an overlay in solo still gets closed
        -- first, and a chain that reaches its end in solo stops there.
        , test "in solo, Escape closes an open overlay and stays in solo" <|
            \_ ->
                let
                    soloWithPreview =
                        setSession (\s -> { s | mediaPreview = Just { mediaType = T.Image, uri = "x", name = Nothing } })
                            { initModelWithSession
                                | soloWin = Just "s1"
                                , windowPositions = Dict.insert "s1" { x = 0, y = 0, w = 560, h = 640, z = 1 } Dict.empty
                            }

                    after =
                        escape soloWithPreview
                in
                Expect.all
                    [ \_ ->
                        Dict.get "s1" after.sessions
                            |> Maybe.map .mediaPreview
                            |> Expect.equal (Just Nothing)
                    , \_ -> Expect.equal after.soloWin (Just "s1")
                    ]
                    ()
        , test "in solo with nothing open, Escape changes nothing at all" <|
            \_ ->
                let
                    solo =
                        { initModelWithSession
                            | soloWin = Just "s1"
                            , windowPositions = Dict.insert "s1" { x = 0, y = 0, w = 560, h = 640, z = 1 } Dict.empty
                        }
                in
                Expect.all
                    [ \_ -> Expect.equal (escape (escape solo)).soloWin (Just "s1")
                    -- two presses and it is still there. Also pins that the
                    -- chain's end is not secretly an ExitSolo: that branch
                    -- re-sends the chain payload, so an idle Escape in canvas
                    -- view must leave the model byte-identical too.
                    , \_ -> Expect.equal (escape initModelWithSession) initModelWithSession
                    ]
                    ()
        ]
