module RpcErrorTest exposing (suite)

import Expect
import Json.Encode as E
import Set
import Test exposing (Test, describe, test)
import App.Update
import App.Types as AT
import Dict
import Session.Types as T


suite : Test
suite =
    describe "RpcError handling"
        [ test "send_prompt failure clears sendPending and shows the error" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "kind", E.string "send_prompt" )
                            , ( "sessionId", E.string "s1" )
                            , ( "message", E.string "Session is disconnected" )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.RpcError raw) model
                in
                case Dict.get "s1" updated.sessions of
                    Just s ->
                        Expect.equal ( s.sendPending, s.statusMsg )
                            ( False, "send_prompt failed: Session is disconnected" )

                    Nothing ->
                        Expect.fail "session s1 missing"
        , test "unknown session ignores the error" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "kind", E.string "send_prompt" )
                            , ( "sessionId", E.string "nope" )
                            , ( "message", E.string "x" )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.RpcError raw) model
                in
                Expect.equal (Dict.size updated.sessions) 1
        ]


initModelWithSession : AT.Model
initModelWithSession =
    let
        session =
            T.emptySession "s1"
    in
    { sessions = Dict.insert "s1" session Dict.empty
    , activeId = Just "s1"
    , showSessionManager = False
    , sessionDirs = []
    , sessionManagerError = Nothing
    , isMaximized = False
    , sessionOrder = [ "s1" ]
    , pendingSwitchOnCreate = False
    , inputRows = 1
    , cursorMsgId = Nothing
    , pendingEvents = Dict.empty
    , sessionNums = Dict.empty
    , nextSessionNum = 1
    , windowPositions = Dict.empty
    , nextZIndex = 1
    , canvasOffset = { x = 0, y = 0 }
    , canvasScale = 1.0
    , canvasDrag = Nothing
    , dragInfo = Nothing
    , resizeInfo = Nothing
    , showGlobalMenu = False
    , defaultModelsEditor = AT.emptyDefaultModelsEditor
    , mcpEditor = AT.emptyMcpEditor
    , settingsEditor = AT.emptySettingsEditor
    , globalConfig = AT.emptyGlobalConfig
    , globalConfigEditor = AT.emptyGlobalConfigEditor
    , presets = []
    , activePreset = ""
    , presetManager = AT.emptyPresetManager
    , ctxVisible = False
    , ctxX = 0
    , ctxY = 0
    , ctxHistoryId = ""
    , ctxSessionId = ""
    , appWidth = 1400
    , appHeight = 900
    , planWindows = Dict.empty
    , planMetas = Dict.empty
    , planMetaLoading = False
    , planMetaScanPending = False
    , planMetaDirQueue = []
    , planMetaDirListing = Nothing
    , planMetaReading = Nothing
    , planMetaReadQueue = []
    , planRunStatuses = Dict.empty
    , planTaskStarted = Set.empty
    , planOrder = []
    , planActiveId = Nothing
    , pendingPlanOffers = Dict.empty
    , planReplaySessions = Set.empty
    , planCreating = Nothing
    , planCreateQueue = []
    , planReadTarget = Nothing
    , planNodeSessions = Dict.empty
    , planResumeOwner = Nothing
    , planResumeFrom = Nothing
    , planResumedFrom = Dict.empty
    , nodeConnection = Nothing
    , planConnection = Nothing
    , homeDir = ""
    }
