port module Ports exposing
    ( -- Inbound events (Tauri → Elm)
      onDelta
    , onFrame
    , onStatus
    , onRpcError
      -- Outbound commands (Elm → Tauri)
    , createSession
    , closeSession
    , sendPrompt
    , cancelTask
    , setModel
    , setReasoningLevel
    , modelSync
      -- Default (global) model list editor
    , listDefaultModels
    , syncDefaultModels
    , setDefaultModel
    , onDefaultModelsList
    , onDefaultModelsSyncResult
    , onDefaultModelSetResult
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
      -- Global config overlay (cross-preset)
    , getGlobalConfig
    , syncGlobalConfig
    , onGlobalConfigGet
    , onGlobalConfigSync
      -- Voice input ASR config overlay (cross-preset)
    , getAsrConfig
    , syncAsrConfig
    , onAsrConfigGet
    , onAsrConfigSync
      -- Voice input (recording / transcription / cursor insertion)
    , voiceStart
    , voiceStop
    , onVoiceError
    , onAsrResult
    , getCursorPos
    , onCursorPos
      -- Raw audio input (record → send WAV as a UA frame)
    , rawAudioStart
    , rawAudioStop
    , onRawAudioReady
    , onRawAudioError
    , onCaptureAutoStop
      -- Presets
    , listPresets
    , copyPreset
    , renamePreset
    , deletePreset
    , reorderPresets
    , onPresetsList
    , onPresetActionResult
      -- Session
    , confirmTool
    , sendMcpDecline
    , sendMcpCancel
    , forkSession
    , cascadeForkSession
    , resumeSession
    , listSessionDirs
    , deleteSessionDir
    , closeAllSessions
    , setConnectionChain
    , onSessionCreated
    , onSessionCreateError
    , onSessionDirs
    , onSessionActionResult
    , onCascadeForkResult
      -- File system
    , fsListDir
    , fsReadFileDataUri
    , fsResolvePath
    , fsHomeDir
    , fsWriteFileText
    , fsReadFileText
    , onFsListDir
    , onFsHomeDir
    , onFsResolvePath
    , onFsReadFileDataUri
    , onFsWriteResult
    , onFsReadResult
      -- Content-addressed object store (C architecture)
    , objectPut
    , objectGet
    , onObjectPut
    , onObjectGet
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
      -- Canvas zoom (wheel from bridge.js, non-passive so the browser
      -- page zoom / scroll can be prevented)
    , onCanvasWheel
      -- Unified pointer input (touch & pointer design): raw events from
      -- the transport.js dumb pipe; the gesture FSM lives in Elm.
    , onPointerDown
    , onPointerMove
    , onPointerUp
    , onPointerCancel
    , longPressMenuOpened
    )

import Json.Encode as E
import App.NodeConnection as NC


-- Inbound events (Tauri → Elm via JS bridge, use E.Value for custom decoding)

port onDelta : (E.Value -> msg) -> Sub msg
port onFrame : (E.Value -> msg) -> Sub msg
port onStatus : (E.Value -> msg) -> Sub msg

-- Backend RPC failures surfaced to the UI (e.g. alayacore_send_prompt
-- rejected because the session disconnected): { kind, sessionId, message }.
port onRpcError : (E.Value -> msg) -> Sub msg


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
port setReasoningLevel : { sessionId : String, level : Int } -> Cmd msg
port modelSync : { sessionId : String, config : String } -> Cmd msg
port listDefaultModels : { preset : String } -> Cmd msg
port syncDefaultModels : { preset : String, config : String } -> Cmd msg
port setDefaultModel : { preset : String, modelId : Int } -> Cmd msg
port onDefaultModelsList : (E.Value -> msg) -> Sub msg
port onDefaultModelsSyncResult : (E.Value -> msg) -> Sub msg
port onDefaultModelSetResult : (E.Value -> msg) -> Sub msg
port listDefaultMcp : { preset : String } -> Cmd msg
port syncDefaultMcp : { preset : String, config : String } -> Cmd msg
port onDefaultMcpList : (E.Value -> msg) -> Sub msg
port onDefaultMcpSyncResult : (E.Value -> msg) -> Sub msg
port listGlobalSettings : { preset : String } -> Cmd msg
port syncGlobalSettings : { preset : String, toolConfirm : String, builtinTools : String, systemPrompt : String, reasoningLevel : Int } -> Cmd msg
port onGlobalSettingsList : (E.Value -> msg) -> Sub msg
port onGlobalSettingsSyncResult : (E.Value -> msg) -> Sub msg
port getGlobalConfig : {} -> Cmd msg
port syncGlobalConfig : { recursionLimit : Int } -> Cmd msg
port onGlobalConfigGet : (E.Value -> msg) -> Sub msg
port onGlobalConfigSync : (E.Value -> msg) -> Sub msg
port getAsrConfig : {} -> Cmd msg
port syncAsrConfig : { config : String } -> Cmd msg
port onAsrConfigGet : (E.Value -> msg) -> Sub msg
port onAsrConfigSync : (E.Value -> msg) -> Sub msg

-- Voice input: the webview records microphone audio (getUserMedia →
-- 16kHz mono PCM → WAV) while voiceStart..voiceStop is active, then
-- sends the audio to asr_transcribe. Results and mic errors come back
-- on onAsrResult / onVoiceError as { sessionId, ok, text, error } /
-- { sessionId, message }.
port voiceStart : { sessionId : String } -> Cmd msg
port voiceStop : { sessionId : String } -> Cmd msg
port onVoiceError : (E.Value -> msg) -> Sub msg
port onAsrResult : (E.Value -> msg) -> Sub msg

-- Raw audio input: same capture, but the WAV is sent straight to
-- AlayaCore as a UA (user audio) frame — JS emits onRawAudioReady
-- { sessionId, uri } (data:audio/wav;base64,…) and Elm stages it and
-- sends immediately. Mic errors come back on onRawAudioError
-- { sessionId, message }.
port rawAudioStart : { sessionId : String } -> Cmd msg
port rawAudioStop : { sessionId : String } -> Cmd msg
port onRawAudioReady : (E.Value -> msg) -> Sub msg
port onRawAudioError : (E.Value -> msg) -> Sub msg

-- Both recorders auto-stop after 60s (the JS capture timer); the
-- bridge notifies Elm so the button/input states reset — after which
-- the same finish path runs as a manual stop (ASR → transcribe,
-- raw → encode + onRawAudioReady).
port onCaptureAutoStop : (E.Value -> msg) -> Sub msg

-- Input cursor: Elm owns session.input but not the textarea caret, so
-- the voice insert flow reads selectionStart from JS right before
-- inserting (getCursorPos → onCursorPos { sessionId, pos }).
port getCursorPos : { sessionId : String } -> Cmd msg
port onCursorPos : (E.Value -> msg) -> Sub msg
port listPresets : {} -> Cmd msg
port copyPreset : { source : String, name : String } -> Cmd msg
port renamePreset : { oldName : String, newName : String } -> Cmd msg
port deletePreset : { name : String } -> Cmd msg
-- Preset Manager drag-to-reorder: full ordered name list persisted by
-- the backend (preset_order.conf).
port reorderPresets : { names : List String } -> Cmd msg
port onPresetsList : (E.Value -> msg) -> Sub msg
port onPresetActionResult : (E.Value -> msg) -> Sub msg
port confirmTool : { sessionId : String, id : String, allowed : Bool } -> Cmd msg
port sendMcpDecline : { sessionId : String, server : String } -> Cmd msg
port sendMcpCancel : { sessionId : String } -> Cmd msg
port forkSession : { sourceSessionId : String, historyId : String } -> Cmd msg
-- P38: fork used by the re-run cascade to TRUNCATE a parent session's
-- history (the fork's session.alaya only contains messages up to the
-- given history id). Carries the plan-node attributes so the fork can
-- replace the node session in place (same nested dir, same config /
-- tools / plan system prompt). Result arrives on onCascadeForkResult.
port cascadeForkSession :
    { sourceSessionId : String
    , historyId : String
    , toolConfirm : String
    , preset : String
    , builtinTools : Maybe String
    , systemPrompt : String
    , workDir : String
    , planId : String
    , nodeId : String
    , originSessionId : String
    }
    -> Cmd msg
port resumeSession : { sessionId : String, workDir : Maybe String, planId : Maybe String, nodeId : Maybe String, originSessionId : Maybe String } -> Cmd msg
port listSessionDirs : {} -> Cmd msg
port deleteSessionDir : { sessionId : String, planId : Maybe String, nodeId : Maybe String, originSessionId : Maybe String } -> Cmd msg

-- Reclaim orphaned sessions after a page refresh: the backend still
-- holds handles for sessions whose windows died with the old page, so
-- resume_session would keep failing with "Session is already active".
-- The frontend fires this once on init (graceful close, history kept).
port closeAllSessions : {} -> Cmd msg

-- Connection chain (P36/P39): Elm tells bridge.js EVERY segment of the
-- active connection path — from the focused session (or active plan
-- window) up through each ancestor plan↔session pair to the TOP-LEVEL
-- session — plus the CANVAS state needed to draw curves in CANVAS
-- coordinates inside the canvas layer (Phase A: no body-level SVG, no
-- per-frame rAF):
--   segments   — the chain ([] = hide all);
--   positions  — every open window's canvas rect + z (chain.js never
--                measures window positions; Elm knows them);
--   canvasScale — stroke-width is compensated: 3 / canvasScale so a
--                curve stays 3 screen px at any zoom.
-- Points INSIDE a window (node cards, the [Plan: …] button) are derived
-- by chain.js from a getBoundingClientRect DIFFERENCE against the
-- window — inner scroll offsets are included automatically, and
-- chain.js redraws on inner scroll events itself. [] = hide all.
port setConnectionChain :
    { segments : List NC.ChainSegment
    , positions : List { id : String, x : Int, y : Int, w : Int, h : Int, z : Int }
    , canvasScale : Float
    }
    -> Cmd msg

port fsListDir : { reqId : String, path : String } -> Cmd msg
port fsReadFileDataUri : { path : String } -> Cmd msg
port fsResolvePath : { path : String } -> Cmd msg
port fsHomeDir : {} -> Cmd msg
port fsWriteFileText : { path : String, content : String, createParents : Bool } -> Cmd msg
port fsReadFileText : { reqId : String, path : String } -> Cmd msg
-- C architecture: content-addressed object store. objectPut stores the
-- content and returns its sha256 hash (dedup by content); objectGet
-- reads an object back by hash.
port objectPut : { reqId : String, content : String } -> Cmd msg
port objectGet : { reqId : String, hash : String } -> Cmd msg
port startMcpAuthFlow : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg
port fillMcpAuthUrl : { sessionId : String, serverName : String, authUrl : String } -> Cmd msg


-- Inbound responses (Tauri → Elm for command results)

port onSessionCreated : (String -> msg) -> Sub msg
port onSessionCreateError : (String -> msg) -> Sub msg
-- { ok, dirs, error }
port onSessionDirs : (E.Value -> msg) -> Sub msg
port onSessionActionResult : (E.Value -> msg) -> Sub msg
-- P38: { ok, sessionId, error } — the new (truncated) session created
-- by a cascade fork.
port onCascadeForkResult : (E.Value -> msg) -> Sub msg
-- { reqId, ok, entries, error } — reqId matches the fsListDir request so
-- the plan-meta scan and the file picker can never steal each other's
-- results (both share the same untagged port).
port onFsListDir : (E.Value -> msg) -> Sub msg
-- { ok, home, error }
port onFsHomeDir : (E.Value -> msg) -> Sub msg
port onFsResolvePath : (E.Value -> msg) -> Sub msg
-- { ok, uri, error }
port onFsReadFileDataUri : (E.Value -> msg) -> Sub msg
port onFsWriteResult : (E.Value -> msg) -> Sub msg
-- { reqId, ok, content, error } — reqId matches the fsReadFileText
-- request (meta scan / plan open / run load share the same port).
port onFsReadResult : (E.Value -> msg) -> Sub msg
-- { reqId, ok, hash, error } — reqId matches the objectPut request.
port onObjectPut : (E.Value -> msg) -> Sub msg
-- { reqId, ok, content, error } — reqId matches the objectGet request.
port onObjectGet : (E.Value -> msg) -> Sub msg


-- Focus / Scroll

port scrollToBottom : { sessionId : String } -> Cmd msg
-- Move the caret: id = element id, pos = Nothing moves to the end of
-- the value (legacy behavior), Just pos sets the caret exactly there.
port setCursorPos : { id : String, pos : Maybe Int } -> Cmd msg
port scrollIntoView : String -> Cmd msg
port onScroll : ({ sessionId : String, scrollTop : Float, scrollHeight : Float, clientHeight : Float } -> msg) -> Sub msg


-- Window state

port onWindowMaximized : (Bool -> msg) -> Sub msg


-- Canvas zoom: bridge.js forwards wheel events (with native scroll /
-- browser zoom prevented) as { deltaY, clientX, clientY }.
port onCanvasWheel : (E.Value -> msg) -> Sub msg

-- Unified pointer input (touch & pointer design D1/D2): transport.js
-- forwards raw pointer events from a dumb pipe that classifies the
-- target (canvas/bar/handle/content/menu/overlay), captures + prevent-
-- defaults draggable surfaces, and forwards:
--   { pointerId, pointerType, button, clientX, clientY, targetKind,
--     sessionId, planId, handle }
-- The gesture state machine (drag/pinch/long-press) lives in Elm.
port onPointerDown : (E.Value -> msg) -> Sub msg
port onPointerMove : (E.Value -> msg) -> Sub msg
port onPointerUp : (E.Value -> msg) -> Sub msg
port onPointerCancel : (E.Value -> msg) -> Sub msg

-- Touch long-press menu opened (D5): Elm tells transport.js so it can
-- swallow the click that the finger release produces — otherwise the
-- release click bubbles to .app and closes the menu it just opened.
-- The 500ms threshold lives only in App/Pointer.longPressMs.
port longPressMenuOpened : () -> Cmd msg
