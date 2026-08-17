module App.Types exposing
    ( Flags
    , Model
    , Msg(..)
    , WindowPos
    , ResizeHandle(..)
    , DragKind(..)
    , DragState
    , PinchState
    , LongPress
    , toDragKind
    , handleFromString
    , DefaultModelsEditor
    , emptyDefaultModelsEditor
    , McpEditor
    , emptyMcpEditor
    , SettingsEditor
    , emptySettingsEditor
    , GlobalConfig
    , emptyGlobalConfig
    , GlobalConfigEditor
    , emptyGlobalConfigEditor
    , AsrConfig
    , emptyAsrConfig
    , AsrProfile
    , AsrConfigEditor
    , emptyAsrConfigEditor
    , PresetInfo
    , PresetManager
    , emptyPresetManager
    , PlanViewState
    , emptyPlanView
    , PlanWindow
    , emptyPlanWindow
    , PlanReadTarget
    , CreateTask(..)
    )

{-| Application-level model, message, and editor/window types.

Kept separate from Main so the update and view modules can operate on
the app state without importing each other (Main imports all three).
The session-level types live in Session/Types.elm.
-}

import Browser.Dom as Dom
import Dict exposing (Dict)
import Json.Encode as E
import Set exposing (Set)
import Plan.Types as PT
import Plan.Runner as R
import Plan.Meta as PM
import Plan.Cascade as PC
import Session.Selector as Sel
import Session.Types as T
import App.NodeConnection as NC
import App.Pointer as P
import Arch.Values as AV
import Arch.Freeze as Freeze


type alias Flags =
    ()


-- MODEL

type alias Model =
    { sessions : Dict String T.SessionState
    , activeId : Maybe String
    , showSessionManager : Bool
    , sessionDirs : List E.Value
    , sessionManagerError : Maybe String
    , isMaximized : Bool
    , sessionOrder : List String
    , pendingSwitchOnCreate : Bool
    , inputRows : Int
    , cursorMsgId : Maybe String
    , pendingEvents : Dict String (List E.Value)
    , sessionNums : Dict String Int
    , nextSessionNum : Int
    , windowPositions : Dict String WindowPos
    , nextZIndex : Int
    -- Infinite canvas: the viewport (main-content) shows a slice of an
    -- unbounded canvas. Windows are positioned in CANVAS coordinates;
    -- canvasOffset is the translate3d applied to the canvas layer
    -- (viewport = canvas + offset). Dragging the empty background pans
    -- the canvas instead of moving a window.
    , canvasOffset : { x : Int, y : Int }
    -- Zoom factor applied to the canvas layer (screen = canvas * scale
    -- + offset). Kept GPU-composited: transform becomes
    -- translate3d(offset) scale(scale), origin stays 0 0.
    , canvasScale : Float
    -- Unified pointer/gesture state (D4/D5): ONE drag state covers
    -- canvas pan, window move and resize; activePointers tracks every
    -- live pointer (for pinch and for drag-end attribution); pinch is
    -- the two-pointer canvas zoom; longPress is the touch menu gesture.
    , activePointers : Dict Int P.PointerInfo
    , drag : Maybe DragState
    , pinch : Maybe PinchState
    , longPress : Maybe LongPress
    , showGlobalMenu : Bool
    -- Where the global menu pops up (right-click position, viewport
    -- coordinates) when opened via context menu on the canvas.
    , globalMenuX : Int
    , globalMenuY : Int
    , defaultModelsEditor : DefaultModelsEditor
    , mcpEditor : McpEditor
    , settingsEditor : SettingsEditor
    -- Cross-preset global config overlay (~/.alayaface/global.conf).
    -- RecursionLimit bounds Plan Mode recursion: node sessions of a plan
    -- whose depth exceeds it get no plan system prompt.
    , globalConfig : GlobalConfig
    , globalConfigEditor : GlobalConfigEditor
    -- Voice-input ASR config overlay (~/.alayaface/asr.conf): an
    -- OpenAI-compatible /audio/transcriptions endpoint (local or remote
    -- — the two only differ by URL).
    , asrConfig : AsrConfig
    , asrConfigEditor : AsrConfigEditor
    -- Pending voice transcript waiting for the input cursor position
    -- (read from the textarea right before inserting, so the text lands
    -- where the user's caret currently is).
    , pendingVoiceInsert : Maybe { sessionId : String, text : String }
    , presets : List PresetInfo
    -- Hover flyout state for the global menu's "New Session" item:
    -- True while the pointer is over the item or its preset submenu.
    , presetSubmenuOpen : Bool
    , presetManager : PresetManager
    , ctxVisible : Bool
    , ctxX : Int
    , ctxY : Int
    , ctxHistoryId : String
    , ctxSessionId : String
    , appWidth : Int
    , appHeight : Int
      -- Plan Mode
    , planWindows : Dict String PlanWindow
    -- Runtime metadata (sessions/<origin>/plans/<planId>/<planId>.meta.json):
    -- origin session/message binding + feedbacks. Keyed by planId; used
    -- for the message status bar and feedback routing. Rebuilt from disk
    -- on session open (R3): sessions/ is listed, then each session's
    -- plans/ dir, then every *.meta.json is read.
    , planMetas : Dict String PM.PlanMeta
    -- Loading state for planMetas: a dedicated fs_list_dir/fs_read chain
    -- that bypasses planReadTarget (single-slot) and the manager UI.
    , planMetaLoading : Bool
    -- Set by FsHomeDirResult; the meta scan starts only AFTER the
    -- session file-picker's home listing has been consumed (both are
    -- fs_list_dir results with no path tag — firing them in the same
    -- batch lets the home listing be misrouted into the scan and
    -- desynchronize it, leaving planMetas empty after a restart).
    , planMetaScanPending : Bool
    -- Directory scan: planMetaDirQueue holds the remaining directories
    -- to list across ALL levels (sessions/<uuid>/plans, then each
    -- <planId>/, then each <nodeId>/); planMetaDirListing is the dir
    -- whose listing the next FsListDirResult belongs to (Nothing + empty
    -- queue while loading = waiting for the sessions/ listing).
    , planMetaDirQueue : List String
    , planMetaDirListing : Maybe String
    -- The meta.json path currently being read (head of the rebuild
    -- chain); planMetaReadQueue holds the remaining paths.
    , planMetaReading : Maybe String
    , planMetaReadQueue : List String
    -- reqId of the scan's in-flight fs_list_dir (sessions/ listing or a
    -- plans/ dir listing). fs_list_dir responses are routed by reqId:
    -- a response whose reqId matches this is a scan listing; anything
    -- else belongs to the file picker — so the scan can never swallow
    -- (or be corrupted by) a user-initiated listing that races it.
    , planMetaScanReqId : Maybe String
    -- reqId of the scan's in-flight meta.json read. fs_read_file_text
    -- responses are routed by reqId: matching here = the meta rebuild
    -- chain; matching planReadTarget = an open/load read; neither = a
    -- stale response (ignored).
    , planMetaReadReqId : Maybe String
    -- C architecture: session.refs.json paths (sessions/<uuid>/session.refs.json),
    -- collected from the sessions/ listing, read one at a time to
    -- register each session's root refs.
    , planMetaSessionQueue : List String
    -- C3-2: nested node-session session.refs.json paths (sessions/<origin>/
    -- plans/<planId>/<nodeId>/<uuid>/session.refs.json) — after a node
    -- cascade fork records a workCopy, restart DAG recovery restores
    -- from the work-copy directory.
    , planMetaNodeRefsQueue : List String
    -- P28 layout fix: every known session id → its ON-DISK DIRECTORY.
    -- Top-level sessions live at sessions/<id>; plan NODE sessions are
    -- NESTED at sessions/<origin>/plans/<planId>/<nodeId>/<id>. Plans
    -- created by a node session must live inside that nested dir — using
    -- the id to join sessions/<id> leaked plan children to the sessions/
    -- top level. Recorded at SessionCreated, rebuilt by the meta scan.
    -- (sessionDirMap, to distinguish from `sessionDirs` = the manager list)
    , sessionDirMap : Dict String String
    -- Monotonic counter for fs request ids (fsListDir/fsReadFileText
    -- only — the two ports shared by the plan-meta scan and the normal
    -- UI flows). Every request gets a unique id so responses can be
    -- attributed to the flow that issued them.
    , fsReqCounter : Int
    -- Last known run status per plan (survives the auto-close of a
    -- Completed plan window — the status bar needs it). Updated on every
    -- runStepIn; not persisted (rebuilt when the window reopens).
    , planRunStatuses : Dict String PT.RunStatus
    -- P38 re-run cascade (§7.4): impact-scope confirmation shown before a
    -- re-run that would truncate parent sessions / cascade upward.
    , planCascadePreview : Maybe PC.ImpactScope
    -- Active cascade execution state; Nothing = no cascade in flight.
    , planCascade : Maybe PC.CascadeState
    -- Ancestor plan windows being REOPENED (async) after the confirm —
    -- their runs are needed to resume nodes and capture old summaries
    -- (ancestors auto-close on completion, D11). The root run starts
    -- once the queue drains.
    , planCascadeOpenQueue : List String
    -- Plans closed (and stopped) because they live inside a truncated
    -- region: their completion must NOT insert feedback anywhere.
    , planSuppressFeedback : Set String
    -- P38: a fork issued to truncate a parent session (awaiting its
    -- result); the adoption rewrites bindings/meta and continues.
    , planCascadeFork : Maybe PC.CascadeForkTarget
    -- A cascade-truncation failure (fork could not be issued or failed):
    -- the reason is shown on the plan window's error banner, the cascade
    -- has ended, and NOTHING was truncated or inserted (a non-durable
    -- in-memory truncation would resurrect after a restart). Non-Nothing
    -- also keeps the completed plan window open so the error stays
    -- visible. Cleared when a new run / confirm / cancel starts.
    , planCascadeError : Maybe String
    -- P39/D1: the ownership-graph close set currently being torn down
    -- (every session + plan id collected in ONE traversal by
    -- CloseSession / PlanClose). While non-empty, nested CloseSession /
    -- PlanClose dispatches (from StopRun's closeAndClear, from a plan's
    -- node sessions) take the MINIMAL branch — close the window /
    -- process only, never re-collect — so the graph is traversed
    -- exactly once and `PlanClose ⇄ CloseSession` mutual recursion is
    -- gone. Always cleared by the time the initiating update returns.
    , closeSet : Set String
    -- Incremental per-session plan-message counts (M3/D4): how many
    -- messages of each session are plan messages (same predicate as
    -- Plan.Detect.isPlanMessage). Maintained O(1) per frame — a message
    -- bumps the counter exactly when its accumulated content crosses
    -- the ```json fence (becamePlanMessage) — replacing the O(n)
    -- planIndexForMessage scan in the per-frame AT path. Seeded from
    -- planIndexForMessage once at SessionCreated (buffered replay).
    , planMessageCounts : Dict String Int
    -- Sessions that have seen an SM task in_progress:true frame — i.e. a
    -- REAL task started (the node prompt was sent). alayacore emits a
    -- boot task frame (in_progress:false) BEFORE any prompt; gating
    -- TaskDone on this set stops that boot frame from being mistaken for
    -- a task completion (which marked the node Succeeded and canceled its
    -- just-started session — R5 bug fix).
    , planTaskStarted : Set String
    , planOrder : List String
    , planActiveId : Maybe String
    -- Keyed by (sessionId, planIndex) — the plan message's index within
    -- its session (message ids are deliberately not used).
    , pendingPlanOffers : Dict ( String, Int ) String
    -- Sessions currently replaying their history after a resume_session:
    -- alayacore replays content frames (UT/AT/AR/AF/UF) BEFORE any SM
    -- frame, so while a session is in this set, detected plan messages
    -- are history — they must NOT auto-create a plan window (the user
    -- opens them via the status bar or the "Open plan" button). The
    -- first SM frame removes the session from the set (replay done).
    , planReplaySessions : Set String
    , planCreating : Maybe CreateTask
    , planCreateQueue : List CreateTask
    -- Node prompts held until their session's readiness signal arrives
    -- (sessionId → prompt text). alayacore rejects prompts with
    -- MCP_NOT_READY before MCP init completes, so the runner's
    -- SendPrompt effect is deferred and flushed on the ready SM.
    , pendingNodePrompts : Dict String String
    , planReadTarget : Maybe PlanReadTarget
    , planNodeSessions : Dict String String
    -- Plan window owning the in-flight resume (for error surfacing).
    , planResumeOwner : Maybe String
    -- Original (on-disk dir) session id of an in-flight plan-node resume.
    -- The resumed session gets a FRESH id from resume_session; the node
    -- stays bound to the original id (the dir name) so it can always be
    -- resumed again.
    , planResumeFrom : Maybe String
    -- Active connection CHAIN (P36): when the user focuses a session
    -- bound to a plan node — or activates a plan window — this holds
    -- EVERY segment of the path from that window up through each
    -- ancestor plan↔session pair to the TOP-LEVEL session (deep node
    -- sessions show their whole ancestor path, so the lines lead all
    -- the way up to the topmost session window). [] = nothing
    -- connected. bridge.js draws one bezier per segment; Elm only
    -- tracks which segments are connected.
    , connectionChain : List NC.ChainSegment
    , homeDir : String
    -- C architecture (docs/arch-persistent.md): immutable versions —
    -- per-session version refs (session id → refs: head + versions), run
    -- summary cache (hash → RunSummary), version decode cache (hash →
    -- Version), and the freeze queue (serial: one freeze at a time,
    -- reqId 0..n only matches the active item).
    , sessionRefs : Dict String AV.SessionRefs
    , runSummaries : Dict String AV.RunSummary
    , versionCache : Dict String AV.Version
    , freezeActive : Maybe Freeze.FreezeState
    , freezeQueue : List Freeze.FreezeState
    -- C2b (§8.1): maps a Session's stable identity to its current work
    -- copy (alayacore session): Session.id → work-copy coreId. Without
    -- fork/resume the default is itself (missing → itself). Windows and
    -- the manager always use Session.id as identity; commands look up
    -- forward (workCopyId), frames look up backward (sessionIdOfWorkCopy).
    , sessionWorkCopies : Dict String String
    -- C2b: set of temporary resume live core ids (new UUIDs returned by
    -- resume_session, no on-disk directory). persistableWorkCopy uses it
    -- to distinguish "persistable work-copy directories" from "temporary
    -- live" (live does not write refs.workCopy).
    , sessionResumedLives : Set String
    -- C4: message block cache (hash → message list, read-only rendering
    -- for version browsing).
    , blockCache : Dict String (List T.Message)
    -- C4: version-browsing state — the Session.id with an open version
    -- list; the version hash being viewed (+ its Session.id, for the title).
    , versionListFor : Maybe String
    , versionViewFor : Maybe String
    , versionViewSession : Maybe String
    -- Push-to-talk (hold Ctrl+' to talk): ptHeld = the key is currently
    -- held down; ptCreatePending = the next SessionCreated belongs to
    -- the PT create and must auto-start ASR (cleared on keyup, so a
    -- release before the create finishes leaves the session unrecorded);
    -- ptSessionId = the session the current hold records into.
    , ptHeld : Bool
    , ptCreatePending : Bool
    , ptSessionId : Maybe String
    }


-- MSG

type Msg
    = -- Session lifecycle (the preset is chosen from the global menu's
      -- hover submenu — every session runs under an explicit preset)
      CreateSessionWith String
    | SessionCreated String
    | SessionCreateError String
    | CloseSession String
      -- Transport events
    | DeltaEvent E.Value
    | FrameEvent E.Value
    | StatusEvent E.Value
    | RpcError E.Value
      -- C architecture: object-store results (object_put / object_get
      -- matched by reqId)
    | ObjectPutResult E.Value
    | ObjectGetResult E.Value
      -- User actions
    | SendPrompt
    | CancelTask
    | VoiceInput
    | CancelAsr
    | RawAudioInput
    -- Push-to-talk (hold to talk): the Quote key + Ctrl held/released —
    -- down=True/False from overlay.js with shift=True for Ctrl+" .
    -- Ctrl+" opens a NEW session under the built-in "Talk" preset and
    -- starts ASR recording; Ctrl+' records in the CURRENT session
    -- (like the mic button). Release stops either (transcribes).
    | PushToTalk Bool Bool
    -- Close-session confirmation (per-session state, see
    -- SessionState.closeConfirm): RequestCloseSession opens the
    -- session's confirm overlay instead of closing (window ✕ / Ctrl+W);
    -- ConfirmCloseSession and ConfirmDeleteSession execute the choice;
    -- DismissCloseConfirm cancels (Escape or the Cancel button).
    | RequestCloseSession String
    | ConfirmCloseSession String
    | ConfirmDeleteSession String
    | DismissCloseConfirm String
    | RawAudioReady E.Value
    | RawAudioError E.Value
    | CaptureAutoStop E.Value
    | SetModel Int
    | SetReasoningLevel Int
    | ConfirmTool String String Bool
    | McpAuthConfirm String String
    | CloseMcpAuthOverlay String
    | McpAuthDeny String String
    | McpCancelAll String
    | CloseConfirm String
    | CloseMcpInit String
    | ForkMessage String
    | RemoveStaged String
    | ConfirmFilePickerUrl
    | SetInput String
    | SwitchSession String
    -- Attachment drag-drop: files dropped onto the prompt input are
    -- read to data URIs by transport.js and staged here.
    | DroppedFiles E.Value
      -- File picker
    | OpenFilePicker
    | CloseFilePicker
    | SetFilePickerInput String
    | FilePickerNavigateDir String
    | FilePickerSelectItem Int
    | FilePickerConfirmItem
    | FilePickerPickItem Int
    | FilePickerToggleMode
    | FilePickerNavigateUp
    | FsListDirResult E.Value
    | FsHomeDirResult E.Value
    | FsReadFileResult E.Value
    | FsResolvePathResult E.Value
    | FsWriteResult E.Value
    | FsReadResult E.Value
      -- Session manager
    | OpenSessionManager
    | CloseSessionManager
    | SessionDirsResult E.Value
    | SessionActionResult E.Value
    | ResumeSession String
    | DeleteSession String
    -- C3: delete the old work-copy directory (deferred until the old
    -- process has gracefully closed, to avoid a save writing back and
    -- racing the directory recreation). planId/nodeId/originSessionId
    -- locate the nested node work copy (top-level uses "").
    | DeleteWorkCopyDir String String String String
      -- Window
    | WindowMaximized Bool
    | GotContainerSize (Result Dom.Error Dom.Element)
    | RequerySize
      -- Model Selector
    | OpenModelSelector
    | CloseModelSelector
    | SetModelSelectorInput String
    | ModelSelectorSelectItem Int
    | ModelSelectorConfirmItem Int
    | ModelSelectorEditModel Int
    | ModelSelectorAddModel
    | ModelSelectorEditBack
    | ModelSelectorEditSave
    | ModelSelectorEditField String String
    | ModelSelectorDeleteModel Int
    | ModelSelectorConfirmDelete Int
    | ModelSelectorCancelDelete
    | ModelSelectorConfirmSync
    | ModelSelectorDiscardClose
    | ModelSelectorCancelSyncPrompt
    | ModelSelectorSyncResult Bool String
      -- Default (global) model list editor (targets a specific preset)
    | EditPresetModels String
    | CloseDefaultModelsEditor
    | SetDefaultModelsInput String
    | DefaultModelsSelectItem Int
    | DefaultModelsConfirmItem Int
    | DefaultModelsEditModel Int
    | DefaultModelsAddModel
    | DefaultModelsEditBack
    | DefaultModelsEditSave
    | DefaultModelsEditField String String
    | DefaultModelsDeleteModel Int
    | DefaultModelsConfirmDelete Int
    | DefaultModelsCancelDelete
    | DefaultModelsConfirmSync
    | DefaultModelsDiscardClose
    | DefaultModelsCancelSyncPrompt
    | DefaultModelsListResult E.Value
    | DefaultModelsSyncResult E.Value
    -- Set a model as the preset's DEFAULT (runtime.conf active_model);
    -- new sessions under the preset start on it.
    | DefaultModelsSetActive Int
    | DefaultModelsSetActiveResult E.Value
      -- MCP server editor (targets a specific preset)
    | EditPresetMcp String
    | CloseMcpEditor
    | SetMcpInput String
    | McpSelectItem Int
    | McpConfirmItem Int
    | McpEditServer Int
    | McpAddServer
    | McpEditBack
    | McpEditSave
    | McpEditField String String
    | McpDeleteServer Int
    | McpConfirmDelete Int
    | McpCancelDelete
    | McpConfirmSync
    | McpDiscardClose
    | McpCancelSyncPrompt
    | McpListResult E.Value
    | McpSyncResult E.Value
      -- Global settings (targets a specific preset)
    | EditPresetSettings String
    | CloseSettingsEditor
    | SetToolConfirm String
    | SetBuiltinTools String
    | SetSystemPrompt String
    | SetSettingsReasoningLevel Int
    | SettingsSave
    | SettingsListResult E.Value
    | SettingsSyncResult E.Value
      -- Global config overlay (cross-preset)
    | OpenGlobalConfig
    | CloseGlobalConfig
    | SetRecursionLimit String
    | GlobalConfigSave
    | GlobalConfigGetResult E.Value
    | GlobalConfigSyncResult E.Value
      -- Voice input (ASR) overlay (cross-preset): profile list + form
    | OpenAsrConfig
    | CloseAsrConfig
    | AsrConfigAdd
    | AsrConfigEdit String
    | AsrConfigBack
    | AsrConfigSetActive String
    | AsrConfigDelete String
    | AsrConfigDeleteConfirm
    | AsrConfigDeleteCancel
    | SetAsrName String
    | SetAsrProtocol String
    | SetAsrUrl String
    | SetAsrApiKey String
    | SetAsrModel String
    | SetAsrLanguage String
    | AsrConfigSave
    | AsrConfigGetResult E.Value
    | AsrConfigSyncResult E.Value
      -- Voice input (recording / transcription, per-session)
    | VoiceError E.Value
    | AsrResult E.Value
    | CursorPosResult E.Value
      -- Presets
    | OpenPresetManager
    | ClosePresetManager
    | PresetCopy String
    | PresetRenameStart String
    | SetPresetRenameInput String
    | PresetRenameSave String
    | PresetRenameCancel
    | PresetToggleEdit String
    | PresetDelete String
    | PresetConfirmDelete String
    | PresetCancelDelete
    | PresetsListResult E.Value
    | PresetActionResult E.Value
    -- Preset Manager drag-to-reorder: HTML5 DnD on the row drag
    -- handles. Indices are PRESET indices (a preset may render extra
    -- edit rows below its main row).
    | PresetDragStart Int
    | PresetDragOver Int
    | PresetDragEnd
    | PresetDrop Int
    | FillMcpAuthUrl String String
      -- Media preview (click a multimodal chip)
    | OpenMediaPreview T.MediaItem
    | CloseMediaPreview
      -- Plan Mode
    -- (sessionId, planIndex): which plan message of the session (1-based,
    -- counted with Plan.Detect.isPlanMessage). Message ids are NOT used
    -- for binding — they are per-session implementation details.
    | PlanCreateOffer String Int
    -- Manual "Open plan" from a detected-but-not-auto-created plan
    -- message (a history replay suppressed the auto-create).
    | PlanOpenFromMessage String Int
    | PlanSaveReady PT.Plan PM.Origin Int
    -- Status-bar "Open" click on a message-bound plan (R3).
    | PlanStatusOpen String
    | PlanActivate String
    | PlanClose String
    | PlanSelectNode String
    | PlanOpenNodeSession String String
    | PlanOpenAttemptSession String String String
    -- P37: the floating info window ("?" in the plan title bar). Toggle
    -- switches Plan tab ↔ closed; a node click opens the Node tab.
    | PlanToggleInfo
    | PlanCloseInfo
    -- P38 re-run cascade: Run click found an impact scope → confirm;
    -- confirm starts the (possibly ancestor-reopening) cascade, cancel
    -- does nothing.
    | PlanCascadeConfirm
    | PlanCascadeCancel
    -- P38: the fork that truncated a parent session's history finished.
    -- Adopts the fork as the node's session (rebind), rewrites the child
    -- meta origin, closes the original session and continues the chain.
    | PlanCascadeForkResult E.Value
    -- C4: version browsing (read-only view of historical version
    -- messages; D8 does not materialize).
    | OpenVersionList String
    | CloseVersionList
    | ViewVersion String String
    | CloseVersionView
      -- Plan runner
    | PlanRunStart
    | PlanRunStartAt Int
    -- Sub-plans (depth > 1) auto-run right after creation — the
    -- top-level plan's Run button is the single user confirmation gate.
    | PlanAutoRunStart String Int
    | PlanRunPause
    | PlanRunResume
    | PlanRunStop
    -- R4 (D9): re-run skipping succeeded nodes; waiting nodes cascade to
    -- their sub-plans (planId unchanged).
    | PlanRunRestart String
    | PlanRunRetryNode String
    | PlanRunnerTick String String
    | PlanRunFrame Int R.Event
    | PlanBindSession Int String String String
    | PlanResume
      -- Session wrapper
    | ForSession String Msg
      -- Unified pointer input (touch & pointer design D1): raw events
      -- forwarded by transport.js; the gesture FSM lives in Update.
    | PointerDown E.Value
    | PointerMove E.Value
    | PointerUp E.Value
    | PointerCancel E.Value
    | LongPressFired
      -- Canvas zoom centered on the mouse: wheel deltaY + pointer position
    | CanvasZoom Float Float Float
    -- Reset zoom to 100% (click on the zoom indicator), keeping the
    -- viewport center fixed
    | CanvasZoomReset
      -- Instant activation on mousedown
    | ActivateSession String
      -- Context menu
    | ShowCtxMenu Int Int String String
    | HideCtxMenu
    | ForkFromCtx
      -- Message collapse/expand
    | ToggleMsgCollapse String String
      -- Global menu
    | ShowGlobalMenuAt Int Int
    | CloseGlobalMenu
    | SetPresetSubmenu Bool
      -- Internal
    | NoOp
    | KeyDown String Bool Bool Bool
    | ScrollPosition String Float Float Float


-- WINDOW / DRAG STATE

type alias WindowPos =
    { x : Int
    , y : Int
    , z : Int
    , w : Int
    , h : Int
    }


{-| What an in-flight drag is moving (D4): the canvas, a session
window, or a plan window (move or resize). One state replaces the old
canvasDrag / dragInfo / resizeInfo triple.
-}
type DragKind
    = Pan
    | WindowMove String
    | WindowResize String ResizeHandle
    | PlanMove String
    | PlanResize String ResizeHandle


type alias DragState =
    { kind : DragKind
    , pointerId : Int
    , startMouseX : Float
    , startMouseY : Float
    -- True once the pointer passed the drag slop: the drag is in
    -- motion and moves windows / pans / resizes. Until then the
    -- pointerdown is just an armed tap (activation only).
    , active : Bool
    -- Origin snapshot taken at pointerdown (canvas coords for windows,
    -- screen coords for the canvas offset).
    , startWinX : Int
    , startWinY : Int
    , startWinW : Int
    , startWinH : Int
    , startOffsetX : Int
    , startOffsetY : Int
    }


{-| Two-pointer canvas pinch zoom (D5): the two pointer ids and the
distance between them when the second finger landed.
-}
type alias PinchState =
    { pointerA : Int
    , pointerB : Int
    , startDist : Float
    }


{-| Touch long-press in flight (D5): the pointer that is held down and
where it started, so LongPressFired can validate (still down, not moved
past the slop) before opening the global menu.
-}
type alias LongPress =
    { pointerId : Int
    , x : Float
    , y : Float
    }


{-| Map a pointerdown target to the drag kind it arms (D5). Returns
Nothing for targets that cannot drag. Requires the ids that only the
DOM knows: sessionId/planId for bars and handles.
-}
toDragKind : P.TargetKind -> String -> String -> String -> Maybe DragKind
toDragKind target sessionId planId handle =
    case target of
        P.TCanvas ->
            Just Pan

        P.TSessionBar ->
            Just (WindowMove sessionId)

        P.TPlanBar ->
            Just (PlanMove planId)

        P.TSessionHandle ->
            Maybe.map (WindowResize sessionId) (handleFromString handle)

        P.TPlanHandle ->
            Maybe.map (PlanResize planId) (handleFromString handle)

        _ ->
            Nothing


handleFromString : String -> Maybe ResizeHandle
handleFromString s =
    case s of
        "nw" ->
            Just NW

        "n" ->
            Just N

        "ne" ->
            Just NE

        "w" ->
            Just W

        "e" ->
            Just E

        "sw" ->
            Just SW

        "s" ->
            Just S

        "se" ->
            Just SE

        _ ->
            Nothing


type ResizeHandle
    = N
    | S
    | W
    | E
    | NW
    | NE
    | SW
    | SE



-- EDITOR STATE (global presets)

-- Default (global) model list editor state. Edits a specific preset's
-- model.conf (the preset is chosen when opening from the preset manager)
-- and shows/selects its DEFAULT model (runtime.conf active_model).

type alias DefaultModelsEditor =
    { show : Bool
    , preset : String
    , state : Sel.State T.ModelInfo T.ModelDraft
    -- The preset's default model id (null when none matches runtime.conf).
    , activeModelId : Maybe Int
    -- Non-nil after a failed "set default model" action.
    , error : Maybe String
    }


emptyDefaultModelsEditor : DefaultModelsEditor
emptyDefaultModelsEditor =
    { show = False
    , preset = ""
    , state = Sel.empty
    , activeModelId = Nothing
    , error = Nothing
    }


type alias McpEditor =
    { show : Bool
    , preset : String
    , state : Sel.State T.McpInfo T.McpDraft
    }


emptyMcpEditor : McpEditor
emptyMcpEditor =
    { show = False
    , preset = ""
    , state = Sel.empty
    }


type alias SettingsEditor =
    { show : Bool
    , loading : Bool
    , syncing : Bool
    , toolConfirm : String
    , builtinTools : String
    , systemPrompt : String
    , reasoningLevel : Int
    , error : Maybe String
    , preset : String
    }


emptySettingsEditor : SettingsEditor
emptySettingsEditor =
    { show = False
    , loading = False
    , syncing = False
    , toolConfirm = ""
    , builtinTools = ""
    , systemPrompt = ""
    , reasoningLevel = 1
    , error = Nothing
    , preset = ""
    }


-- GLOBAL CONFIG OVERLAY

type alias GlobalConfig =
    { recursionLimit : Int
    }


emptyGlobalConfig : GlobalConfig
emptyGlobalConfig =
    { recursionLimit = 8
    }


type alias GlobalConfigEditor =
    { show : Bool
    , loading : Bool
    , syncing : Bool
    , input : String
    , error : Maybe String
    }


emptyGlobalConfigEditor : GlobalConfigEditor
emptyGlobalConfigEditor =
    { show = False
    , loading = False
    , syncing = False
    , input = ""
    , error = Nothing
    }


-- VOICE INPUT ASR CONFIG OVERLAY
--
-- ~/.alayaface/asr.conf: a LIST of ASR endpoint profiles; one is
-- active and used by asr_transcribe. Three wire protocols per profile:
--   "transcriptions"    — OpenAI-compatible /audio/transcriptions
--                         (multipart file upload); local and remote
--                         differ only by URL (default)
--   "chat_completions"  — OpenAI standard chat completions: JSON body
--                         with input_audio base64, api-key header
--   "step_audio"        — StepFun StepAudio realtime ASR: JSON with raw
--                         PCM audio, Accept: text/event-stream,
--                         Authorization: Bearer
-- The endpoint URL is the FULL address and is used verbatim.

type alias AsrProfile =
    { id : String
    , name : String
    , protocol : String
    , url : String
    , apiKey : String
    , model : String
    , language : String
    }


type alias AsrConfig =
    { active : String
    , profiles : List AsrProfile
    }


emptyAsrConfig : AsrConfig
emptyAsrConfig =
    { active = ""
    , profiles = []
    }


{-| Editor state: the overlay has two views — a profile LIST (the entry
point from the system menu) and the FORM (add/edit, the same page as
before). editingId = Nothing means a new profile.
-}
type alias AsrConfigEditor =
    { show : Bool
    , loading : Bool
    , syncing : Bool
    , inForm : Bool
    , editingId : Maybe String
    , confirmDelete : Maybe String
    , name : String
    , protocol : String
    , url : String
    , apiKey : String
    , model : String
    , language : String
    , error : Maybe String
    }


emptyAsrConfigEditor : AsrConfigEditor
emptyAsrConfigEditor =
    { show = False
    , loading = False
    , syncing = False
    , inForm = False
    , editingId = Nothing
    , confirmDelete = Nothing
    , name = ""
    , protocol = "transcriptions"
    , url = ""
    , apiKey = ""
    , model = "whisper-1"
    , language = "auto"
    , error = Nothing
    }


-- PRESETS

type alias PresetInfo =
    { name : String
    -- Built-in seed preset (Simple/Complex): referenced by the seeded
    -- plan contract, so it cannot be renamed (the backend rejects it and
    -- the manager hides the Rename button).
    , isSeed : Bool
    }


type alias PresetManager =
    { show : Bool
    , loading : Bool
    , busy : Bool
    , renaming : Maybe String
    , renameInput : String
    , editing : Maybe String
    , confirmDelete : Maybe String
    , error : Maybe String
    -- Drag-to-reorder: preset indices of the row being dragged
    -- (dragFrom) and the row currently under the pointer (dragOver).
    , dragFrom : Maybe Int
    , dragOver : Maybe Int
    }


emptyPresetManager : PresetManager
emptyPresetManager =
    { show = False
    , loading = False
    , busy = False
    , renaming = Nothing
    , renameInput = ""
    , editing = Nothing
    , confirmDelete = Nothing
    , error = Nothing
    , dragFrom = Nothing
    , dragOver = Nothing
    }


-- PLAN MODE

-- The currently opened plan (P2: list view; P3+: HTML/CSS DAG).
type alias PlanViewState =
    { plan : Maybe PT.Plan
    , path : Maybe String
    , errors : List String
    , saving : Bool
    }


emptyPlanView : PlanViewState
emptyPlanView =
    { plan = Nothing
    , path = Nothing
    , errors = []
    , saving = False
    }


{-| A plan opened in its own draggable window (like a session window).
One window per plan file; the window owns its run state so multiple
plans can run independently. `infoOpen` (P37): the floating info window
— all plan text (goal / task prompts / run log / saved path) is hidden
by default and shown there; `selectedNode` selects its Node tab.
-}
type alias PlanWindow =
    { view : PlanViewState
    , run : Maybe PT.RunState
    , runPath : Maybe String
    , runLog : List String
    , selectedNode : Maybe String
    , resumePath : Maybe String
    , infoOpen : Bool
    }


emptyPlanWindow : PlanWindow
emptyPlanWindow =
    { view = emptyPlanView
    , run = Nothing
    , runPath = Nothing
    , runLog = []
    , selectedNode = Nothing
    , resumePath = Nothing
    , infoOpen = False
    }


{-| A pending fs_read_file_text request initiated from Plan Mode:
which window it belongs to and what to do with the content.
  - isResume=False → the read is a plan file (open/import)
  - isResume=True  → the read is a run-state file; continueRun=True
    means also relaunch scheduling (user clicked Load run), while
    continueRun=False is a silent best-effort restore (auto-load the
    saved bindings when a plan window opens).
-}
type alias PlanReadTarget =
    { reqId : String
    , planId : String
    , path : String
    , isResume : Bool
    , continueRun : Bool
    }


{-| A queued session-creation request. Runner creates are tagged with
their (planId, nodeId); user-initiated creates ("normal" / "plan") go
through the SAME serialized queue so a user click can never be misbound
to a runner node (and vice versa).
-}
type CreateTask
    = RunnerCreate String String
    | UserCreate String
