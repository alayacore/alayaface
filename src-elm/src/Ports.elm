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
    , setNodeConnection
    , setPlanConnection
    , onSessionCreated
    , onSessionCreateError
    , onSessionDirs
    , onSessionActionResult
      -- File system
    , fsListDir
    , fsReadFileDataUri
    , fsResolvePath
    , fsHomeDir
    , fsWriteFileText
    , fsReadFileText
    , fsDeleteFile
    , onFsListDir
    , onFsHomeDir
    , onFsResolvePath
    , onFsReadFileDataUri
    , onFsWriteResult
    , onFsReadResult
    , onFsDeleteResult
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

import Json.Encode as E
import App.NodeConnection


-- Inbound events (Tauri → Elm via JS bridge, use E.Value for custom decoding)

port onDelta : (E.Value -> msg) -> Sub msg
port onFrame : (E.Value -> msg) -> Sub msg
port onStatus : (E.Value -> msg) -> Sub msg


-- Outbound commands (Elm → Tauri via JS bridge)

-- originSessionId/planId/nodeId (optional): plan NODE sessions are
-- created/resumed nested under
-- sessions/<originSessionId>/plans/<planId>/<nodeId>/ on disk (every
-- plan lives inside the session that created it); plain sessions omit
-- them and stay at sessions/<uuid>/ (top level = never a plan child).
port createSession : { toolConfirm : Maybe String, preset : Maybe String, builtinTools : Maybe String, systemPrompt : Maybe String, workDir : Maybe String, planId : Maybe String, nodeId : Maybe String, originSessionId : Maybe String } -> Cmd msg
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
port syncGlobalSettings : { preset : String, toolConfirm : String, builtinTools : String } -> Cmd msg
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
port resumeSession : { sessionId : String, workDir : Maybe String, planId : Maybe String, nodeId : Maybe String, originSessionId : Maybe String } -> Cmd msg
port listSessionDirs : {} -> Cmd msg
port deleteSessionDir : { sessionId : String, planId : Maybe String, nodeId : Maybe String, originSessionId : Maybe String } -> Cmd msg

-- Node↔session connection curve (P19): Elm tells bridge.js which pair to
-- connect (Nothing = hide). bridge.js measures the DOM and draws a bezier.
port setNodeConnection : Maybe App.NodeConnection.NodeConnection -> Cmd msg

-- Plan window ↔ owning session curve: Elm tells bridge.js which plan
-- window to connect to which (live) session window (Nothing = hide).
port setPlanConnection : Maybe App.NodeConnection.PlanConnection -> Cmd msg

port fsListDir : { path : String } -> Cmd msg
port fsReadFileDataUri : { path : String } -> Cmd msg
port fsResolvePath : { path : String } -> Cmd msg
port fsHomeDir : {} -> Cmd msg
port fsWriteFileText : { path : String, content : String, createParents : Bool } -> Cmd msg
port fsReadFileText : { path : String } -> Cmd msg
port fsDeleteFile : { path : String } -> Cmd msg
port startMcpAuthFlow : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg
port fillMcpAuthUrl : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg


-- Inbound responses (Tauri → Elm for command results)

port onSessionCreated : (String -> msg) -> Sub msg
port onSessionCreateError : (String -> msg) -> Sub msg
port onSessionDirs : (List E.Value -> msg) -> Sub msg
port onSessionActionResult : (E.Value -> msg) -> Sub msg
port onFsListDir : (List E.Value -> msg) -> Sub msg
port onFsHomeDir : (String -> msg) -> Sub msg
port onFsResolvePath : (E.Value -> msg) -> Sub msg
port onFsReadFileDataUri : (String -> msg) -> Sub msg
port onFsWriteResult : (E.Value -> msg) -> Sub msg
port onFsReadResult : (E.Value -> msg) -> Sub msg
port onFsDeleteResult : (E.Value -> msg) -> Sub msg


-- Focus / Scroll

port scrollToBottom : { sessionId : String } -> Cmd msg
port setCursorPos : String -> Cmd msg
port scrollIntoView : String -> Cmd msg
port onScroll : ({ sessionId : String, scrollTop : Float, scrollHeight : Float, clientHeight : Float } -> msg) -> Sub msg


-- Window state

port onWindowMaximized : (Bool -> msg) -> Sub msg
