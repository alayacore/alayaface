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
    , ToolCall
    , NotificationItem
    , NotifType(..)
    , SessionState
    , ModelInfo
    , ThemeInfo
    , emptySession
    , PendingConfirm
    )

import Dict exposing (Dict)
import Set exposing (Set)
import Json.Decode as D
import Json.Encode as E


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


roleToString : Role -> String
roleToString r =
    case r of
        User -> "user"
        Assistant -> "assistant"
        Tool -> "tool"
        System -> "system"
        Reasoning -> "reasoning"


roleFromString : String -> Maybe Role
roleFromString s =
    case s of
        "user" -> Just User
        "assistant" -> Just Assistant
        "tool" -> Just Tool
        "system" -> Just System
        "reasoning" -> Just Reasoning
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


-- Notification

type alias NotificationItem =
    { id : String
    , notifType : NotifType
    , text : String
    , timestamp : Int
    }


type NotifType
    = Notify
    | Error


-- Pending Confirm

type alias PendingConfirm =
    { id : String
    , toolName : Maybe String
    , toolInput : Maybe String
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
    , notifications : List NotificationItem
    , input : String
    , sendPending : Bool
    , processedEchoIds : Set.Set String
    , collapsedMsgIds : Set.Set String
    , pendingConfirm : List PendingConfirm
    , pendingMcpAuth : Maybe PendingConfirm
    , mcpStatus : Maybe String
    , messageVersion : Maybe Int
    , reasoningLevel : Maybe Int
    , activeTheme : Maybe String
    , themes : Maybe (List ThemeInfo)
    , videoFps : Maybe Int
    , videoRes : Maybe Int
    }


type alias ModelInfo =
    { id : Int
    , name : String
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
    , notifications = []
    , input = ""
    , sendPending = False
    , processedEchoIds = Set.empty
    , collapsedMsgIds = Set.empty
    , pendingConfirm = []
    , pendingMcpAuth = Nothing
    , mcpStatus = Nothing
    , messageVersion = Nothing
    , reasoningLevel = Nothing
    , activeTheme = Nothing
    , themes = Nothing
    , videoFps = Nothing
    , videoRes = Nothing
    }
