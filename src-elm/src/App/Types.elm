module App.Types exposing
    ( Flags
    , Model
    , Msg(..)
    , WindowPos
    , DragInfo
    , ResizeHandle(..)
    , ResizeInfo
    , DefaultModelsEditor
    , emptyDefaultModelsEditor
    , McpEditor
    , emptyMcpEditor
    , SettingsEditor
    , emptySettingsEditor
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
import Session.Selector as Sel
import Session.Types as T
import App.NodeConnection as NC


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
    , dragInfo : Maybe DragInfo
    , resizeInfo : Maybe ResizeInfo
    , showGlobalMenu : Bool
    , defaultModelsEditor : DefaultModelsEditor
    , mcpEditor : McpEditor
    , settingsEditor : SettingsEditor
    , presets : List PresetInfo
    , activePreset : String
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
    -- Two-level dir scan: planMetaDirQueue holds the remaining
    -- sessions/<uuid>/plans dirs to list; planMetaDirListing is the dir
    -- whose listing the next FsListDirResult belongs to (Nothing + empty
    -- queue while loading = waiting for the sessions/ listing).
    , planMetaDirQueue : List String
    , planMetaDirListing : Maybe String
    -- The meta.json path currently being read (head of the rebuild
    -- chain); planMetaReadQueue holds the remaining paths.
    , planMetaReading : Maybe String
    , planMetaReadQueue : List String
    -- Last known run status per plan (survives the auto-close of a
    -- Completed plan window — the status bar needs it). Updated on every
    -- runStepIn; not persisted (rebuilt when the window reopens).
    , planRunStatuses : Dict String PT.RunStatus
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
    , planReadTarget : Maybe PlanReadTarget
    , planNodeSessions : Dict String String
    -- Plan window owning the in-flight resume (for error surfacing).
    , planResumeOwner : Maybe String
    -- Original (on-disk dir) session id of an in-flight plan-node resume.
    -- The resumed session gets a FRESH id from resume_session; the node
    -- stays bound to the original id (the dir name) so it can always be
    -- resumed again.
    , planResumeFrom : Maybe String
    -- Live (fresh) session id → original dir id, for every resume done in
    -- this app run. Lets a node click find the live resumed session and
    -- lets CloseSession attribute the window back to its plan node.
    , planResumedFrom : Dict String String
    -- Active node↔session connection: when the user focuses a session
    -- that belongs to a plan node, the node's plan window is raised to
    -- the second layer and a bezier curve connects the two windows
    -- (drawn by bridge.js; Elm only tracks which pair is connected).
    , nodeConnection : Maybe NC.NodeConnection
    -- Active plan window ↔ owning session connection: when the plan
    -- window is active, a curve connects it to the (live) session that
    -- auto-created it (meta.json origin). Drawn by bridge.js.
    , planConnection : Maybe NC.PlanConnection
    , homeDir : String
    }


-- MSG

type Msg
    = -- Session lifecycle
      CreateSession
    | SessionCreated String
    | SessionCreateError String
    | CloseSession String
      -- Transport events
    | DeltaEvent E.Value
    | FrameEvent E.Value
    | StatusEvent E.Value
      -- User actions
    | SendPrompt
    | CancelTask
    | SetModel Int
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
    | FsListDirResult (List E.Value)
    | FsHomeDirResult String
    | FsReadFileResult String
    | FsResolvePathResult E.Value
    | FsWriteResult E.Value
    | FsReadResult E.Value
      -- Session manager
    | OpenSessionManager
    | CloseSessionManager
    | SessionDirsResult (List E.Value)
    | SessionActionResult E.Value
    | ResumeSession String
    | DeleteSession String
      -- Window
    | WindowMaximized Bool
    | GotContainerSize (Result Dom.Error Dom.Element)
    | RequerySize
      -- Model Selector
    | OpenModelSelector
    | CloseModelSelector
    | SetModelSelectorInput String
    | ModelSelectorSelectItem Int
    | ModelSelectorConfirmItem
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
    | DefaultModelsConfirmItem
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
      -- MCP server editor (targets a specific preset)
    | EditPresetMcp String
    | CloseMcpEditor
    | SetMcpInput String
    | McpSelectItem Int
    | McpConfirmItem
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
    | SettingsSave
    | SettingsListResult E.Value
    | SettingsSyncResult E.Value
      -- Presets
    | OpenPresetManager
    | ClosePresetManager
    | PresetCopy String
    | PresetSetActive String
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
      -- Help Window
    | OpenHelpWindow
    | CloseHelpWindow
    | SetHelpFilter String
    | HelpSelectItem Int
    | HelpCmdMsg String
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
    | PlanSetConcurrency String
    | PlanSetExportPath String
    | PlanExport
      -- Plan runner
    | PlanRunStart
    | PlanRunStartAt Int
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
      -- Window dragging
    | WindowDragStart String Float Float
    | WindowDragMove Float Float
    | WindowDragEnd
    | PlanWindowDragStart String Float Float
      -- Window resizing
    | ResizeStart String ResizeHandle Float Float
    | PlanResizeStart String ResizeHandle Float Float
      -- Instant activation on mousedown
    | ActivateSession String
      -- Context menu
    | ShowCtxMenu Int Int String String
    | HideCtxMenu
    | ForkFromCtx
      -- Message collapse/expand
    | ToggleMsgCollapse String String
      -- Global menu
    | ToggleGlobalMenu
    | CloseGlobalMenu
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


type alias DragInfo =
    { sessionId : String
    , startMouseX : Float
    , startMouseY : Float
    , startWinX : Int
    , startWinY : Int
    }


type ResizeHandle
    = N
    | S
    | W
    | E
    | NW
    | NE
    | SW
    | SE


type alias ResizeInfo =
    { sessionId : String
    , handle : ResizeHandle
    , startMouseX : Float
    , startMouseY : Float
    , startWinX : Int
    , startWinY : Int
    , startWinW : Int
    , startWinH : Int
    }


-- EDITOR STATE (global presets)

-- Default (global) model list editor state. Edits a specific preset's
-- model.conf (the preset is chosen when opening from the preset manager).

type alias DefaultModelsEditor =
    { show : Bool
    , preset : String
    , state : Sel.State T.ModelInfo T.ModelDraft
    }


emptyDefaultModelsEditor : DefaultModelsEditor
emptyDefaultModelsEditor =
    { show = False
    , preset = ""
    , state = Sel.empty
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
    , error = Nothing
    , preset = ""
    }


-- PRESETS

type alias PresetInfo =
    { name : String
    , isActive : Bool
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
    }


-- PLAN MODE

-- The currently opened plan (P2: list view; P3+: SVG/HTML DAG).
type alias PlanViewState =
    { plan : Maybe PT.Plan
    , path : Maybe String
    , errors : List String
    , saving : Bool
    , exportPath : String
    -- Concurrency override from the plan header (empty = use the plan's
    -- own concurrency). Applied when a run starts.
    , concurrencyInput : String
    }


emptyPlanView : PlanViewState
emptyPlanView =
    { plan = Nothing
    , path = Nothing
    , errors = []
    , saving = False
    , exportPath = ""
    , concurrencyInput = ""
    }


{-| A plan opened in its own draggable window (like a session window).
One window per plan file; the window owns its run state so multiple
plans can run independently.
-}
type alias PlanWindow =
    { view : PlanViewState
    , run : Maybe PT.RunState
    , runPath : Maybe String
    , runLog : List String
    , selectedNode : Maybe String
    , resumePath : Maybe String
    }


emptyPlanWindow : PlanWindow
emptyPlanWindow =
    { view = emptyPlanView
    , run = Nothing
    , runPath = Nothing
    , runLog = []
    , selectedNode = Nothing
    , resumePath = Nothing
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
    { planId : String
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
