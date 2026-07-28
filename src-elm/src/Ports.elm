port module Ports exposing
    ( -- Inbound events (Tauri → Elm)
      onDelta
    , onFrame
    , onStatus
      -- Outbound commands (Elm → Tauri)
    , createSession
    , closeSession
    , sendPrompt
    , cancelTask
    , setModel
    , confirmTool
    , sendCommand
    , forkSession
    , resumeSession
    , listSessionDirs
    , deleteSessionDir
    , fsListDir
    , fsReadFileDataUri
    , fsResolvePath
    , fsHomeDir
      -- Window operations
    , openUrl
      -- Existence
    , isSessionConnected
    , listModels
    , -- MCP Auth Flow
      startMcpAuthFlow
    , fillMcpAuthUrl
    , onMcpAuthUrl
      -- Display navigation
    , scrollBy
    , scrollToY
    , blurInput
    , copyToClipboard
      -- Inbound subscriptions (Tauri → Elm responses)
    , onSessionCreated
    , onSessionClosed
    , onSessionDirs
    , onFsListDir
    , onFsHomeDir
    , onFsReadFileDataUri
    , onFsResolvePath
    , onStderrLog
    , scrollToBottom
    , focusElement
    , scrollIntoView
    , onScroll
    , onWindowMaximized
    , getStderrLog
    )

import Json.Decode as D
import Json.Encode as E


-- Inbound events (Tauri → Elm via JS bridge, use E.Value for custom decoding)

port onDelta : (E.Value -> msg) -> Sub msg
port onFrame : (E.Value -> msg) -> Sub msg
port onStatus : (E.Value -> msg) -> Sub msg


-- Outbound commands (Elm → Tauri via JS bridge)

port createSession : { toolConfirm : Maybe String } -> Cmd msg
port closeSession : { sessionId : String } -> Cmd msg
port sendPrompt : { sessionId : String, text : String, media : List E.Value } -> Cmd msg
port cancelTask : { sessionId : String } -> Cmd msg
port setModel : { sessionId : String, modelId : Int } -> Cmd msg
port confirmTool : { sessionId : String, id : String, allowed : Bool } -> Cmd msg
port sendCommand : { sessionId : String, command : String } -> Cmd msg
port forkSession : { sourceSessionId : String, historyId : String } -> Cmd msg
port resumeSession : { sessionId : String } -> Cmd msg
port listSessionDirs : {} -> Cmd msg
port deleteSessionDir : { sessionId : String } -> Cmd msg
port fsListDir : { path : String } -> Cmd msg
port fsReadFileDataUri : { path : String } -> Cmd msg
port fsResolvePath : { path : String } -> Cmd msg
port fsHomeDir : {} -> Cmd msg
port openUrl : { url : String } -> Cmd msg
port isSessionConnected : { sessionId : String } -> Cmd msg
port listModels : {} -> Cmd msg
port startMcpAuthFlow : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg
port fillMcpAuthUrl : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg
port onMcpAuthUrl : (String -> msg) -> Sub msg
port scrollBy : { dx : Float, dy : Float } -> Cmd msg
port scrollToY : { y : Float } -> Cmd msg
port blurInput : {} -> Cmd msg
port copyToClipboard : { text : String } -> Cmd msg


-- Inbound responses (Tauri → Elm for command results)

port onSessionCreated : (String -> msg) -> Sub msg
port onSessionClosed : (String -> msg) -> Sub msg
port onSessionDirs : (List E.Value -> msg) -> Sub msg
port onFsListDir : (List E.Value -> msg) -> Sub msg
port onFsHomeDir : (String -> msg) -> Sub msg
port onFsResolvePath : (E.Value -> msg) -> Sub msg
port onFsReadFileDataUri : (String -> msg) -> Sub msg

-- Debug / Logging

port getStderrLog : { sessionId : String } -> Cmd msg
port onStderrLog : (List String -> msg) -> Sub msg

-- Focus / Scroll

port scrollToBottom : {} -> Cmd msg
port focusElement : String -> Cmd msg
port scrollIntoView : String -> Cmd msg
port onScroll : ({ scrollTop : Float, scrollHeight : Float, clientHeight : Float } -> msg) -> Sub msg

-- Window state

port onWindowMaximized : (Bool -> msg) -> Sub msg
