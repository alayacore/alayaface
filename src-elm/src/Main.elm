module Main exposing (main)

{-| Thin application shell: wires init, subscriptions, and the
update/view from App/Update and App/View. All application logic lives
in the App/* and Session/* modules; keep this file small.
-}

import Browser
import Browser.Dom as Dom
import Browser.Events as Evts
import Dict exposing (Dict)
import Html exposing (Html)
import Json.Decode as D
import Task
import App.Types exposing (..)
import App.Update
import App.View
import Ports


-- MAIN

main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }


init : Flags -> ( Model, Cmd Msg )
init _ =
    ( { sessions = Dict.empty
      , activeId = Nothing
      , initializing = True
      , initError = Nothing
      , showSessionManager = False
      , sessionDirs = []
      , sessionManagerError = Nothing
      , isMaximized = False
      , atBottom = True
      , prevMsgCount = 0
      , sessionOrder = []
      , pendingSwitchOnCreate = False
      , inputRows = 1
      , cursorMsgId = Nothing
      , pendingEvents = Dict.empty
      , sessionNums = Dict.empty
      , nextSessionNum = 1
      , windowPositions = Dict.empty
      , nextZIndex = 1
      , dragInfo = Nothing
      , resizeInfo = Nothing
      , showGlobalMenu = False
      , defaultModelsEditor = emptyDefaultModelsEditor
      , mcpEditor = emptyMcpEditor
      , settingsEditor = emptySettingsEditor
      , presets = []
      , activePreset = ""
      , presetManager = emptyPresetManager
      , ctxVisible = False
      , ctxX = 0
      , ctxY = 0
      , ctxHistoryId = ""
      , ctxSessionId = ""
      , appWidth = 1400
      , appHeight = 900
      }
    , Cmd.batch
        [ Ports.createSession { toolConfirm = Nothing }
        , Ports.listPresets {}
        , Task.attempt GotContainerSize (Dom.getElement "main-content")
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update =
    App.Update.update


view : Model -> Html Msg
view =
    App.View.view


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Ports.onScroll (\{ scrollTop, scrollHeight, clientHeight } ->
            ScrollPosition scrollTop scrollHeight clientHeight
          )
        , Ports.onDelta (\raw -> DeltaEvent raw)
        , Ports.onFrame (\raw -> FrameEvent raw)
        , Ports.onStatus (\raw -> StatusEvent raw)
        , Ports.onDefaultModelsList (\raw -> DefaultModelsListResult raw)
        , Ports.onDefaultModelsSyncResult (\raw -> DefaultModelsSyncResult raw)
        , Ports.onDefaultMcpList (\raw -> McpListResult raw)
        , Ports.onDefaultMcpSyncResult (\raw -> McpSyncResult raw)
        , Ports.onGlobalSettingsList (\raw -> SettingsListResult raw)
        , Ports.onGlobalSettingsSyncResult (\raw -> SettingsSyncResult raw)
        , Ports.onPresetsList (\raw -> PresetsListResult raw)
        , Ports.onPresetActionResult (\raw -> PresetActionResult raw)
        , Ports.onSessionCreated (\id -> SessionCreated id)
        , Ports.onSessionDirs (\dirs -> SessionDirsResult dirs)
        , Ports.onSessionActionResult (\raw -> SessionActionResult raw)
        , Ports.onFsListDir (\entries -> FsListDirResult entries)
        , Ports.onFsHomeDir (\home -> FsHomeDirResult home)
        , Ports.onFsReadFileDataUri (\uri -> FsReadFileResult uri)
        , Ports.onFsResolvePath (\result -> FsResolvePathResult result)
        , Ports.onWindowMaximized (\v -> WindowMaximized v)
        , Evts.onResize (\_ _ -> RequerySize)
        , Evts.onKeyDown <|
            D.map4 KeyDown
                (D.field "key" D.string)
                (D.field "ctrlKey" D.bool)
                (D.field "altKey" D.bool)
                (D.field "defaultPrevented" D.bool)
        , Evts.onMouseMove (D.map2 WindowDragMove (D.field "clientX" D.float) (D.field "clientY" D.float))
        , Evts.onMouseUp (D.succeed WindowDragEnd)
        ]
