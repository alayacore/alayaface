module Session.Overlays exposing (OverlayState, emptyOverlays)

import Session.Types as T


type alias OverlayState =
    { -- File Picker
      showFilePicker : Bool
    , filePickerType : T.MediaType
    , filePickerMode : T.FileMode
    , filePickerInput : String
    , filePickerFilter : String
    , filePickerEntries : List T.DirEntry
    , filePickerDir : String
    , filePickerBaseDir : String
    , filePickerSelected : Int
    , filePickerLoading : Bool
    , filePickerError : Maybe String
    , pendingFileName : String
      -- Model Selector
    , showModelSelector : Bool
    , modelSelectorInput : String
    , modelSelectorSelected : Int
    , modelSelectorScroll : Int
      -- Help Window
    , showHelpWindow : Bool
    , helpFilter : String
    , helpSelected : Int
    , helpScroll : Int
      -- MCP / Confirm (these are shared between overlays)
    , pendingConfirm : List T.PendingConfirm
    , pendingMcpAuth : Maybe T.PendingConfirm
    , pendingMcpAuths : List T.PendingConfirm
    , mcpStatus : Maybe String
    , mcpServers : List String
    }


emptyOverlays : OverlayState
emptyOverlays =
    { showFilePicker = False
    , filePickerType = T.Image
    , filePickerMode = T.Local
    , filePickerInput = ""
    , filePickerFilter = ""
    , filePickerEntries = []
    , filePickerDir = ""
    , filePickerBaseDir = ""
    , filePickerSelected = 0
    , filePickerLoading = False
    , filePickerError = Nothing
    , pendingFileName = ""
    , showModelSelector = False
    , modelSelectorInput = ""
    , modelSelectorSelected = 0
    , modelSelectorScroll = 0
    , showHelpWindow = False
    , helpFilter = ""
    , helpSelected = 0
    , helpScroll = 0
    , pendingConfirm = []
    , pendingMcpAuth = Nothing
    , pendingMcpAuths = []
    , mcpStatus = Nothing
    , mcpServers = []
    }
