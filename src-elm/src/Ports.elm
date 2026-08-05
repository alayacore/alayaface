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
    , modelSync
      -- Default (global) model list editor
    , listDefaultModels
    , syncDefaultModels
    , onDefaultModelsList
    , onDefaultModelsSyncResult
      -- Default (global) MCP server editor
    , listDefaultMcp
    , syncDefaultMcp
    , onDefaultMcpList
    , onDefaultMcpSyncResult
      -- Global settings
    , listGlobalSettings
    , syncGlobalSettings
    , onGlobalSettingsList
    , onGlobalSettingsSyncResult
      -- Presets
    , listPresets
    , copyPreset
    , renamePreset
    , deletePreset
    , setActivePreset
    , onPresetsList
    , onPresetActionResult
      -- Session
    , confirmTool
    , sendMcpDecline
    , sendMcpCancel
    , forkSession
    , resumeSession
    , listSessionDirs
    , deleteSessionDir
    , onSessionCreated
    , onSessionDirs
    , onSessionActionResult
      -- File system
    , fsListDir
    , fsReadFileDataUri
    , fsResolvePath
    , fsHomeDir
    , onFsListDir
    , onFsHomeDir
    , onFsResolvePath
    , onFsReadFileDataUri
      -- MCP Auth Flow
    , startMcpAuthFlow
    , fillMcpAuthUrl
      -- Focus / Scroll
    , scrollToBottom
    , setCursorPos
    , scrollIntoView
    , onScroll
      -- Window state
    , onWindowMaximized
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
port modelSync : { sessionId : String, config : String } -> Cmd msg
port listDefaultModels : { preset : String } -> Cmd msg
port syncDefaultModels : { preset : String, config : String } -> Cmd msg
port onDefaultModelsList : (E.Value -> msg) -> Sub msg
port onDefaultModelsSyncResult : (E.Value -> msg) -> Sub msg
port listDefaultMcp : { preset : String } -> Cmd msg
port syncDefaultMcp : { preset : String, config : String } -> Cmd msg
port onDefaultMcpList : (E.Value -> msg) -> Sub msg
port onDefaultMcpSyncResult : (E.Value -> msg) -> Sub msg
port listGlobalSettings : { preset : String } -> Cmd msg
port syncGlobalSettings : { preset : String, toolConfirm : String } -> Cmd msg
port onGlobalSettingsList : (E.Value -> msg) -> Sub msg
port onGlobalSettingsSyncResult : (E.Value -> msg) -> Sub msg
port listPresets : {} -> Cmd msg
port copyPreset : { source : String, name : String } -> Cmd msg
port renamePreset : { oldName : String, newName : String } -> Cmd msg
port deletePreset : { name : String } -> Cmd msg
port setActivePreset : { name : String } -> Cmd msg
port onPresetsList : (E.Value -> msg) -> Sub msg
port onPresetActionResult : (E.Value -> msg) -> Sub msg
port confirmTool : { sessionId : String, id : String, allowed : Bool } -> Cmd msg
port sendMcpDecline : { sessionId : String, server : String } -> Cmd msg
port sendMcpCancel : { sessionId : String } -> Cmd msg
port forkSession : { sourceSessionId : String, historyId : String } -> Cmd msg
port resumeSession : { sessionId : String } -> Cmd msg
port listSessionDirs : {} -> Cmd msg
port deleteSessionDir : { sessionId : String } -> Cmd msg
port fsListDir : { path : String } -> Cmd msg
port fsReadFileDataUri : { path : String } -> Cmd msg
port fsResolvePath : { path : String } -> Cmd msg
port fsHomeDir : {} -> Cmd msg
port startMcpAuthFlow : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg
port fillMcpAuthUrl : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg


-- Inbound responses (Tauri → Elm for command results)

port onSessionCreated : (String -> msg) -> Sub msg
port onSessionDirs : (List E.Value -> msg) -> Sub msg
port onSessionActionResult : (E.Value -> msg) -> Sub msg
port onFsListDir : (List E.Value -> msg) -> Sub msg
port onFsHomeDir : (String -> msg) -> Sub msg
port onFsResolvePath : (E.Value -> msg) -> Sub msg
port onFsReadFileDataUri : (String -> msg) -> Sub msg


-- Focus / Scroll

port scrollToBottom : { sessionId : String } -> Cmd msg
port setCursorPos : String -> Cmd msg
port scrollIntoView : String -> Cmd msg
port onScroll : ({ scrollTop : Float, scrollHeight : Float, clientHeight : Float } -> msg) -> Sub msg


-- Window state

port onWindowMaximized : (Bool -> msg) -> Sub msg
