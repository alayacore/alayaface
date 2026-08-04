module Session.Types exposing
    ( Role(..)
    , roleToString
    , roleFromString
    , MediaType(..)
    , mediaTypeToString
    , mediaTypeFromString
    , MediaItem
    , StagedMedia
    , Message
    , defaultCollapsed
    , isMsgCollapsed
    , toggleMsgCollapsed
    , ToolCall
    , SessionState
    , ModelInfo
    , ModelDraft
    , McpInfo
    , McpDraft
    , emptyMcpDraft
    , latestMcpProtoVersion
    , ThemeInfo
    , emptySession
    , emptyDraft
    , PendingConfirm
    , McpAuth
    , FileMode(..)
    , DirEntry
    )

import Dict exposing (Dict)
import Set exposing (Set)
import Json.Decode as D
import Json.Encode as E
import Session.Selector


-- Media Types

type MediaType
    = Image
    | Audio
    | Video
    | Document


mediaTypeToString : MediaType -> String
mediaTypeToString mt =
    case mt of
        Image -> "image"
        Audio -> "audio"
        Video -> "video"
        Document -> "document"


mediaTypeFromString : String -> Maybe MediaType
mediaTypeFromString s =
    case s of
        "image" -> Just Image
        "audio" -> Just Audio
        "video" -> Just Video
        "document" -> Just Document
        _ -> Nothing


-- File Picker Types

type FileMode
    = Local
    | Url


type alias DirEntry =
    { name : String
    , isDir : Bool
    }


type alias MediaItem =
    { mediaType : MediaType
    , uri : String
    , name : Maybe String
    }


type alias StagedMedia =
    { id : String
    , mediaType : MediaType
    , uri : String
    , name : Maybe String
    }


-- Role

type Role
    = User
    | Assistant
    | Tool
    | System
    | Reasoning
    | Notify
    | Error


roleToString : Role -> String
roleToString r =
    case r of
        User -> "user"
        Assistant -> "assistant"
        Tool -> "tool"
        System -> "system"
        Reasoning -> "reasoning"
        Notify -> "notify"
        Error -> "error"


roleFromString : String -> Maybe Role
roleFromString s =
    case s of
        "user" -> Just User
        "assistant" -> Just Assistant
        "tool" -> Just Tool
        "system" -> Just System
        "reasoning" -> Just Reasoning
        "notify" -> Just Notify
        "error" -> Just Error
        _ -> Nothing


-- Message

type alias Message =
    { id : String
    , role : Role
    , content : String
    , toolId : Maybe String
    , toolName : Maybe String
    , isError : Bool
    , historyId : Maybe String
    , media : Maybe (List MediaItem)
    }


-- Message Collapse
--
-- Collapse state is a Dict keyed by message id holding the user's
-- EXPLICIT choice (True = collapsed, False = expanded). Messages without
-- an entry fall back to a role-based default, so tool/reasoning windows
-- start collapsed while user/assistant start expanded.

defaultCollapsed : Role -> Bool
defaultCollapsed role =
    case role of
        Tool ->
            True

        Reasoning ->
            True

        _ ->
            False


isMsgCollapsed : Dict String Bool -> Message -> Bool
isMsgCollapsed dict msg =
    case Dict.get msg.id dict of
        Just v ->
            v

        Nothing ->
            defaultCollapsed msg.role


toggleMsgCollapsed : Dict String Bool -> Message -> Dict String Bool
toggleMsgCollapsed dict msg =
    Dict.insert msg.id (not (isMsgCollapsed dict msg)) dict


-- Tool Call

type alias ToolCall =
    { id : String
    , name : String
    , input : Maybe (Dict String E.Value)
    , output : Maybe String
    , isError : Bool
    , started : Bool
    , inputReceived : Bool
    , accumulatedDelta : Maybe String
    }


-- Pending Confirm

type alias PendingConfirm =
    { id : String
    , toolName : Maybe String
    , toolInput : Maybe String
    }


-- MCP OAuth request for one server. Multiple servers can need
-- authorization during a single init; each is tracked independently.

type alias McpAuth =
    { server : String
    , url : String
    }


-- Session State

type alias SessionState =
    { id : String
    , connected : Bool
    , statusMsg : String
    , messages : List Message
    , staged : List StagedMedia
    , models : List ModelInfo
    , activeModelId : Maybe Int
    , activeModelName : String
    , taskRunning : Bool
    , taskCurrentStep : Int
    , taskMaxSteps : Int
    , contextTokens : Int
    , contextLimit : Int
    , historyContents : Dict String String
    , historyRoles : Dict String String
    , toolCalls : Dict String ToolCall
    , stderrLines : List String
    , input : String
    , sendPending : Bool
    , processedEchoIds : Set.Set String
    , msgCollapsed : Dict.Dict String Bool
    , pendingConfirm : List PendingConfirm
    , pendingMcpAuths : List McpAuth
    , mcpAuthRunning : Maybe String
    , showFilePicker : Bool
    , filePickerType : MediaType
    , filePickerMode : FileMode
    , filePickerInput : String
    , filePickerFilter : String
    , filePickerEntries : List DirEntry
    , filePickerDir : String
    , filePickerBaseDir : String
    , filePickerSelected : Int
    , filePickerLoading : Bool
    , filePickerError : Maybe String
    , filePickerSavedLocalPath : String
    , filePickerSavedUrlPath : String
    , pendingFileName : String
    , mcpStatus : Maybe String
    , mcpServers : List String
    , messageVersion : Maybe Int
    , reasoningLevel : Maybe Int
    , activeTheme : Maybe String
    , themes : Maybe (List ThemeInfo)
    , videoFps : Maybe Int
    , videoRes : Maybe Int
      -- Overlay state (per-session)
    , showModelSelector : Bool
    , modelSelector : Session.Selector.State ModelInfo ModelDraft
    , showHelpWindow : Bool
    , helpFilter : String
    , helpSelected : Int
    , helpScroll : Int
    }


type alias ModelInfo =
    { id : Int
    , name : String
    , protocolType : String
    , baseUrl : String
    , apiKey : String
    , modelName : String
    , contextLimit : Int
    , maxTokens : Int
    }


type alias ModelDraft =
    { id : Int
    , name : String
    , protocolType : String
    , baseUrl : String
    , apiKey : String
    , modelName : String
    , contextLimit : String
    , maxTokens : String
    }


-- MCP server (mirrors mcp.conf key-value blocks; args/env kept as raw JSON text)
-- `type` is a UI concept (http/stdio) inferred from url presence; not persisted.

type alias McpInfo =
    { id : Int
    , type_ : String
    , server : String
    , url : String
    , command : String
    , args : String
    , env : String
    , authType : String
    , authToken : String
    , authClientId : String
    , authClientSecret : String
    , protoVersion : String
    }


type alias McpDraft =
    { id : Int
    , type_ : String
    , server : String
    , url : String
    , command : String
    , args : String
    , env : String
    , authType : String
    , authToken : String
    , authClientId : String
    , authClientSecret : String
    , protoVersion : String
    }


emptyMcpDraft : McpDraft
emptyMcpDraft =
    { id = 0
    , type_ = "http"
    , server = ""
    , url = ""
    , command = ""
    , args = ""
    , env = ""
    , authType = ""
    , authToken = ""
    , authClientId = ""
    , authClientSecret = ""
    , protoVersion = latestMcpProtoVersion
    }


-- Latest MCP protocol version used as the default for new servers.
-- Keep in sync with the `known` list in Overlay/McpEditor.protoVersionOptions.
latestMcpProtoVersion : String
latestMcpProtoVersion =
    "2026-07-28"


emptyDraft : ModelDraft
emptyDraft =
    { id = 0
    , name = ""
    , protocolType = "openai"
    , baseUrl = ""
    , apiKey = ""
    , modelName = ""
    , contextLimit = "0"
    , maxTokens = "0"
    }


type alias ThemeInfo =
    { name : String
    , theme : Maybe (Dict String String)
    }


emptySession : String -> SessionState
emptySession id =
    { id = id
    , connected = True
    , statusMsg = "Connected"
    , messages = []
    , staged = []
    , models = []
    , activeModelId = Nothing
    , activeModelName = ""
    , taskRunning = False
    , taskCurrentStep = 0
    , taskMaxSteps = 0
    , contextTokens = 0
    , contextLimit = 0
    , historyContents = Dict.empty
    , historyRoles = Dict.empty
    , toolCalls = Dict.empty
    , stderrLines = []
    , input = ""
    , sendPending = False
    , processedEchoIds = Set.empty
    , msgCollapsed = Dict.empty
    , pendingConfirm = []
    , pendingMcpAuths = []
    , mcpAuthRunning = Nothing
    , showFilePicker = False
    , filePickerType = Image
    , filePickerMode = Local
    , filePickerInput = ""
    , filePickerFilter = ""
    , filePickerEntries = []
    , filePickerDir = ""
    , filePickerBaseDir = ""
    , filePickerSelected = 0
    , filePickerLoading = False
    , filePickerError = Nothing
    , filePickerSavedLocalPath = ""
    , filePickerSavedUrlPath = ""
    , pendingFileName = ""
    , mcpStatus = Nothing
    , mcpServers = []
    , messageVersion = Nothing
    , reasoningLevel = Nothing
    , activeTheme = Nothing
    , themes = Nothing
    , videoFps = Nothing
    , videoRes = Nothing
    , showModelSelector = False
    , modelSelector = Session.Selector.empty
    , showHelpWindow = False
    , helpFilter = ""
    , helpSelected = 0
    , helpScroll = 0
    }
