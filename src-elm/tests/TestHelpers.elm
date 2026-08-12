module TestHelpers exposing (initModelWithSession)

-- Shared model builder for App/Update tests: a model with one session
-- "s1" (active) and all plan-mode fields at their initial values.

import Dict
import Set
import App.Types as AT
import Session.Types as T


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
    , planMetaScanReqId = Nothing
    , planMetaReadReqId = Nothing
    , planMetaSessionQueue = []
    , sessionDirMap = Dict.empty
    , fsReqCounter = 0
    , planRunStatuses = Dict.empty
    , planCascadePreview = Nothing
    , planCascade = Nothing
    , planCascadeOpenQueue = []
    , planSuppressFeedback = Set.empty
    , planCascadeFork = Nothing
    , closeSet = Set.empty
    , planMessageCounts = Dict.empty
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
    , connectionChain = []
    , homeDir = ""
    , sessionRefs = Dict.empty
    , runSummaries = Dict.empty
    , versionCache = Dict.empty
    , freezeActive = Nothing
    , freezeQueue = []
    , sessionWorkCopies = Dict.empty
    }
