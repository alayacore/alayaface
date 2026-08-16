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
    , mcpProtoVersions
    , emptySession
    , emptyDraft
    , FilePickerState
    , emptyFilePicker
    , PendingConfirm
    , McpAuth
    , FileMode(..)
    , DirEntry
    )

import Dict exposing (Dict)
import Set exposing (Set)
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

        -- Error/Notify frames (incl. local voice-input errors) are
        -- collapsed by default too: they are transient status rows, not
        -- conversation content — expand to read the details.
        Error ->
            True

        Notify ->
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
    -- True once the core's explicit readiness signal arrives
    -- (SM {"type":"session","data":{"state":"ready"}}): MCP servers are
    -- initialized, replay ended, the session is interactive. Node
    -- prompts are held until this flips (alayacore rejects prompts with
    -- MCP_NOT_READY before it).
    , ready : Bool
    , statusMsg : String
    , messages : List Message
    , staged : List StagedMedia
    , models : List ModelInfo
    , activeModelId : Maybe Int
    , activeModelName : String
      -- Reasoning level (0|1|2), set via the `:reason` command / the
      -- input-bar selector; the core reports the active level in its
      -- boot SM {"type":"reasoning",...}.
    , reasoningLevel : Int
    , taskRunning : Bool
    , taskCurrentStep : Int
    , taskMaxSteps : Int
    , contextTokens : Int
    , contextLimit : Int
    , historyContents : Dict String String
    , toolCalls : Dict String ToolCall
    , input : String
    , sendPending : Bool
    , atBottom : Bool
    , processedEchoIds : Set.Set String
    , msgCollapsed : Dict.Dict String Bool
    , pendingConfirm : List PendingConfirm
    , pendingMcpAuths : List McpAuth
    , mcpAuthRunning : Maybe String
    , filePicker : FilePickerState
    , mediaPreview : Maybe MediaItem
    , mcpStatus : Maybe String
    , mcpServers : List String
      -- Overlay state (per-session)
    , showModelSelector : Bool
    , modelSelector : Session.Selector.State ModelInfo ModelDraft
      -- Voice input (P-series): voiceActive = mic recording in progress
      -- (toggle on the mic button); asrBusy = transcription running
      -- (waiting for the asr_transcribe result — the mic button turns
      -- into a cancel); asrDiscard = the user cancelled a pending
      -- transcription, so its result must be dropped when it arrives.
      -- rawRecording = the raw-audio button is recording the mic; on
      -- stop the WAV data URI is sent straight to AlayaCore as a UA
      -- (user audio) frame.
    , voiceActive : Bool
    , asrBusy : Bool
    , asrDiscard : Bool
    , rawRecording : Bool
    }


-- File Picker State
--
-- All picker UI state grouped in one record (previously 14 flat
-- filePicker* fields on SessionState). Pure logic lives in
-- Session/FilePicker.elm.

type alias FilePickerState =
    { show : Bool
    , mode : FileMode
    , input : String
    , filter : String
    , entries : List DirEntry
    , dir : String
    , baseDir : String
    , selected : Int
    , loading : Bool
    , error : Maybe String
    , savedLocalPath : String
    , savedUrlPath : String
    , pendingFileName : String
    }


emptyFilePicker : FilePickerState
emptyFilePicker =
    { show = False
    , mode = Local
    , input = ""
    , filter = ""
    , entries = []
    , dir = ""
    , baseDir = ""
    , selected = 0
    , loading = False
    , error = Nothing
    , savedLocalPath = ""
    , savedUrlPath = ""
    , pendingFileName = ""
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
latestMcpProtoVersion : String
latestMcpProtoVersion =
    "2026-07-28"


-- Canonical list of known MCP protocol versions. Overlay/McpEditor
-- derives its dropdown options from this so the two cannot drift.
mcpProtoVersions : List String
mcpProtoVersions =
    [ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", latestMcpProtoVersion ]


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


emptySession : String -> SessionState
emptySession id =
    { id = id
    , connected = True
    , ready = False
    , statusMsg = "Connected"
    , messages = []
    , staged = []
    , models = []
    , activeModelId = Nothing
    , activeModelName = ""
    , reasoningLevel = 1
    , taskRunning = False
    , taskCurrentStep = 0
    , taskMaxSteps = 0
    , contextTokens = 0
    , contextLimit = 0
    , historyContents = Dict.empty
    , toolCalls = Dict.empty
    , input = ""
    , sendPending = False
    , atBottom = True
    , processedEchoIds = Set.empty
    , msgCollapsed = Dict.empty
    , pendingConfirm = []
    , pendingMcpAuths = []
    , mcpAuthRunning = Nothing
    , filePicker = emptyFilePicker
    , mediaPreview = Nothing
    , mcpStatus = Nothing
    , mcpServers = []
    , showModelSelector = False
    , modelSelector = Session.Selector.empty
    , voiceActive = False
    , asrBusy = False
    , asrDiscard = False
    , rawRecording = False
    }
