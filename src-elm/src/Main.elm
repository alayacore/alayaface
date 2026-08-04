module Main exposing (main)

import Browser
import Browser.Dom as Dom
import Browser.Events as Evts
import Task
import Process
import Dict exposing (Dict)
import Set exposing (Set)
import Html exposing (Html, Attribute)
import Html.Attributes as Attr
import Html.Events as Ev
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Time
import Session.Types as T
import Session.Protocol as P
import Session.Handlers as H
import Session.Selector as Sel exposing (Page(..))
import Overlay.ConfirmTool
import Overlay.Settings
import Overlay.PresetManager
import Overlay.McpInit
import Overlay.FilePicker
import Overlay.Selector
import Overlay.ModelEditor
import Overlay.McpEditor
import Overlay.HelpWindow exposing (HelpItem, filterHelpItems, view)
import Markdown
import Ports
import Fuzzy


-- TYPE ALIASES

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
    , error : Maybe String
    , preset : String
    }


emptySettingsEditor : SettingsEditor
emptySettingsEditor =
    { show = False
    , loading = False
    , syncing = False
    , toolConfirm = ""
    , error = Nothing
    , preset = ""
    }


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


-- Constants

defaultWinW : Int
defaultWinW = 560

defaultWinH : Int
defaultWinH = 640

minWinW : Int
minWinW = 300

minWinH : Int
minWinH = 200


-- Shared Markdown render config

markdownOptions : Markdown.Options
markdownOptions =
    { githubFlavored = Just { tables = True, breaks = True }
    , defaultHighlighting = Nothing
    , sanitize = False
    , smartypants = False
    }


-- MAIN

main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }


type alias Flags =
    ()


-- MODEL

type alias Model =
    { sessions : Dict String T.SessionState
    , activeId : Maybe String
    , initializing : Bool
    , initError : Maybe String
    , showSessionManager : Bool
    , sessionDirs : List E.Value
    , isMaximized : Bool
    , atBottom : Bool
    , prevMsgCount : Int
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
    }


init : Flags -> ( Model, Cmd Msg )
init _ =
    ( { sessions = Dict.empty
      , activeId = Nothing
      , initializing = True
      , initError = Nothing
      , showSessionManager = False
      , sessionDirs = []
      , isMaximized = False
      , atBottom = True
      , prevMsgCount = 0
      , sessionOrder = []
      , pendingSwitchOnCreate = False
      , inputRows = 1
      , cursorMsgId = Nothing
      , pendingEvents = Dict.empty
      , sessionNums = Dict.empty
      , nextSessionNum = 1
      , windowPositions = Dict.empty
      , nextZIndex = 1
      , dragInfo = Nothing
      , resizeInfo = Nothing
      , showGlobalMenu = False
      , defaultModelsEditor = emptyDefaultModelsEditor
      , mcpEditor = emptyMcpEditor
      , settingsEditor = emptySettingsEditor
      , presets = []
      , activePreset = ""
      , presetManager = emptyPresetManager
      , ctxVisible = False
      , ctxX = 0
      , ctxY = 0
      , ctxHistoryId = ""
      , ctxSessionId = ""
      , appWidth = 1400
      , appHeight = 900
      }
    , Cmd.batch
        [ Ports.createSession { toolConfirm = Nothing }
        , Ports.listPresets {}
        , Task.attempt GotContainerSize (Dom.getElement "main-content")
        ]
    )


-- Helpers

updateSession : Model -> String -> (T.SessionState -> T.SessionState) -> Model
updateSession model sid fn =
    case Dict.get sid model.sessions of
        Just s ->
            { model | sessions = Dict.insert sid (fn s) model.sessions }

        Nothing ->
            model


updateActiveSession : Model -> (T.SessionState -> T.SessionState) -> Model
updateActiveSession model fn =
    case model.activeId of
        Just sid ->
            updateSession model sid fn

        Nothing ->
            model


focusInput : Model -> Cmd Msg
focusInput model =
    case model.activeId of
        Just sid ->
            Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ sid))
        Nothing ->
            Cmd.none


getActiveSession : Model -> Maybe T.SessionState
getActiveSession model =
    case model.activeId of
        Just sid ->
            Dict.get sid model.sessions

        Nothing ->
            Nothing


-- Buffer an inbound event for a session that has not been registered
-- yet (e.g. transport events racing session creation). The buffered
-- events are flushed when the session appears (see SessionCreated).
bufferPendingEvent : Model -> String -> E.Value -> ( Model, Cmd Msg )
bufferPendingEvent model sessionId raw =
    let
        existing =
            Dict.get sessionId model.pendingEvents |> Maybe.withDefault []
    in
    ( { model | pendingEvents = Dict.insert sessionId (existing ++ [ raw ]) model.pendingEvents }
    , Cmd.none
    )



-- MSG

type Msg
    = -- Session lifecycle
      CreateSession
    | SessionCreated String
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
    | McpAuthConfirm String
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
    | FocusElement String
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
      -- Session manager
    | OpenSessionManager
    | CloseSessionManager
    | SessionDirsResult (List E.Value)
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
    | FillMcpAuthUrl String
      -- Session wrapper
    | ForSession String Msg
      -- Window dragging
    | WindowDragStart String Float Float
    | WindowDragMove Float Float
    | WindowDragEnd
      -- Window resizing
    | ResizeStart String ResizeHandle Float Float
      -- Instant activation on mousedown
    | ActivateSession String
      -- Context menu
    | ShowCtxMenu Int Int String String
    | HideCtxMenu
    | ForkFromCtx
      -- Global menu
    | ToggleGlobalMenu
    | CloseGlobalMenu
      -- Internal
    | NoOp
    | KeyDown String Bool Bool Bool
    | ScrollPosition Float Float Float


-- UPDATE

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Session Lifecycle
        CreateSession ->
            ( { model | pendingSwitchOnCreate = True, showGlobalMenu = False }
            , Ports.createSession { toolConfirm = Nothing }
            )

        SessionCreated id ->
            let
                newSession =
                    T.emptySession id

                newSessions =
                    Dict.insert id newSession model.sessions

                -- Replay any buffered events that arrived before this session was registered
                buffered =
                    Dict.get id model.pendingEvents |> Maybe.withDefault []

                sessionsAfterBuffer =
                    List.foldl applyPendingEvent newSessions buffered

                -- Only auto-switch on initial creation (activeId was Nothing)
                -- If user is already viewing a session, don't steal focus
                newActiveId =
                    if model.pendingSwitchOnCreate || model.activeId == Nothing then
                        Just id
                    else
                        model.activeId

                cmds =
                    if model.pendingSwitchOnCreate || model.activeId == Nothing then
                        Cmd.batch [ Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ id)), Ports.scrollToBottom { sessionId = id } ]
                    else
                        Cmd.none
            in
            ( { model
                | sessions = sessionsAfterBuffer
                , activeId = newActiveId
                , initializing = False
                , atBottom = True
                , sessionOrder = model.sessionOrder ++ [ id ]
                , sessionNums = Dict.insert id model.nextSessionNum model.sessionNums
                , nextSessionNum = model.nextSessionNum + 1
                , windowPositions =
                    if Dict.member id model.windowPositions then
                        model.windowPositions
                    else
                        let
                            -- Cascade: each new window offsets from previous
                            -- Use nextSessionNum (monotonically increasing) to avoid
                            -- overlapping with existing windows after session closures
                            n =
                                model.nextSessionNum

                            baseX =
                                60 + remainderBy 6 n * 50

                            baseY =
                                60 + remainderBy 4 n * 40
                        in
                        Dict.insert id
                            { x = baseX
                            , y = baseY
                            , z = model.nextZIndex
                            , w = defaultWinW
                            , h = defaultWinH
                            }
                            model.windowPositions
                , nextZIndex = model.nextZIndex + 1
                , pendingSwitchOnCreate = False
                , pendingEvents = Dict.remove id model.pendingEvents
              }
            , cmds
            )

        CloseSession id ->
            ( { model
                | sessions = Dict.remove id model.sessions
                , sessionOrder = List.filter (\k -> k /= id) model.sessionOrder
                , sessionNums = Dict.remove id model.sessionNums
                , windowPositions = Dict.remove id model.windowPositions
                , activeId =
                    if model.activeId == Just id then
                        List.head (List.reverse (List.filter (\k -> k /= id) model.sessionOrder))
                    else
                        model.activeId
              }
            , Ports.closeSession { sessionId = id }
            )

        -- Transport Events
        DeltaEvent raw ->
            case D.decodeValue P.deltaEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                newSession =
                                    H.handleDeltaEvent session ev

                                cmds =
                                    if model.atBottom then
                                        Cmd.batch
                                            [ Ports.scrollToBottom { sessionId = ev.sessionId }
                                            , if model.activeId == Just ev.sessionId then
                                                Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ ev.sessionId))
                                              else
                                                Cmd.none
                                            ]
                                    else
                                        Cmd.none
                            in
                            ( { model
                                | sessions = Dict.insert ev.sessionId newSession model.sessions
                                , prevMsgCount = List.length newSession.messages
                              }
                            , cmds
                            )

                        Nothing ->
                            bufferPendingEvent model ev.sessionId raw

                Err _ ->
                    ( model, Cmd.none )

        FrameEvent raw ->
            case D.decodeValue P.frameEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                newSession =
                                    H.handleFrameEvent session ev

                                msgCountChanged =
                                    List.length newSession.messages /= model.prevMsgCount

                                mcpJustCompleted =
                                    session.mcpStatus /= Nothing && newSession.mcpStatus == Nothing

                                cmds =
                                    Cmd.batch
                                        (List.filterMap identity
                                            [ if msgCountChanged && model.atBottom then
                                                Just (Ports.scrollToBottom { sessionId = ev.sessionId })

                                              else
                                                Nothing
                                            , if (msgCountChanged && model.atBottom || mcpJustCompleted) && model.activeId == Just ev.sessionId then
                                                Just (Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ ev.sessionId)))

                                              else
                                                Nothing
                                            ]
                                        )

                                updatedModel =
                                    { model
                                        | sessions = Dict.insert ev.sessionId newSession model.sessions
                                        , prevMsgCount = List.length newSession.messages
                                    }
                            in
                            -- model_sync completes asynchronously via CO:
                            -- success closes the overlay, failure keeps it open
                            case decodeSyncOutcome raw of
                                Just ( isError, message ) ->
                                    if newSession.modelSelector.page == ModelSelSyncing then
                                        update (ForSession ev.sessionId (ModelSelectorSyncResult isError message)) updatedModel

                                    else
                                        ( updatedModel, cmds )

                                Nothing ->
                                    ( updatedModel, cmds )

                        Nothing ->
                            bufferPendingEvent model ev.sessionId raw

                Err _ ->
                    ( model, Cmd.none )

        StatusEvent raw ->
            case D.decodeValue P.statusEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            let
                                updated =
                                    { session
                                        | connected = ev.connected
                                        , statusMsg = ev.message
                                    }
                            in
                            if not ev.connected && session.modelSelector.page == ModelSelSyncing then
                                -- A disconnect means the model_sync CO will
                                -- never arrive — fail the sync instead of
                                -- leaving the overlay stuck.
                                ( { model
                                    | sessions = Dict.insert ev.sessionId
                                        { updated
                                            | modelSelector = Sel.syncFailed "Session disconnected during sync" updated.modelSelector
                                        }
                                        model.sessions
                                  }
                                , Cmd.none
                                )

                            else
                                ( { model
                                    | sessions = Dict.insert ev.sessionId updated model.sessions
                                  }
                                , Cmd.none
                                )

                        Nothing ->
                            bufferPendingEvent model ev.sessionId raw

                Err _ ->
                    ( model, Cmd.none )

        -- User Actions
        SendPrompt ->
            case getActiveSession model of
                Just s ->
                    let
                        text =
                            String.trim s.input

                        mediaItems =
                            List.map
                                (\m ->
                                    E.object
                                        [ ( "media_type", E.string (T.mediaTypeToString m.mediaType) )
                                        , ( "uri", E.string m.uri )
                                        ]
                                )
                                s.staged
                    in
                    if text == "" && List.isEmpty s.staged then
                        ( model, Cmd.none )

                    else
                        ( { model
                            | inputRows = 1
                            , sessions = Dict.insert s.id
                                { s
                                    | input = ""
                                    , staged = []
                                    , statusMsg = "Sending…"
                                    , sendPending = True
                                }
                                model.sessions
                          }
                        , Ports.sendPrompt
                            { sessionId = s.id
                            , text = text
                            , media = mediaItems
                            }
                        )

                Nothing ->
                    ( model, Cmd.none )

        CancelTask ->
            case model.activeId of
                Just id ->
                    ( model
                    , Ports.cancelTask { sessionId = id }
                    )

                Nothing ->
                    ( model, Cmd.none )

        SetModel modelId ->
            case model.activeId of
                Just id ->
                    ( model, Ports.setModel { sessionId = id, modelId = modelId } )

                Nothing ->
                    ( model, Cmd.none )

        ConfirmTool sid id allowed ->
            case Dict.get sid model.sessions of
                Just _ ->
                    ( updateAfterConfirm model sid
                    , Ports.confirmTool { sessionId = sid, id = id, allowed = allowed }
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthConfirm sid ->
            case Dict.get sid model.sessions of
                Just s ->
                    case s.pendingMcpAuth of
                        Just auth ->
                            let
                                newSessions =
                                    Dict.insert sid { s | pendingMcpAuth = Nothing } model.sessions

                                authUrl =
                                    Maybe.withDefault "" auth.toolInput

                                serverName =
                                    Maybe.withDefault "" auth.toolName
                            in
                            ( { model | sessions = newSessions }
                            , Ports.startMcpAuthFlow
                                { sessionId = sid
                                , serverName = serverName
                                , authUrl = authUrl
                                }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthDeny sid server ->
            case Dict.get sid model.sessions of
                Just sess ->
                    ( { model | sessions = Dict.insert sid { sess | pendingMcpAuth = Nothing } model.sessions }
                    , Cmd.batch
                        [ Ports.sendMcpDecline { sessionId = sid, server = server }
                        , focusInput model
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseMcpAuthOverlay sid ->
            case Dict.get sid model.sessions of
                Just _ ->
                    ( { model | sessions = Dict.update sid
                        (Maybe.map (\sess ->
                            { sess
                                | mcpStatus = Nothing
                                , pendingMcpAuth = Nothing
                                , pendingMcpAuths = []
                            }
                        ))
                        model.sessions
                      }
                    , Cmd.batch
                        [ Ports.sendMcpCancel { sessionId = sid }
                        , focusInput model
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpCancelAll sid ->
            case Dict.get sid model.sessions of
                Just sess ->
                    ( { model
                        | sessions = Dict.insert sid
                            { sess | pendingMcpAuth = Nothing, mcpStatus = Nothing }
                            model.sessions
                      }
                    , Cmd.batch
                        [ Ports.sendMcpCancel { sessionId = sid }
                        , focusInput model
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseConfirm sid ->
            case Dict.get sid model.sessions of
                Just sess ->
                    -- Pop next pending MCP auth from queue if any
                    let
                        nextAuth =
                            case sess.pendingMcpAuths of
                                next :: rest ->
                                    Just next

                                [] ->
                                    Nothing

                        newQueue =
                            case sess.pendingMcpAuths of
                                _ :: rest -> rest
                                [] -> []
                    in
                    ( { model
                        | sessions = Dict.insert sid
                            { sess
                                | pendingConfirm = []
                                , pendingMcpAuth = nextAuth
                                , pendingMcpAuths = newQueue
                            }
                            model.sessions
                      }
                    , focusInput model
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseMcpInit sid ->
            update (McpCancelAll sid) model

        ForkMessage historyId ->
            case model.activeId of
                Just sid ->
                    ( model
                    , Ports.forkSession { sourceSessionId = sid, historyId = historyId }
                    )

                Nothing ->
                    ( model, Cmd.none )

        ShowCtxMenu x y historyId sessionId ->
            ( { model
                | ctxVisible = True
                , ctxX = x
                , ctxY = y
                , ctxHistoryId = historyId
                , ctxSessionId = sessionId
              }
            , Cmd.none
            )

        HideCtxMenu ->
            ( { model | ctxVisible = False }, Cmd.none )

        ForkFromCtx ->
            if model.ctxHistoryId /= "" && model.ctxSessionId /= "" then
                ( { model | ctxVisible = False, pendingSwitchOnCreate = True }
                , Ports.forkSession { sourceSessionId = model.ctxSessionId, historyId = model.ctxHistoryId }
                )

            else
                ( { model | ctxVisible = False }, Cmd.none )

        RemoveStaged stagedId ->
            case model.activeId of
                Just sid ->
                    case Dict.get sid model.sessions of
                        Just s ->
                            let
                                newStaged =
                                    List.filter (\m -> m.id /= stagedId) s.staged
                            in
                            ( { model | sessions = Dict.insert sid { s | staged = newStaged } model.sessions }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ConfirmFilePickerUrl ->
            case getActiveSession model of
                Just s ->
                    let
                        url =
                            String.trim s.filePickerInput
                    in
                    if url == "" then
                        ( model, Cmd.none )

                    else
                        let
                            detectedType =
                                detectMediaType url

                            newItem =
                                { id = "url-" ++ String.fromInt (List.length s.staged)
                                , mediaType = detectedType
                                , uri = url
                                , name = Just (String.left 60 url)
                                }
                        in
                        ( updateActiveSession model (\sess ->
                            { sess
                                | staged = sess.staged ++ [ newItem ]
                                , showFilePicker = False
                                , filePickerInput = ""
                            }
                          )
                        , focusInput model
                        )

                Nothing ->
                    ( model, Cmd.none )

        SetInput val ->
            case model.activeId of
                Just sid ->
                    let
                        s =
                            Dict.get sid model.sessions
                    in
                    case s of
                        Just sess ->
                            ( { model
                                | sessions = Dict.insert sid { sess | input = val } model.sessions
                                , inputRows = clamp 1 3 (List.length (String.lines val))
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )
        SwitchSession id ->
            if model.activeId == Just id then
                -- Already active: just focus the input, no z-index bump
                ( model
                , Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ id))
                )
            else
                let
                    newPositions =
                        Dict.update id
                            (Maybe.map (\pos -> { pos | z = model.nextZIndex }))
                            model.windowPositions
                in
                ( { model
                    | activeId = Just id
                    , windowPositions = newPositions
                    , nextZIndex = model.nextZIndex + 1
                  }
                , Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ id))
                )

        -- File Picker
        OpenFilePicker ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        { sess
                            | showFilePicker = True
                            , filePickerMode = T.Local
                            , filePickerInput = ""
                            , filePickerFilter = ""
                            , filePickerSelected = 0
                            , filePickerLoading = True
                        }
                      )
                    , Cmd.batch
                        [ Ports.fsHomeDir {}
                        , focusAfterDelay ("fp-page-input-" ++ s.id)
                        , Ports.setCursorPos ("fp-page-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseFilePicker ->
            ( updateActiveSession model (\s -> { s | showFilePicker = False, filePickerSavedLocalPath = "", filePickerSavedUrlPath = "" })
            , focusInput model
            )

        FocusElement id ->
            ( model, Task.attempt (\_ -> NoOp) (Dom.focus id) )

        SetFilePickerInput val ->
            case getActiveSession model of
                Just s ->
                    if s.filePickerMode == T.Url then
                        -- URL mode: just update input, no path parsing
                        ( updateActiveSession model (\sess ->
                            { sess | filePickerInput = val }
                          )
                        , Cmd.none
                        )

                    else
                        -- If input was cleared (select-all + delete, etc.),
                        -- restore to current directory path
                        let
                            safeVal =
                                if val == "" then
                                    "/"
                                else
                                    val
                        in
                        -- Local mode: parse input as path, extract filter text,
                        -- navigate directory if needed
                        let
                            ( needsResolve, resolvePath, filterText ) =
                                parsePathInput safeVal s.filePickerDir s.filePickerBaseDir

                            cmd =
                                if needsResolve then
                                    Ports.fsResolvePath { path = resolvePath }
                                else
                                    Cmd.none

                            -- Clamp selection to filtered list length
                            previewSession =
                                { s | filePickerInput = safeVal, filePickerFilter = filterText }

                            filteredLen =
                                List.length (filterEntries previewSession)

                            clampedIdx =
                                if s.filePickerSelected >= filteredLen then
                                    max 0 (filteredLen - 1)
                                else
                                    s.filePickerSelected
                        in
                        ( updateActiveSession model (\sess ->
                            { sess
                                | filePickerInput = safeVal
                                , filePickerFilter = filterText
                                , filePickerSelected = clampedIdx
                            }
                          )
                        , cmd
                        )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerNavigateDir name ->
            -- User clicked a directory in the file list.
            -- Append the directory name + "/" to the current input path.
            case getActiveSession model of
                Just s ->
                    let
                        inputVal =
                            s.filePickerInput

                        -- Find the prefix up to (and including) the last "/" in input
                        newInput =
                            if String.endsWith "/" inputVal then
                                -- Input already ends with "/", just append dir name
                                inputVal ++ name ++ "/"
                            else
                                -- Input has filter text after last "/",
                                -- replace filter with dir name + "/"
                                case lastIndexOf '/' inputVal of
                                    Just idx ->
                                        String.left (idx + 1) inputVal ++ name ++ "/"

                                    Nothing ->
                                        -- No "/" in input, just use dir name + "/"
                                        name ++ "/"

                        newDir =
                            if s.filePickerDir == "" then
                                name
                            else
                                s.filePickerDir ++ "/" ++ name
                    in
                    ( updateActiveSession model (\sess ->
                        { sess
                            | filePickerInput = newInput
                            , filePickerFilter = ""
                            , filePickerLoading = True
                        }
                      )
                    , Ports.fsResolvePath { path = newDir }
                    )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerSelectItem idx ->
            let
                scrollCmd =
                    case getActiveSession model of
                        Just s ->
                            let
                                entries =
                                    filterEntries s
                            in
                            case List.head (List.drop idx entries) of
                                Just e ->
                                    Ports.scrollIntoView ("fp-item-" ++ s.id ++ "-" ++ e.name)

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none
            in
            ( updateActiveSession model (\s -> { s | filePickerSelected = idx })
            , scrollCmd
            )

        FilePickerConfirmItem ->
            case getActiveSession model of
                Just s ->
                    let
                        entries =
                            filterEntries s
                    in
                    case List.head (List.drop s.filePickerSelected entries) of
                        Just entry ->
                            if entry.isDir then
                                -- Directory: autocomplete its name into the input path
                                let
                                    inputVal =
                                        s.filePickerInput

                                    -- Append dir name + "/" to the input
                                    newInput =
                                        if String.endsWith "/" inputVal then
                                            inputVal ++ entry.name ++ "/"
                                        else
                                            case lastIndexOf '/' inputVal of
                                                Just idx ->
                                                    String.left (idx + 1) inputVal ++ entry.name ++ "/"

                                                Nothing ->
                                                    entry.name ++ "/"

                                    newDir =
                                        if s.filePickerDir == "" then
                                            entry.name
                                        else
                                            s.filePickerDir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePickerLoading = True
                                        , filePickerInput = newInput
                                        , filePickerFilter = ""
                                    }
                                  )
                                , Ports.fsResolvePath { path = newDir }
                                )

                            else
                                -- File: select it
                                let
                                    fullPath =
                                        if s.filePickerDir == "" then
                                            entry.name
                                        else
                                            s.filePickerDir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePickerLoading = True
                                        , pendingFileName = entry.name
                                    }
                                  )
                                , Ports.fsReadFileDataUri { path = fullPath }
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerPickItem idx ->
            -- Pick an item by index (from click). Same logic as ConfirmItem but uses
            -- the explicit clicked index instead of keyboard-selected index.
            case getActiveSession model of
                Just s ->
                    let
                        entries =
                            filterEntries s
                    in
                    case List.head (List.drop idx entries) of
                        Just entry ->
                            if entry.isDir then
                                let
                                    inputVal =
                                        s.filePickerInput

                                    newInput =
                                        if String.endsWith "/" inputVal then
                                            inputVal ++ entry.name ++ "/"
                                        else
                                            case lastIndexOf '/' inputVal of
                                                Just sl ->
                                                    String.left (sl + 1) inputVal ++ entry.name ++ "/"

                                                Nothing ->
                                                    entry.name ++ "/"

                                    newDir =
                                        if s.filePickerDir == "" then
                                            entry.name
                                        else
                                            s.filePickerDir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePickerLoading = True
                                        , filePickerInput = newInput
                                        , filePickerFilter = ""
                                        , filePickerSelected = idx
                                    }
                                  )
                                , Ports.fsResolvePath { path = newDir }
                                )

                            else
                                let
                                    fullPath =
                                        if s.filePickerDir == "" then
                                            entry.name
                                        else
                                            s.filePickerDir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePickerLoading = True
                                        , pendingFileName = entry.name
                                        , filePickerSelected = idx
                                    }
                                  )
                                , Ports.fsReadFileDataUri { path = fullPath }
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerToggleMode ->
            case getActiveSession model of
                Just s ->
                    let
                        ( newMode, newInput ) =
                            case s.filePickerMode of
                                T.Local ->
                                    -- Switching FROM local TO URL: save local path, restore saved URL
                                    ( T.Url
                                    , s.filePickerSavedUrlPath
                                    )

                                T.Url ->
                                    -- Switching FROM URL TO local: save URL, restore saved local path
                                    let
                                        restoredLocal =
                                            if s.filePickerSavedLocalPath /= "" then
                                                s.filePickerSavedLocalPath
                                            else if s.filePickerDir /= "" then
                                                s.filePickerDir ++ "/"
                                            else
                                                ""
                                    in
                                    ( T.Local
                                    , restoredLocal
                                    )

                        ( savedLocal, savedUrl ) =
                            case s.filePickerMode of
                                T.Local ->
                                    ( s.filePickerInput
                                    , ""
                                    )

                                T.Url ->
                                    ( ""
                                    , s.filePickerInput
                                    )
                    in
                    ( updateActiveSession model (\oldS ->
                        { oldS
                            | filePickerMode = newMode
                            , filePickerInput = newInput
                            , filePickerFilter = ""
                            , filePickerSavedLocalPath = savedLocal
                            , filePickerSavedUrlPath = savedUrl
                        }
                      )
                    , Cmd.batch
                        [ focusAfterDelay ("fp-page-input-" ++ s.id)
                        , Ports.setCursorPos ("fp-page-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerNavigateUp ->
            case getActiveSession model of
                Just s ->
                    if s.filePickerDir /= "" && s.filePickerBaseDir /= "" then
                        let
                            cleanPath =
                                if String.endsWith "/" s.filePickerDir then
                                    String.dropRight 1 s.filePickerDir
                                else
                                    s.filePickerDir

                            parts =
                                String.split "/" cleanPath

                            parentDir =
                                case List.reverse parts of
                                    _ :: rest ->
                                        String.join "/" (List.reverse rest)

                                    [] ->
                                        "/"
                        in
                        ( updateActiveSession model (\sess ->
                            { sess
                                | filePickerLoading = True
                                , filePickerInput = parentDir ++ "/"
                                , filePickerFilter = ""
                            }
                          )
                        , Ports.fsResolvePath { path = parentDir }
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FsListDirResult entries ->
            let
                parsed =
                    List.filterMap decodeDirEntry entries

                -- Filter out ".." (parent directory entry) — not useful in UI
                noDotDot =
                    List.filter (\e -> e.name /= "..") parsed
            in
            ( updateActiveSession model (\s ->
                { s
                    | filePickerEntries = noDotDot
                    , filePickerLoading = False
                    , filePickerError = Nothing
                }
              )
            , Cmd.none
            )

        FsHomeDirResult home ->
            ( updateActiveSession model (\s ->
                { s
                    | filePickerBaseDir = home
                    , filePickerDir = home
                    , filePickerInput = home ++ "/"
                    , filePickerFilter = ""
                    , filePickerLoading = True
                }
              )
            , case model.activeId of
                Just sid ->
                    Cmd.batch
                        [ Ports.fsListDir { path = home }
                        , focusAfterDelay ("fp-page-input-" ++ sid)
                        , Ports.setCursorPos ("fp-page-input-" ++ sid)
                        ]
                Nothing ->
                    Ports.fsListDir { path = home }
            )

        FsReadFileResult uri ->
            case getActiveSession model of
                Just s ->
                    let
                        name =
                            if s.pendingFileName /= "" then
                                Just s.pendingFileName
                            else
                                Nothing

                        detectedType =
                            case name of
                                Just n -> detectMediaType n
                                Nothing -> T.Document

                        newItem =
                            { id = "file-" ++ String.fromInt (List.length s.staged)
                            , mediaType = detectedType
                            , uri = uri
                            , name = name
                            }
                    in
                    ( updateActiveSession model (\sess ->
                        { sess
                            | showFilePicker = False
                            , filePickerInput = ""
                            , pendingFileName = ""
                            , staged = sess.staged ++ [ newItem ]
                        }
                      )
                    , focusInput model
                    )

                Nothing ->
                    ( model, Cmd.none )

        FsResolvePathResult result ->
            case getActiveSession model of
                Just s ->
                    case D.decodeValue resolvePathResultDecoder result of
                        Ok rp ->
                            if rp.exists && rp.isDir then
                                let
                                    sameDir =
                                        rp.resolved == s.filePickerDir
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePickerDir = rp.resolved
                                        , filePickerSelected = 0
                                    }
                                  )
                                , if sameDir then
                                    Cmd.none
                                  else
                                    Ports.fsListDir { path = rp.resolved }
                                )

                            else
                                ( model, Cmd.none )

                        Err _ ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        -- Session Manager
        OpenSessionManager ->
            ( { model | showSessionManager = True, showGlobalMenu = False }, Ports.listSessionDirs {} )

        CloseSessionManager ->
            ( { model | showSessionManager = False }
            , focusInput model
            )

        ToggleGlobalMenu ->
            ( { model | showGlobalMenu = not model.showGlobalMenu }, Cmd.none )

        CloseGlobalMenu ->
            ( { model | showGlobalMenu = False }, Cmd.none )

        SessionDirsResult dirs ->
            ( { model | sessionDirs = dirs }, Cmd.none )

        ResumeSession id ->
            ( model, Ports.resumeSession { sessionId = id } )

        DeleteSession id ->
            ( model, Ports.deleteSessionDir { sessionId = id } )

        -- Window
        WindowMaximized v ->
            ( { model | isMaximized = v }, Cmd.none )

        GotContainerSize result ->
            case result of
                Ok el ->
                    ( { model
                        | appWidth = round el.element.width
                        , appHeight = round el.element.height
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( model, Cmd.none )

        RequerySize ->
            ( model, Task.attempt GotContainerSize (Dom.getElement "main-content") )

        -- Model Selector (per-session)
        OpenModelSelector ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | showModelSelector = True, modelSelector = Sel.open sess.models sess.modelSelector })
                    , Cmd.batch
                        [ focusAfterDelay ("model-selector-input-" ++ s.id)
                        , Ports.setCursorPos ("model-selector-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseModelSelector ->
            case getActiveSession model of
                Just s ->
                    case Sel.closeRequest s.modelSelector of
                        Nothing ->
                            -- Sync in flight: do not allow closing
                            ( model, Cmd.none )

                        Just True ->
                            -- Unsaved edits: ask before closing
                            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.askSync sess.modelSelector })
                            , Cmd.none
                            )

                        Just False ->
                            ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
                            , focusInput model
                            )

                Nothing ->
                    ( model, Cmd.none )

        SetModelSelectorInput val ->
            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.setInput modelName val sess.modelSelector })
            , Cmd.none
            )

        ModelSelectorSelectItem idx ->
            let
                scrollCmd =
                    case getActiveSession model of
                        Just s ->
                            case List.head (List.drop idx (Sel.filterItems modelName s.modelSelector.working s.modelSelector.input)) of
                                Just m ->
                                    Ports.scrollIntoView ("model-selector-item-" ++ s.id ++ "-" ++ String.fromInt m.id)

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none
            in
            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.selectItem idx sess.modelSelector })
            , scrollCmd
            )

        ModelSelectorConfirmItem ->
            case getActiveSession model of
                Just s ->
                    case Sel.selectedItem modelName s.modelSelector of
                        Just m ->
                            if Sel.isDirty s.modelSelector then
                                -- Unsaved edits: ask to sync before leaving
                                ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.askSync sess.modelSelector })
                                , Cmd.none )

                            else
                                ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
                                , Cmd.batch
                                    [ Ports.setModel { sessionId = s.id, modelId = m.id }
                                    , focusInput model
                                    ]
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorEditModel id ->
            case getActiveSession model of
                Just s ->
                    case List.filter (\m -> m.id == id) s.modelSelector.working |> List.head of
                        Just m ->
                            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.openEdit (draftFromModel m) sess.modelSelector })
                            , Cmd.batch
                                [ focusAfterDelay ("model-editor-name-" ++ s.id)
                                , Ports.setCursorPos ("model-editor-name-" ++ s.id)
                                ]
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorAddModel ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.openEdit T.emptyDraft sess.modelSelector })
                    , Cmd.batch
                        [ focusAfterDelay ("model-editor-name-" ++ s.id)
                        , Ports.setCursorPos ("model-editor-name-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorEditBack ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.backFromEdit sess.modelSelector })
                    , Cmd.batch
                        [ focusAfterDelay ("model-selector-input-" ++ s.id)
                        , Ports.setCursorPos ("model-selector-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorEditSave ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.saveItem (\d -> d.id) modelFromDraft (\m -> m.id) sess.modelSelector })
                    , Cmd.batch
                        [ focusAfterDelay ("model-selector-input-" ++ s.id)
                        , Ports.setCursorPos ("model-selector-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorEditField field value ->
            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.updateDraft (updateDraftField field value) sess.modelSelector })
            , Cmd.none
            )

        ModelSelectorDeleteModel id ->
            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.requestDelete id sess.modelSelector })
            , Cmd.none
            )

        ModelSelectorConfirmDelete id ->
            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.confirmDeleteItem (\m -> m.id) id sess.modelSelector })
            , Cmd.none
            )

        ModelSelectorCancelDelete ->
            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.cancelDelete sess.modelSelector })
            , Cmd.none
            )

        ModelSelectorConfirmSync ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.startSync sess.modelSelector })
                    , Ports.modelSync
                        { sessionId = s.id
                        , config = encodeModels s.modelSelector.working
                        }
                    )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorDiscardClose ->
            ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
            , focusInput model
            )

        ModelSelectorCancelSyncPrompt ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.backToList sess.modelSelector })
                    , Cmd.batch
                        [ focusAfterDelay ("model-selector-input-" ++ s.id)
                        , Ports.setCursorPos ("model-selector-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        ModelSelectorSyncResult isError message ->
            case getActiveSession model of
                Just s ->
                    if s.modelSelector.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if isError then
                        ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.syncFailed message sess.modelSelector })
                        , Cmd.none
                        )

                    else
                        ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
                        , focusInput model
                        )

                Nothing ->
                    ( model, Cmd.none )

        -- Default (global) Model List Editor (targets a specific preset)
        EditPresetModels preset ->
            ( { model
                | defaultModelsEditor =
                    { emptyDefaultModelsEditor
                        | show = True
                        , preset = preset
                        , state = Sel.setLoading Sel.empty
                    }
                , showGlobalMenu = False
              }
            , Ports.listDefaultModels { preset = preset }
            )

        CloseDefaultModelsEditor ->
            let
                ed =
                    model.defaultModelsEditor
            in
            case Sel.closeRequest ed.state of
                Nothing ->
                    -- Sync in flight: do not allow closing
                    ( model, Cmd.none )

                Just True ->
                    -- Unsaved edits: ask before closing
                    ( { model | defaultModelsEditor = { ed | state = Sel.askSync ed.state } }
                    , Cmd.none
                    )

                Just False ->
                    ( { model | defaultModelsEditor = emptyDefaultModelsEditor }
                    , Cmd.none
                    )

        DefaultModelsListResult raw ->
            case D.decodeValue defaultModelsListResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.defaultModelsEditor
                    in
                    if res.ok then
                        ( { model
                            | defaultModelsEditor =
                                { ed | state = Sel.setList res.models ed.state }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "model-selector-input-default"
                            , Ports.setCursorPos "model-selector-input-default"
                            ]
                        )

                    else
                        ( { model
                            | defaultModelsEditor =
                                { ed | state = Sel.setLoadError (Just res.error) ed.state }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SetDefaultModelsInput val ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model | defaultModelsEditor = { ed | state = Sel.setInput modelName val ed.state } }
            , Cmd.none
            )

        DefaultModelsSelectItem idx ->
            let
                ed =
                    model.defaultModelsEditor

                scrollCmd =
                    case List.head (List.drop idx (Sel.filterItems modelName ed.state.working ed.state.input)) of
                        Just m ->
                            Ports.scrollIntoView ("model-selector-item-default-" ++ String.fromInt m.id)

                        Nothing ->
                            Cmd.none
            in
            ( { model | defaultModelsEditor = { ed | state = Sel.selectItem idx ed.state } }
            , scrollCmd
            )

        DefaultModelsConfirmItem ->
            let
                ed =
                    model.defaultModelsEditor
            in
            case Sel.selectedItem modelName ed.state of
                Just m ->
                    ( { model
                        | defaultModelsEditor =
                            { ed | state = Sel.openEdit (draftFromModel m) ed.state }
                      }
                    , Cmd.batch
                        [ focusAfterDelay "model-editor-name-default"
                        , Ports.setCursorPos "model-editor-name-default"
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        DefaultModelsEditModel id ->
            let
                ed =
                    model.defaultModelsEditor
            in
            case List.filter (\m -> m.id == id) ed.state.working |> List.head of
                Just m ->
                    ( { model
                        | defaultModelsEditor =
                            { ed | state = Sel.openEdit (draftFromModel m) ed.state }
                      }
                    , Cmd.batch
                        [ focusAfterDelay "model-editor-name-default"
                        , Ports.setCursorPos "model-editor-name-default"
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        DefaultModelsAddModel ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor =
                    { ed | state = Sel.openEdit T.emptyDraft ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "model-editor-name-default"
                , Ports.setCursorPos "model-editor-name-default"
                ]
            )

        DefaultModelsEditBack ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor =
                    { ed | state = Sel.backFromEdit ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "model-selector-input-default"
                , Ports.setCursorPos "model-selector-input-default"
                ]
            )

        DefaultModelsEditSave ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor =
                    { ed | state = Sel.saveItem (\d -> d.id) modelFromDraft (\m -> m.id) ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "model-selector-input-default"
                , Ports.setCursorPos "model-selector-input-default"
                ]
            )

        DefaultModelsEditField field value ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor =
                    { ed | state = Sel.updateDraft (updateDraftField field value) ed.state }
              }
            , Cmd.none
            )

        DefaultModelsDeleteModel id ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor = { ed | state = Sel.requestDelete id ed.state }
              }
            , Cmd.none
            )

        DefaultModelsConfirmDelete id ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor = { ed | state = Sel.confirmDeleteItem (\m -> m.id) id ed.state }
              }
            , Cmd.none
            )

        DefaultModelsCancelDelete ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor = { ed | state = Sel.cancelDelete ed.state }
              }
            , Cmd.none
            )

        DefaultModelsConfirmSync ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor = { ed | state = Sel.startSync ed.state }
              }
            , Ports.syncDefaultModels
                { preset = ed.preset
                , config = encodeModels ed.state.working
                }
            )

        DefaultModelsDiscardClose ->
            ( { model | defaultModelsEditor = emptyDefaultModelsEditor }
            , Cmd.none
            )

        DefaultModelsCancelSyncPrompt ->
            let
                ed =
                    model.defaultModelsEditor
            in
            ( { model
                | defaultModelsEditor = { ed | state = Sel.backToList ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "model-selector-input-default"
                , Ports.setCursorPos "model-selector-input-default"
                ]
            )

        DefaultModelsSyncResult raw ->
            case D.decodeValue defaultModelsSyncResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.defaultModelsEditor
                    in
                    if ed.state.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if res.ok then
                        ( { model | defaultModelsEditor = emptyDefaultModelsEditor }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | defaultModelsEditor =
                                { ed | state = Sel.syncFailed res.error ed.state }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        EditPresetMcp preset ->
            ( { model
                | mcpEditor =
                    { emptyMcpEditor
                        | show = True
                        , preset = preset
                        , state = Sel.setLoading Sel.empty
                    }
                , showGlobalMenu = False
              }
            , Ports.listDefaultMcp { preset = preset }
            )

        CloseMcpEditor ->
            let
                ed =
                    model.mcpEditor
            in
            case Sel.closeRequest ed.state of
                Nothing ->
                    -- Sync in flight: do not allow closing
                    ( model, Cmd.none )

                Just True ->
                    -- Unsaved edits: ask before closing
                    ( { model | mcpEditor = { ed | state = Sel.askSync ed.state } }
                    , Cmd.none
                    )

                Just False ->
                    ( { model | mcpEditor = emptyMcpEditor }
                    , Cmd.none
                    )

        McpListResult raw ->
            case D.decodeValue mcpListResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.mcpEditor

                        -- mcp.conf has no id field; assign stable unique ids here
                        servers =
                            List.indexedMap (\i s -> { s | id = i + 1 }) res.servers
                    in
                    if res.ok then
                        ( { model
                            | mcpEditor =
                                { ed | state = Sel.setList servers ed.state }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "mcp-selector-input-default"
                            , Ports.setCursorPos "mcp-selector-input-default"
                            ]
                        )

                    else
                        ( { model
                            | mcpEditor =
                                { ed | state = Sel.setLoadError (Just res.error) ed.state }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SetMcpInput val ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model | mcpEditor = { ed | state = Sel.setInput mcpServerName val ed.state } }
            , Cmd.none
            )

        McpSelectItem idx ->
            let
                ed =
                    model.mcpEditor

                scrollCmd =
                    case List.head (List.drop idx (Sel.filterItems mcpServerName ed.state.working ed.state.input)) of
                        Just s ->
                            Ports.scrollIntoView ("mcp-selector-item-default-" ++ String.fromInt s.id)

                        Nothing ->
                            Cmd.none
            in
            ( { model | mcpEditor = { ed | state = Sel.selectItem idx ed.state } }
            , scrollCmd
            )

        McpConfirmItem ->
            let
                ed =
                    model.mcpEditor
            in
            case Sel.selectedItem mcpServerName ed.state of
                Just s ->
                    ( { model
                        | mcpEditor =
                            { ed | state = Sel.openEdit (draftFromMcp s) ed.state }
                      }
                    , Cmd.batch
                        [ focusAfterDelay "mcp-editor-server-default"
                        , Ports.setCursorPos "mcp-editor-server-default"
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpEditServer id ->
            let
                ed =
                    model.mcpEditor
            in
            case List.filter (\s -> s.id == id) ed.state.working |> List.head of
                Just s ->
                    ( { model
                        | mcpEditor =
                            { ed | state = Sel.openEdit (draftFromMcp s) ed.state }
                      }
                    , Cmd.batch
                        [ focusAfterDelay "mcp-editor-server-default"
                        , Ports.setCursorPos "mcp-editor-server-default"
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpAddServer ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor =
                    { ed | state = Sel.openEdit T.emptyMcpDraft ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "mcp-editor-server-default"
                , Ports.setCursorPos "mcp-editor-server-default"
                ]
            )

        McpEditBack ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor =
                    { ed | state = Sel.backFromEdit ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "mcp-selector-input-default"
                , Ports.setCursorPos "mcp-selector-input-default"
                ]
            )

        McpEditSave ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor =
                    { ed | state = Sel.saveItem (\d -> d.id) mcpFromDraft (\s -> s.id) ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "mcp-selector-input-default"
                , Ports.setCursorPos "mcp-selector-input-default"
                ]
            )

        McpEditField field value ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor =
                    { ed | state = Sel.updateDraft (updateMcpDraftField field value) ed.state }
              }
            , Cmd.none
            )

        McpDeleteServer id ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor = { ed | state = Sel.requestDelete id ed.state }
              }
            , Cmd.none
            )

        McpConfirmDelete id ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor = { ed | state = Sel.confirmDeleteItem (\s -> s.id) id ed.state }
              }
            , Cmd.none
            )

        McpCancelDelete ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor = { ed | state = Sel.cancelDelete ed.state }
              }
            , Cmd.none
            )

        McpConfirmSync ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor = { ed | state = Sel.startSync ed.state }
              }
            , Ports.syncDefaultMcp
                { preset = ed.preset
                , config = encodeMcpServers ed.state.working
                }
            )

        McpDiscardClose ->
            ( { model | mcpEditor = emptyMcpEditor }
            , Cmd.none
            )

        McpCancelSyncPrompt ->
            let
                ed =
                    model.mcpEditor
            in
            ( { model
                | mcpEditor = { ed | state = Sel.backToList ed.state }
              }
            , Cmd.batch
                [ focusAfterDelay "mcp-selector-input-default"
                , Ports.setCursorPos "mcp-selector-input-default"
                ]
            )

        McpSyncResult raw ->
            case D.decodeValue mcpSyncResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.mcpEditor
                    in
                    if ed.state.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if res.ok then
                        ( { model | mcpEditor = emptyMcpEditor }
                        , Cmd.none
                        )

                    else
                        ( { model
                            | mcpEditor =
                                { ed | state = Sel.syncFailed res.error ed.state }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        -- Global Settings (targets a specific preset)
        EditPresetSettings preset ->
            ( { model
                | settingsEditor =
                    { emptySettingsEditor
                        | show = True
                        , loading = True
                        , preset = preset
                    }
                , showGlobalMenu = False
              }
            , Ports.listGlobalSettings { preset = preset }
            )

        CloseSettingsEditor ->
            let
                ed =
                    model.settingsEditor
            in
            if ed.syncing then
                -- Do not allow closing while a sync is in flight
                ( model, Cmd.none )

            else
                ( { model | settingsEditor = emptySettingsEditor }
                , Cmd.none
                )

        SetToolConfirm val ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor =
                    { ed
                        | toolConfirm = val
                        , error = Nothing
                    }
              }
            , Cmd.none
            )

        SettingsSave ->
            let
                ed =
                    model.settingsEditor
            in
            ( { model
                | settingsEditor = { ed | syncing = True, error = Nothing }
              }
            , Ports.syncGlobalSettings { preset = ed.preset, toolConfirm = ed.toolConfirm }
            )

        SettingsListResult raw ->
            case D.decodeValue settingsListResultDecoder raw of
                Ok res ->
                    let
                        ed =
                            model.settingsEditor
                    in
                    if res.ok then
                        ( { model
                            | settingsEditor =
                                { ed
                                    | loading = False
                                    , toolConfirm = res.toolConfirm
                                    , error = Nothing
                                }
                          }
                        , Cmd.batch
                            [ focusAfterDelay "settings-tool-confirm"
                            , Ports.setCursorPos "settings-tool-confirm"
                            ]
                        )

                    else
                        ( { model
                            | settingsEditor =
                                { ed
                                    | loading = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        SettingsSyncResult raw ->
            case D.decodeValue settingsSyncResultDecoder raw of
                Ok res ->
                    if res.ok then
                        ( { model | settingsEditor = emptySettingsEditor }
                        , Cmd.none
                        )

                    else
                        let
                            ed =
                                model.settingsEditor
                        in
                        ( { model
                            | settingsEditor =
                                { ed
                                    | syncing = False
                                    , error = Just res.error
                                }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        -- Presets
        OpenPresetManager ->
            ( { model
                | presetManager =
                    { emptyPresetManager
                        | show = True
                        , loading = True
                    }
                , showGlobalMenu = False
              }
            , Ports.listPresets {}
            )

        ClosePresetManager ->
            let
                pm =
                    model.presetManager
            in
            if pm.busy then
                -- Do not allow closing while an action is in flight
                ( model, Cmd.none )

            else
                ( { model | presetManager = emptyPresetManager }
                , Cmd.none
                )

        PresetCopy source ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing }
              }
            , Ports.copyPreset
                { source = source
                , name = nextCopyName source model.presets
                }
            )

        PresetSetActive name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing }
              }
            , Ports.setActivePreset { name = name }
            )

        PresetRenameStart name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | renaming = Just name, renameInput = name }
              }
            , Cmd.none
            )

        SetPresetRenameInput val ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | renameInput = val, error = Nothing }
              }
            , Cmd.none
            )

        PresetRenameSave oldName ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing }
              }
            , Ports.renamePreset { oldName = oldName, newName = pm.renameInput }
            )

        PresetRenameCancel ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | renaming = Nothing, renameInput = "" }
              }
            , Cmd.none
            )

        PresetToggleEdit name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager =
                    { pm
                        | editing =
                            if pm.editing == Just name then
                                Nothing
                            else
                                Just name
                    }
              }
            , Cmd.none
            )

        PresetDelete name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | confirmDelete = Just name }
              }
            , Cmd.none
            )

        PresetConfirmDelete name ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | busy = True, error = Nothing, confirmDelete = Nothing }
              }
            , Ports.deletePreset { name = name }
            )

        PresetCancelDelete ->
            let
                pm =
                    model.presetManager
            in
            ( { model
                | presetManager = { pm | confirmDelete = Nothing }
              }
            , Cmd.none
            )

        PresetsListResult raw ->
            case D.decodeValue presetsListResultDecoder raw of
                Ok res ->
                    if res.ok then
                        let
                            pm =
                                model.presetManager

                            active =
                                List.filterMap
                                    (\p -> if p.isActive then Just p.name else Nothing)
                                    res.presets
                                    |> List.head
                                    |> Maybe.withDefault ""
                        in
                        ( { model
                            | presets = res.presets
                            , activePreset = active
                            , presetManager = { pm | loading = False, error = Nothing }
                          }
                        , Cmd.none
                        )

                    else
                        let
                            pm =
                                model.presetManager
                        in
                        ( { model
                            | presetManager = { pm | loading = False, error = Just res.error }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        PresetActionResult raw ->
            case D.decodeValue presetActionResultDecoder raw of
                Ok res ->
                    let
                        pm =
                            model.presetManager
                    in
                    if res.ok then
                        ( { model
                            | presetManager =
                                { pm
                                    | busy = False
                                    , renaming = Nothing
                                    , renameInput = ""
                                    , confirmDelete = Nothing
                                }
                          }
                        , Ports.listPresets {}
                        )

                    else
                        ( { model
                            | presetManager = { pm | busy = False, error = Just res.error }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        -- Help Window
        OpenHelpWindow ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        { sess
                            | showHelpWindow = True
                            , helpFilter = ""
                            , helpSelected = 0
                            , helpScroll = 0
                        }
                      )
                    , Cmd.batch
                        [ focusAfterDelay ("help-filter-input-" ++ s.id)
                        , Ports.setCursorPos ("help-filter-input-" ++ s.id)
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseHelpWindow ->
            ( updateActiveSession model (\s -> { s | showHelpWindow = False })
            , focusInput model
            )

        SetHelpFilter val ->
            ( updateActiveSession model (\s ->
                let
                    filtered =
                        filterHelpItems val helpItems

                    clampedSelected =
                        if List.length filtered <= s.helpSelected then
                            max 0 (List.length filtered - 1)
                        else
                            s.helpSelected
                in
                { s
                    | helpFilter = val
                    , helpSelected = clampedSelected
                }
              )
            , Cmd.none
            )

        HelpSelectItem idx ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess -> { sess | helpSelected = idx })
                    , Ports.scrollIntoView ("help-item-" ++ s.id ++ "-" ++ String.fromInt idx)
                    )

                Nothing ->
                    ( model, Cmd.none )

        HelpCmdMsg cmd ->
            case model.activeId of
                Just sid ->
                    let
                        -- Focus input and insert the command prefix
                        newSessions =
                            Dict.update sid
                                (\maybeS ->
                                    case maybeS of
                                        Just s ->
                                            Just
                                                { s
                                                    | showHelpWindow = False
                                                    , input = cmd ++ " "
                                                }

                                        Nothing ->
                                            maybeS
                                )
                                model.sessions
                    in
                    ( { model | sessions = newSessions }
                    , Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ sid))
                    )

                Nothing ->
                    ( model, Cmd.none )

        FillMcpAuthUrl url ->
            case getActiveSession model of
                Just s ->
                    let
                        serverName =
                            case s.pendingMcpAuth of
                                Just auth ->
                                    Maybe.withDefault "" auth.toolName

                                Nothing ->
                                    ""
                    in
                    ( model
                    , Ports.fillMcpAuthUrl
                        { sessionId = s.id
                        , serverName = serverName
                        , authUrl = url
                        }
                    )

                Nothing ->
                    ( model, Cmd.none )

        ScrollPosition scrollTop scrollHeight clientHeight ->
            let
                atBottom =
                    scrollTop + clientHeight >= scrollHeight - 5
            in
            ( { model | atBottom = atBottom }, Cmd.none )

        KeyDown key ctrl alt defaultPrevented ->
            -- If another handler already processed this key (e.g. textarea), skip
            if defaultPrevented then
                ( model, Cmd.none )

            -- Escape or Ctrl+[ dismisses the context menu.
            -- Overlays are closed via their close buttons only (no Escape).
            else if key == "Escape" || (key == "[" && ctrl) then
                if model.ctxVisible then
                    ( { model | ctxVisible = False }, Cmd.none )

                else
                    ( model, Cmd.none )

            -- Ctrl+W closes the active session window
            else if key == "w" && ctrl then
                case model.activeId of
                    Just sid ->
                        update (CloseSession sid) model

                    Nothing ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        ForSession sid innerMsg ->
            update innerMsg { model | activeId = Just sid }

        ResizeStart id handle mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    ( { model
                        | resizeInfo =
                            Just
                                { sessionId = id
                                , handle = handle
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                , startWinW = pos.w
                                , startWinH = pos.h
                                }
                        , windowPositions = Dict.insert id { pos | z = model.nextZIndex } model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        , activeId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        WindowDragStart id mouseX mouseY ->
            case Dict.get id model.windowPositions of
                Just pos ->
                    ( { model
                        | dragInfo =
                            Just
                                { sessionId = id
                                , startMouseX = mouseX
                                , startMouseY = mouseY
                                , startWinX = pos.x
                                , startWinY = pos.y
                                }
                        , windowPositions = Dict.insert id { pos | z = model.nextZIndex } model.windowPositions
                        , nextZIndex = model.nextZIndex + 1
                        , activeId = Just id
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        WindowDragMove mouseX mouseY ->
            case model.dragInfo of
                Just info ->
                    let
                        dx =
                            round mouseX - round info.startMouseX

                        dy =
                            round mouseY - round info.startMouseY

                        newRawX =
                            info.startWinX + dx

                        newRawY =
                            info.startWinY + dy

                        -- Look up current window size for right/bottom clamping
                        winSize =
                            Dict.get info.sessionId model.windowPositions

                        winW =
                            Maybe.map .w winSize |> Maybe.withDefault 560

                        winH =
                            Maybe.map .h winSize |> Maybe.withDefault 640

                        maxX =
                            max 0 (model.appWidth - winW)

                        maxY =
                            max 0 (model.appHeight - winH)

                        newX =
                            clamp 0 maxX newRawX

                        newY =
                            clamp 0 maxY newRawY
                    in
                    ( { model
                        | windowPositions =
                            Dict.update info.sessionId
                                (Maybe.map (\pos -> { pos | x = newX, y = newY }))
                                model.windowPositions
                      }
                    , Cmd.none
                    )

                Nothing ->
                    handleResizeMove model mouseX mouseY

        WindowDragEnd ->
            ( { model | dragInfo = Nothing, resizeInfo = Nothing }, Cmd.none )

        ActivateSession id ->
            if model.activeId == Just id then
                ( model, Cmd.none )
            else
                let
                    newPositions =
                        Dict.update id
                            (Maybe.map (\pos -> { pos | z = model.nextZIndex }))
                            model.windowPositions
                in
                ( { model
                    | activeId = Just id
                    , windowPositions = newPositions
                    , nextZIndex = model.nextZIndex + 1
                  }
                , Cmd.none
                )

        NoOp ->
            ( model, Cmd.none )


-- ─── Helpers ──────────────────────────────────────────────────────────

updateAfterConfirm : Model -> String -> Model
updateAfterConfirm model sid =
    case Dict.get sid model.sessions of
        Just s ->
            let
                newQueue =
                    case s.pendingConfirm of
                        [] -> []
                        _ :: rest -> rest
            in
            { model | sessions = Dict.insert sid { s | pendingConfirm = newQueue } model.sessions }

        Nothing ->
            model


handleResizeMove : Model -> Float -> Float -> ( Model, Cmd Msg )
handleResizeMove model mouseX mouseY =
    case model.resizeInfo of
        Just info ->
            let
                dx =
                    round mouseX - round info.startMouseX

                dy =
                    round mouseY - round info.startMouseY
            in
            let
                config =
                    { handle = info.handle
                    , dx = dx
                    , dy = dy
                    , startX = info.startWinX
                    , startY = info.startWinY
                    , startW = info.startWinW
                    , startH = info.startWinH
                    , minW = minWinW
                    , minH = minWinH
                    }

                r =
                    resizeDimensions config

                -- Clamp so window stays within viewport
                clampedX =
                    max 0 (min (max 0 (model.appWidth - r.w)) r.x)

                clampedY =
                    max 0 (min (max 0 (model.appHeight - r.h)) r.y)

                -- If x/y was clamped, adjust w/h so right/bottom edge stays put
                adjustW =
                    if clampedX /= r.x then
                        r.w + (r.x - clampedX)
                    else
                        r.w

                adjustH =
                    if clampedY /= r.y then
                        r.h + (r.y - clampedY)
                    else
                        r.h

                finalW =
                    max minWinW adjustW

                finalH =
                    max minWinH adjustH
            in
            ( { model
                | windowPositions =
                    Dict.update info.sessionId
                        (Maybe.map (\pos -> { pos | x = clampedX, y = clampedY, w = finalW, h = finalH }))
                        model.windowPositions
              }
            , Cmd.none
            )

        Nothing ->
            ( model, Cmd.none )


-- Focus an element by ID after a brief delay to ensure the DOM is fully rendered
focusAfterDelay : String -> Cmd Msg
focusAfterDelay id =
    Task.attempt (\_ -> NoOp)
        (Process.sleep 0
            |> Task.andThen (\_ -> Dom.focus id)
        )


-- Apply a buffered transport event to the sessions dict.
-- Returns the updated sessions dict unchanged if the event can't be decoded or session not found.
applyPendingEvent : E.Value -> Dict String T.SessionState -> Dict String T.SessionState
applyPendingEvent raw sessions =
    -- Try FrameEvent first (most common for initial messages)
    case D.decodeValue P.frameEventDecoder raw of
        Ok ev ->
            case Dict.get ev.sessionId sessions of
                Just session ->
                    Dict.insert ev.sessionId (H.handleFrameEvent session ev) sessions

                Nothing ->
                    sessions

        Err _ ->
            -- Try DeltaEvent
            case D.decodeValue P.deltaEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId sessions of
                        Just session ->
                            Dict.insert ev.sessionId (H.handleDeltaEvent session ev) sessions

                        Nothing ->
                            sessions

                Err _ ->
                    -- Try StatusEvent
                    case D.decodeValue P.statusEventDecoder raw of
                        Ok ev ->
                            case Dict.get ev.sessionId sessions of
                                Just session ->
                                    Dict.insert ev.sessionId
                                        { session
                                            | connected = ev.connected
                                            , statusMsg = ev.message
                                        }
                                        sessions

                                Nothing ->
                                    sessions

                        Err _ ->
                            sessions


decodeDirEntry : E.Value -> Maybe T.DirEntry
decodeDirEntry val =
    case D.decodeValue (D.map2 T.DirEntry (D.field "name" D.string) (D.field "isDir" D.bool)) val of
        Ok entry -> Just entry
        Err _ -> Nothing


type alias SessionDir =
    { id : String
    , hasSessionFile : Bool
    , createdAt : String
    }


sessionDirDecoder : D.Decoder SessionDir
sessionDirDecoder =
    D.map3 SessionDir
        (D.field "id" D.string)
        (D.field "has_session_file" D.bool)
        (D.field "created_at" D.string)


decodeSessionDir : E.Value -> Maybe SessionDir
decodeSessionDir val =
    case D.decodeValue sessionDirDecoder val of
        Ok dir -> Just dir
        Err _ -> Nothing


filterEntries : T.SessionState -> List T.DirEntry
filterEntries session =
    let
        term =
            String.trim session.filePickerFilter
    in
    if String.isEmpty term then
        session.filePickerEntries

    else
        List.filter (\e -> Fuzzy.fuzzyMatch term (String.toLower e.name)) session.filePickerEntries


-- Parse file picker input into (needsResolve, resolvePath, filterText)
-- Matches alayacore terminal adapter's navigateByPath logic.
--
-- ~             → resolve "~",          filter ""
-- ~/path        → resolve "~",          filter "path"
-- ~/dir/        → resolve "~/dir",      filter ""
-- ~/dir/sub     → resolve "~/dir",      filter "sub"
-- /abs/path     → resolve "/abs/path",  filter ""  (if ends with /)
-- /abs/foo      → resolve "/abs",       filter "foo"
-- ../rel        → resolve baseDir/..,   filter "rel"
-- foo           → no resolve,           filter "foo"  (fuzzy search)


parsePathInput : String -> String -> String -> ( Bool, String, String )
parsePathInput input currentDir baseDir =
    if String.isEmpty input then
        ( False, "", "" )

    else if String.startsWith "~" input then
        parseTildePath input

    else if String.startsWith "/" input then
        parseAbsolutePath input

    else if String.contains "/" input || input == ".." then
        parseRelativePath input baseDir

    else
        -- Plain text: no navigation, use as filter
        ( False, "", input )


parseTildePath : String -> ( Bool, String, String )
parseTildePath input =
    let
        rest =
            String.dropLeft 1 input
    in
    if rest == "" || rest == "/" then
        -- "~" or "~/" → navigate to home
        ( True, "~", "" )

    else if String.endsWith "/" rest then
        -- "~/dir/" → navigate to ~/dir
        ( True, input, "" )

    else
        -- "~/dir/file" → navigate to ~/dir, filter "file"
        let
            dirPart =
                "~/" ++ (String.join "/" (List.take (List.length (String.split "/" rest) - 1) (String.split "/" rest)))

            filePart =
                Maybe.withDefault "" (List.head (List.reverse (String.split "/" rest)))
        in
        if dirPart == "~/" then
            -- "~/file" → navigate to ~, filter "file"
            ( True, "~", filePart )
        else
            ( True, dirPart, filePart )


parseAbsolutePath : String -> ( Bool, String, String )
parseAbsolutePath input =
    let
        trimmed =
            if String.endsWith "/" input && input /= "/" then
                String.dropRight 1 input
            else
                input
    in
    if trimmed == "/" || String.endsWith "/" input then
        -- "/" or "/path/" → navigate to that dir
        ( True, trimmed, "" )

    else
        -- "/path/to/file" → navigate to /path/to, filter "file"
        let
            parts =
                String.split "/" trimmed

            filePart =
                Maybe.withDefault "" (List.head (List.reverse parts))

            dirPart =
                String.join "/" (List.take (List.length parts - 1) parts)
        in
        if dirPart == "" then
            -- "/file" → navigate to /, filter "file"
            ( True, "/", filePart )
        else
            ( True, dirPart, filePart )


parseRelativePath : String -> String -> ( Bool, String, String )
parseRelativePath input baseDir =
    if input == ".." then
        -- Navigate to parent
        ( True, baseDir ++ "/..", "" )

    else if String.endsWith "/" input then
        -- "dir/" → navigate to baseDir/dir
        ( True, baseDir ++ "/" ++ (String.dropRight 1 input), "" )

    else
        -- "dir/file" → navigate to baseDir/dir, filter "file"
        let
            filePart =
                Maybe.withDefault "" (List.head (List.reverse (String.split "/" input)))

            dirPart =
                String.join "/" (List.take (List.length (String.split "/" input) - 1) (String.split "/" input))
        in
        if dirPart == "" then
            -- "file" (shouldn't happen since input contains "/" but just in case)
            ( False, "", input )
        else
            ( True, baseDir ++ "/" ++ dirPart, filePart )


-- File Picker Helpers

type alias ResolvedPathResult =
    { resolved : String
    , exists : Bool
    , isDir : Bool
    }


resolvePathResultDecoder : D.Decoder ResolvedPathResult
resolvePathResultDecoder =
    D.map3 ResolvedPathResult
        (D.field "resolved" D.string)
        (D.field "exists" D.bool)
        (D.field "isDir" D.bool)


detectMediaType : String -> T.MediaType
detectMediaType name =
    let
        ext =
            String.toLower (Maybe.withDefault "" (List.head (List.reverse (String.split "." name))))
    in
    case ext of
        "jpg" -> T.Image
        "jpeg" -> T.Image
        "png" -> T.Image
        "gif" -> T.Image
        "webp" -> T.Image
        "bmp" -> T.Image
        "svg" -> T.Image
        "mp3" -> T.Audio
        "wav" -> T.Audio
        "ogg" -> T.Audio
        "flac" -> T.Audio
        "m4a" -> T.Audio
        "mp4" -> T.Video
        "webm" -> T.Video
        "avi" -> T.Video
        "mov" -> T.Video
        "mkv" -> T.Video
        "pdf" -> T.Document
        "txt" -> T.Document
        "md" -> T.Document
        "json" -> T.Document
        "csv" -> T.Document
        "html" -> T.Document
        "htm" -> T.Document
        _ -> T.Document

-- ─── String Helpers ─────────────────────────────────────────────────

lastIndexOf : Char -> String -> Maybe Int
lastIndexOf char str =
    lastIndexOfHelp char str 0 Nothing


lastIndexOfHelp : Char -> String -> Int -> Maybe Int -> Maybe Int
lastIndexOfHelp char str idx found =
    if idx >= String.length str then
        found
    else
        case String.uncons (String.dropLeft idx str) of
            Just ( c, _ ) ->
                if c == char then
                    lastIndexOfHelp char str (idx + 1) (Just idx)
                else
                    lastIndexOfHelp char str (idx + 1) found

            Nothing ->
                found


-- ─── Selector Search Keys ────────────────────────────────────────────
-- Passed to Session.Selector.filterItems (and the overlay list view)
-- to fuzzy-match the selector's search input.

modelName : T.ModelInfo -> String
modelName m =
    m.name


mcpServerName : T.McpInfo -> String
mcpServerName s =
    s.server


draftFromMcp : T.McpInfo -> T.McpDraft
draftFromMcp s =
    { id = s.id
    , type_ = s.type_
    , server = s.server
    , url = s.url
    , command = s.command
    , args = s.args
    , env = s.env
    , authType = s.authType
    , authToken = s.authToken
    , authClientId = s.authClientId
    , authClientSecret = s.authClientSecret
    , protoVersion =
        -- Old configs may lack proto-version; default it to the latest so
        -- the dropdown shows the real value instead of silently selecting
        -- the first option while the draft stays empty.
        if String.isEmpty (String.trim s.protoVersion) then
            T.latestMcpProtoVersion

        else
            s.protoVersion
    }


mcpFromDraft : T.McpDraft -> T.McpInfo
mcpFromDraft d =
    { id = d.id
    , type_ = d.type_
    , server = String.trim d.server
    , url = String.trim d.url
    , command = String.trim d.command
    , args = String.trim d.args
    , env = String.trim d.env
    , authType = String.trim d.authType
    , authToken = String.trim d.authToken
    , authClientId = String.trim d.authClientId
    , authClientSecret = String.trim d.authClientSecret
    , protoVersion = String.trim d.protoVersion
    }


updateMcpDraftField : String -> String -> T.McpDraft -> T.McpDraft
updateMcpDraftField field value draft =
    case field of
        "type" ->
            -- Switching kind clears the other kind's fields to avoid residue
            if value == "http" then
                { draft | type_ = value, command = "", args = "", env = "" }

            else
                { draft | type_ = value, url = "" }

        "server" ->
            { draft | server = value }

        "url" ->
            { draft | url = value }

        "command" ->
            { draft | command = value }

        "args" ->
            { draft | args = value }

        "env" ->
            { draft | env = value }

        "auth-type" ->
            { draft | authType = value }

        "auth-token" ->
            { draft | authToken = value }

        "auth-client-id" ->
            { draft | authClientId = value }

        "auth-client-secret" ->
            { draft | authClientSecret = value }

        "proto-version" ->
            { draft | protoVersion = value }

        _ ->
            draft


encodeMcpServers : List T.McpInfo -> String
encodeMcpServers servers =
    E.encode 0 (E.list encodeMcpServer servers)


encodeMcpServer : T.McpInfo -> E.Value
encodeMcpServer s =
    E.object
        [ ( "server", E.string s.server )
        , ( "url", E.string s.url )
        , ( "command", E.string s.command )
        , ( "args", E.string s.args )
        , ( "env", E.string s.env )
        , ( "auth_type", E.string s.authType )
        , ( "auth_token", E.string s.authToken )
        , ( "auth_client_id", E.string s.authClientId )
        , ( "auth_client_secret", E.string s.authClientSecret )
        , ( "proto_version", E.string s.protoVersion )
        ]


draftFromModel : T.ModelInfo -> T.ModelDraft
draftFromModel m =
    { id = m.id
    , name = m.name
    , protocolType = m.protocolType
    , baseUrl = m.baseUrl
    , apiKey = m.apiKey
    , modelName = m.modelName
    , contextLimit = String.fromInt m.contextLimit
    , maxTokens = String.fromInt m.maxTokens
    }


modelFromDraft : T.ModelDraft -> T.ModelInfo
modelFromDraft d =
    { id = d.id
    , name = String.trim d.name
    , protocolType = String.trim d.protocolType
    , baseUrl = String.trim d.baseUrl
    , apiKey = d.apiKey
    , modelName = String.trim d.modelName
    , contextLimit = String.toInt d.contextLimit |> Maybe.withDefault 0
    , maxTokens = String.toInt d.maxTokens |> Maybe.withDefault 0
    }


updateDraftField : String -> String -> T.ModelDraft -> T.ModelDraft
updateDraftField field value draft =
    case field of
        "name" ->
            { draft | name = value }

        "protocol_type" ->
            { draft | protocolType = value }

        "base_url" ->
            { draft | baseUrl = value }

        "api_key" ->
            { draft | apiKey = value }

        "model_name" ->
            { draft | modelName = value }

        "context_limit" ->
            { draft | contextLimit = value }

        "max_tokens" ->
            { draft | maxTokens = value }

        _ ->
            draft


encodeModels : List T.ModelInfo -> String
encodeModels models =
    E.encode 0 (E.list encodeModel models)


encodeModel : T.ModelInfo -> E.Value
encodeModel m =
    E.object
        [ ( "id", E.int m.id )
        , ( "name", E.string m.name )
        , ( "protocol_type", E.string m.protocolType )
        , ( "base_url", E.string m.baseUrl )
        , ( "api_key", E.string m.apiKey )
        , ( "model_name", E.string m.modelName )
        , ( "context_limit", E.int m.contextLimit )
        , ( "max_tokens", E.int m.maxTokens )
        ]


-- Decode a model_sync CO result: Just ( isError, message ) when the frame
-- is a CO for the model_sync command, Nothing otherwise.
decodeSyncOutcome : E.Value -> Maybe ( Bool, String )
decodeSyncOutcome raw =
    case D.decodeValue P.frameEventDecoder raw of
        Ok ev ->
            if ev.tag == "CO" then
                case ev.json of
                    Just json ->
                        let
                            name =
                                D.decodeValue (D.field "name" D.string) json
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""

                            isError =
                                D.decodeValue (D.field "is_error" D.bool) json
                                    |> Result.toMaybe
                                    |> Maybe.withDefault False

                            message =
                                D.decodeValue (D.field "output" (D.field "message" D.string)) json
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""
                        in
                        if name == "model_sync" then
                            Just ( isError, message )

                        else
                            Nothing

                    Nothing ->
                        Nothing

            else
                Nothing

        Err _ ->
            Nothing


defaultModelsListResultDecoder : D.Decoder { ok : Bool, models : List T.ModelInfo, error : String }
defaultModelsListResultDecoder =
    D.map3
        (\ok models error -> { ok = ok, models = models, error = error })
        (D.field "ok" D.bool)
        (D.field "models" (D.list H.modelInfoDecoder))
        (D.field "error" D.string)


defaultModelsSyncResultDecoder : D.Decoder { ok : Bool, error : String }
defaultModelsSyncResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


mcpInfoDecoder : D.Decoder T.McpInfo
mcpInfoDecoder =
    D.succeed T.McpInfo
        |> andMap (D.succeed 0)
        |> andMap (optionalString "type")
        |> andMap (D.field "server" D.string)
        |> andMap (optionalString "url")
        |> andMap (optionalString "command")
        |> andMap (optionalString "args")
        |> andMap (optionalString "env")
        |> andMap (optionalString "auth_type")
        |> andMap (optionalString "auth_token")
        |> andMap (optionalString "auth_client_id")
        |> andMap (optionalString "auth_client_secret")
        |> andMap (optionalString "proto_version")


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap dx df =
    D.map2 (\f x -> f x) df dx


optionalString : String -> D.Decoder String
optionalString key =
    D.oneOf [ D.field key D.string, D.succeed "" ]


mcpListResultDecoder : D.Decoder { ok : Bool, servers : List T.McpInfo, error : String }
mcpListResultDecoder =
    D.map3
        (\ok servers error -> { ok = ok, servers = servers, error = error })
        (D.field "ok" D.bool)
        (D.field "servers" (D.list mcpInfoDecoder))
        (D.field "error" D.string)


mcpSyncResultDecoder : D.Decoder { ok : Bool, error : String }
mcpSyncResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


settingsListResultDecoder : D.Decoder { ok : Bool, toolConfirm : String, error : String }
settingsListResultDecoder =
    D.map3
        (\ok toolConfirm error -> { ok = ok, toolConfirm = toolConfirm, error = error })
        (D.field "ok" D.bool)
        (D.field "tool_confirm" D.string)
        (D.field "error" D.string)


settingsSyncResultDecoder : D.Decoder { ok : Bool, error : String }
settingsSyncResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


presetInfoDecoder : D.Decoder PresetInfo
presetInfoDecoder =
    D.map2 PresetInfo
        (D.field "name" D.string)
        (D.field "is_active" D.bool)


presetsListResultDecoder : D.Decoder { ok : Bool, presets : List PresetInfo, error : String }
presetsListResultDecoder =
    D.map3
        (\ok presets error -> { ok = ok, presets = presets, error = error })
        (D.field "ok" D.bool)
        (D.field "presets" (D.list presetInfoDecoder))
        (D.field "error" D.string)


presetActionResultDecoder : D.Decoder { ok : Bool, error : String }
presetActionResultDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


-- ─── Help Items ──────────────────────────────────────────────────────

helpItems : List HelpItem
helpItems =
    [ { id = 1, key = "Commands", desc = "", isSection = True, isCommand = False }
    , { id = 2, key = ":tool_confirm <id>", desc = "Confirm pending tool", isSection = False, isCommand = True }
    , { id = 3, key = ":tool_decline <id>", desc = "Decline pending tool", isSection = False, isCommand = True }
    , { id = 4, key = ":mcp_confirm <server> <code> <redirect_uri>", desc = "Confirm OAuth authorization", isSection = False, isCommand = True }
    , { id = 5, key = ":mcp_decline <server>", desc = "Decline OAuth authorization", isSection = False, isCommand = True }
    , { id = 6, key = ":continue", desc = "Retry last prompt", isSection = False, isCommand = True }
    , { id = 7, key = ":reason <0|1|2>", desc = "Set reasoning level", isSection = False, isCommand = True }
    , { id = 8, key = ":cancel", desc = "Cancel current task", isSection = False, isCommand = True }
    , { id = 9, key = ":summarize", desc = "Summarize & compress history", isSection = False, isCommand = True }
    , { id = 10, key = ":theme_set <name>", desc = "Switch theme by name", isSection = False, isCommand = True }
    , { id = 11, key = ":model_set <id>", desc = "Switch model by ID", isSection = False, isCommand = True }
    , { id = 12, key = ":model_load", desc = "Reload model config", isSection = False, isCommand = True }
    , { id = 13, key = ":model_sync", desc = "Apply edited model config", isSection = False, isCommand = True }
    , { id = 14, key = ":save [filename]", desc = "Save session", isSection = False, isCommand = True }
    , { id = 15, key = ":fork <id> <filename>", desc = "Fork session up to content", isSection = False, isCommand = True }
    , { id = 16, key = ":video_config <fps> <0|1>", desc = "Set video FPS and resolution", isSection = False, isCommand = True }
    , { id = 17, key = ":suspend", desc = "Suspend process", isSection = False, isCommand = True }
    , { id = 18, key = ":quit", desc = "Exit application", isSection = False, isCommand = True }
    , { id = 19, key = ":help", desc = "Open help window", isSection = False, isCommand = True }
    ]


-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Ports.onScroll (\{ scrollTop, scrollHeight, clientHeight } ->
            ScrollPosition scrollTop scrollHeight clientHeight
          )
        , Ports.onDelta (\raw -> DeltaEvent raw)
        , Ports.onFrame (\raw -> FrameEvent raw)
        , Ports.onStatus (\raw -> StatusEvent raw)
        , Ports.onDefaultModelsList (\raw -> DefaultModelsListResult raw)
        , Ports.onDefaultModelsSyncResult (\raw -> DefaultModelsSyncResult raw)
        , Ports.onDefaultMcpList (\raw -> McpListResult raw)
        , Ports.onDefaultMcpSyncResult (\raw -> McpSyncResult raw)
        , Ports.onGlobalSettingsList (\raw -> SettingsListResult raw)
        , Ports.onGlobalSettingsSyncResult (\raw -> SettingsSyncResult raw)
        , Ports.onPresetsList (\raw -> PresetsListResult raw)
        , Ports.onPresetActionResult (\raw -> PresetActionResult raw)
        , Ports.onSessionCreated (\id -> SessionCreated id)
        , Ports.onSessionDirs (\dirs -> SessionDirsResult dirs)
        , Ports.onFsListDir (\entries -> FsListDirResult entries)
        , Ports.onFsHomeDir (\home -> FsHomeDirResult home)
        , Ports.onFsReadFileDataUri (\uri -> FsReadFileResult uri)
        , Ports.onFsResolvePath (\result -> FsResolvePathResult result)
        , Ports.onWindowMaximized (\v -> WindowMaximized v)
        , Evts.onResize (\_ _ -> RequerySize)
        , Evts.onKeyDown <|
            D.map4 KeyDown
                (D.field "key" D.string)
                (D.field "ctrlKey" D.bool)
                (D.field "altKey" D.bool)
                (D.field "defaultPrevented" D.bool)
        , Evts.onMouseMove (D.map2 WindowDragMove (D.field "clientX" D.float) (D.field "clientY" D.float))
        , Evts.onMouseUp (D.succeed WindowDragEnd)
        ]


-- VIEW

view : Model -> Html Msg
view model =
    Html.div [ Attr.class "app" ]
        [ Html.node "style"
            []
            [ Html.text (".app{--content-width:" ++ String.fromInt (min 864 (max 400 model.appWidth - 40)) ++ "px}") ]
        , Html.div [ Attr.id "main-content", Attr.class "main-content" ]
            (if List.isEmpty model.sessionOrder then
                [ viewNoSessionPanel model ]

             else
                List.map (\id -> viewSessionPanel model id) model.sessionOrder
            )
        , viewGlobalMenu model
        , viewContextMenu model
        , viewSessionManagerOverlay model
        , viewPresetManagerOverlay model
        , viewDefaultModelsEditorOverlay model
        , viewMcpEditorOverlay model
        , viewSettingsEditorOverlay model
        ]


viewSessionPanel : Model -> String -> Html Msg
viewSessionPanel model id =
    case Dict.get id model.sessions of
        Just session ->
            let
                isActive =
                    model.activeId == Just id

                idx =
                    case Dict.get id model.sessionNums of
                        Just n -> n
                        Nothing -> 0

                winPos =
                    Dict.get id model.windowPositions

                positionStyles =
                    case winPos of
                        Just p ->
                            [ Attr.style "left" (String.fromInt p.x ++ "px")
                            , Attr.style "top" (String.fromInt p.y ++ "px")
                            , Attr.style "width" (String.fromInt p.w ++ "px")
                            , Attr.style "height" (String.fromInt p.h ++ "px")
                            , Attr.style "z-index" (String.fromInt p.z)
                            , Attr.style "position" "absolute"
                            ]

                        Nothing ->
                            []

                panelClasses =
                    "session-panel"
                        ++ (if isActive then " session-panel-active" else "")

            in
            Html.div
                ([ Attr.class panelClasses
                 , Ev.onClick (SwitchSession id)
                 , Ev.on "mousedown" (D.succeed (ActivateSession id))
                 ]
                    ++ positionStyles
                )
                [ viewResizeHandle id NW
                , viewResizeHandle id N
                , viewResizeHandle id NE
                , viewResizeHandle id W
                , viewResizeHandle id E
                , viewResizeHandle id SW
                , viewResizeHandle id S
                , viewResizeHandle id SE
                , Html.div
                    [ Attr.class "session-bar"
                    , Ev.preventDefaultOn "mousedown"
                        (D.map2
                            (\clientX clientY ->
                                ( WindowDragStart id clientX clientY, True )
                            )
                            (D.field "clientX" D.float)
                            (D.field "clientY" D.float)
                        )
                    , Attr.title "Drag to move"
                    ]
                    [ Html.span [ Attr.class "session-bar-title" ]
                        [ Html.text
                            (if session.activeModelName /= "" then
                                "Session " ++ String.fromInt idx ++ " — " ++ session.activeModelName
                             else
                                "Session " ++ String.fromInt idx
                            )
                        ]
                    , Html.button
                        [ Attr.class "session-bar-close"
                        , Ev.stopPropagationOn "mousedown" (D.succeed ( NoOp, True ))
                        , Ev.stopPropagationOn "click" (D.succeed ( CloseSession id, True ))
                        , Attr.title "Close session"
                        ]
                        [ Html.text "✕" ]
                    ]
                , viewChatArea model session
                ]

        Nothing ->
            Html.text ""


viewNoSessionPanel : Model -> Html Msg
viewNoSessionPanel model =
    Html.div [ Attr.class "chat-area chat-area-centered no-sessions" ]
        [ if model.initializing then
            Html.div [ Attr.class "hs-container-inline" ]
                [ Html.div [ Attr.class "hs-logo" ] [ Html.text "AlayaFace" ]
                , Html.div [ Attr.class "hs-tagline" ] [ Html.text "Connecting…" ]
                ]

          else
            Html.text ""
        ]


viewGlobalMenu : Model -> Html Msg
viewGlobalMenu model =
    let
        isOpen =
            model.showGlobalMenu
    in
    Html.div
        [ Attr.class ("global-menu" ++ (if isOpen then " open" else ""))
        , Ev.onMouseLeave CloseGlobalMenu
        ]
        [ Html.div
            [ Attr.class "global-menu-panel" ]
            [ Html.div
                [ Attr.class "global-menu-item"
                , Ev.onClick CreateSession
                ]
                [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "+" ]
                , Html.text " New Session"
                ]
            , Html.div
                [ Attr.class "global-menu-item"
                , Ev.onClick OpenSessionManager
                ]
                [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "☰" ]
                , Html.text " Session Manager"
                ]
            , Html.div
                [ Attr.class "global-menu-item"
                , Ev.onClick OpenPresetManager
                ]
                [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "◱" ]
                , Html.text
                    ("Presets"
                        ++ (if model.activePreset /= "" then
                                " (" ++ model.activePreset ++ ")"
                            else
                                ""
                           )
                    )
                ]
            ]
        , Html.button
            [ Attr.class "global-menu-btn"
            , Ev.onClick ToggleGlobalMenu
            , Attr.title "Menu"
            ]
            [ Html.text "⚙" ]
        ]


viewContextMenu : Model -> Html Msg
viewContextMenu model =
    if model.ctxVisible then
        Html.div
            [ Attr.class "ctx-overlay"
            , Ev.onClick HideCtxMenu
            , Ev.preventDefaultOn "contextmenu" (D.succeed ( HideCtxMenu, True ))
            ]
            [ Html.div
                [ Attr.class "ctx-menu"
                , Attr.style "left" (String.fromInt model.ctxX ++ "px")
                , Attr.style "top" (String.fromInt model.ctxY ++ "px")
                , Ev.stopPropagationOn "click" (D.succeed ( NoOp, True ))
                , Ev.stopPropagationOn "contextmenu" (D.succeed ( NoOp, True ))
                ]
                [ Html.div
                    [ Attr.class "ctx-menu-item"
                    , Ev.onClick ForkFromCtx
                    ]
                    [ Html.span [ Attr.class "ctx-menu-icon" ] [ Html.text "⑂" ]
                    , Html.text "Fork"
                    ]
                ]
            ]

    else
        Html.text ""


viewSessionManagerOverlay : Model -> Html Msg
viewSessionManagerOverlay model =
    if model.showSessionManager then
        let
            dirs =
                List.filterMap decodeSessionDir model.sessionDirs
        in
        viewOverlay CloseSessionManager
            [ Html.div [ Attr.class "sel-page" ]
                [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Session Manager" ]
                , if List.isEmpty dirs then
                    Html.div [ Attr.class "sel-page-status" ] [ Html.text "No saved sessions." ]

                  else
                    Html.div [ Attr.class "sel-page-list" ]
                        (List.map (\dir ->
                            Html.div
                                [ Attr.class "sel-page-item" ]
                                [ Html.span [ Attr.class "sel-page-item-name" ] [ Html.text dir.id ]
                                , Html.button
                                    [ Attr.class "confirm-page-btn confirm-page-btn-allow"
                                    , Ev.onClick (ResumeSession dir.id)
                                    , Attr.style "padding" "4px 10px"
                                    , Attr.style "font-size" "0.75rem"
                                    , Attr.style "min-width" "auto"
                                    ]
                                    [ Html.text "Resume" ]
                                , Html.button
                                    [ Attr.class "confirm-page-btn confirm-page-btn-deny"
                                    , Ev.onClick (DeleteSession dir.id)
                                    , Attr.style "padding" "4px 10px"
                                    , Attr.style "font-size" "0.75rem"
                                    , Attr.style "min-width" "auto"
                                    ]
                                    [ Html.text "Delete" ]
                                ]
                            ) dirs
                        )
                ]
            ]
    else
        Html.text ""


viewChatArea : Model -> T.SessionState -> Html Msg
viewChatArea model session =
    let
        hasMessages =
            not (List.isEmpty session.messages)
    in
    Html.div
        [ Attr.class "chat-area" ]
        [ if hasMessages then
            Html.div [ Attr.class "messages" ]
                (List.map (viewMessage model.cursorMsgId session.id) session.messages

                    ++ [ Html.div [] [] ]
                )

          else
            Html.text ""
        , viewInputBar model session
        , viewConfirmOverlay session.id session
        , viewMcpInitOverlay session.id session
        , viewFilePickerOverlay session.id session
        , viewModelSelectorOverlay session.id session
        , viewHelpWindowOverlay session.id session
        ]


viewMessage : Maybe String -> String -> T.Message -> Html Msg
viewMessage cursorMsgId sessionId msg =
    let
        isCursor =
            case cursorMsgId of
                Just c -> c == msg.id
                Nothing -> False

        cursorClass =
            if isCursor then
                " message-cursor"
            else
                ""

        hasHistoryId =
            msg.historyId /= Nothing

        -- Right-click handler for messages with historyId
        ctxAttrs =
            case msg.historyId of
                Just hid ->
                    [ Ev.preventDefaultOn "contextmenu"
                        (D.map2
                            (\clientX clientY ->
                                ( ShowCtxMenu (round clientX) (round clientY) hid sessionId, True )
                            )
                            (D.field "clientX" D.float)
                            (D.field "clientY" D.float)
                        )
                    ]

                Nothing ->
                    []

        baseClass =
            "message message-" ++ T.roleToString msg.role ++ cursorClass
    in
    case msg.role of
        T.Assistant ->
            Html.div
                ([ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass)
                 ]
                    ++ ctxAttrs
                )
                [ Html.div [ Attr.class "message-content" ]
                    [ Markdown.toHtmlWith markdownOptions
                        [ Attr.class "md" ]
                        msg.content
                    ]
                ]

        T.Reasoning ->
            Html.div [ Attr.class "message-reasoning-wrap" ]
                [ Html.div
                    ([ Attr.class ("message message-reasoning" ++ cursorClass) ]
                        ++ ctxAttrs
                    )
                    [ Html.text msg.content ]
                ]

        T.Tool ->
            Html.div [ Attr.class "message-reasoning-wrap" ]
                [ Html.div
                    ([ Attr.class ("message message-tool" ++ cursorClass) ]
                        ++ ctxAttrs
                    )
                    [ Html.div [ Attr.class "message-content" ]
                        [ Markdown.toHtmlWith markdownOptions
                            [ Attr.class "md" ]
                            msg.content
                        ]
                    ]
                ]

        T.User ->
            Html.div
                ([ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass)
                 ]
                    ++ ctxAttrs
                )
                [ case msg.media of
                    Just items ->
                        Html.div [ Attr.class "hs-staged-row" ]
                            (List.map viewMessageMedia items)

                    Nothing ->
                        Html.text ""
                , Html.div [ Attr.class "message-content" ]
                    [ Html.text msg.content ]
                ]

        T.System ->
            Html.div
                ([ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass) ]
                    ++ ctxAttrs
                )
                [ Html.div [ Attr.class "message-content" ]
                    (List.map (\line -> Html.span [] [ Html.text line ]) (String.lines msg.content))
                ]

        T.Notify ->
            Html.div [ Attr.class ("message message-notify" ++ cursorClass) ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Html.text msg.content ]
                ]

        T.Error ->
            Html.div [ Attr.class ("message message-error" ++ cursorClass) ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Html.text msg.content ]
                ]


viewInputBar : Model -> T.SessionState -> Html Msg
viewInputBar model session =
    let
        hasMessages =
            not (List.isEmpty session.messages)

        hasStaged =
            not (List.isEmpty session.staged)

        inputClass =
            "session-input-bar" ++ (if not hasMessages then " session-input-bar-centered" else "")
    in
    Html.div [ Attr.class inputClass ]
        [ Html.div [ Attr.class "input-container" ]
            [ Html.div [ Attr.class "message message-user input-bubble" ]
                [ if hasStaged then
                    Html.div [ Attr.class "hs-staged-row" ]
                        (List.map (viewStagedChip session.id) session.staged)

                  else
                    Html.text ""
                , Html.textarea
                    [ Attr.id ("msg-input-" ++ session.id)
                    , Attr.class "input-text"
                    , Attr.placeholder "Type a message…"
                    , Attr.value session.input
                    , Ev.onInput (\v -> ForSession session.id (SetInput v))
                    , Ev.preventDefaultOn "keydown" <|
                        D.map3 (\key ctrl shift ->
                            if key == "Enter" && not ctrl && not shift then
                                ( ForSession session.id SendPrompt, True )
                            else if key == "Enter" && shift then
                                ( NoOp, False )
                            else
                                ( NoOp, False )
                        ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "shiftKey" D.bool)
                    , Attr.disabled (not session.connected)
                    , Attr.rows model.inputRows
                    ]
                    []
                ]
            , Html.div [ Attr.class "input-footer" ]
                [ Html.div [ Attr.class "input-footer-left" ]
                    [ Html.button
                        [ Attr.class "footer-btn"
                        , Ev.onClick (ForSession session.id OpenFilePicker)
                        , Attr.title "Attach media"
                        , Attr.disabled (not session.connected)
                        ]
                        [ Html.text "📎" ]
                    , Html.button
                        [ Attr.class "footer-btn"
                        , Ev.onClick (ForSession session.id OpenModelSelector)
                        , Attr.title "Select model"
                        , Attr.disabled (not session.connected)
                        ]
                        [ Html.text "🧠" ]
                    , Html.button
                        [ Attr.class "footer-btn"
                        , Ev.onClick (ForSession session.id OpenHelpWindow)
                        , Attr.title "Help"
                        ]
                        [ Html.text "?" ]
                    ]
                , Html.div [ Attr.class "input-footer-right" ]
                    [ Html.button
                        [ Attr.class ("send-btn" ++ (if session.taskRunning then " cancel" else ""))
                        , Ev.onClick
                            (if session.taskRunning then ForSession session.id CancelTask else ForSession session.id SendPrompt)
                        , Attr.disabled (not session.connected)
                        ]
                        [ if session.taskRunning then Html.text "Cancel" else Html.text "Send" ]
                    ]
                ]
            ]
        ]


-- ─── Staged Media Chips ──────────────────────────────────────────────

viewStagedChip : String -> T.StagedMedia -> Html Msg
viewStagedChip sid item =
    Html.div [ Attr.class "hs-staged-chip" ]
        [ Html.span [ Attr.class "hs-staged-icon" ]
            [ Html.text (mediaTypeIcon item.mediaType) ]
        , Html.span [ Attr.class "hs-staged-name" ]
            [ Html.text (Maybe.withDefault (String.left 40 item.uri) item.name) ]
        , Html.button
            [ Attr.class "hs-staged-remove"
            , Ev.onClick (ForSession sid (RemoveStaged item.id))
            , Attr.title "Remove"
            ]
            [ Html.text "✕" ]
        ]


-- ─── Message Media Previews ─────────────────────────────────────────

viewMessageMedia : T.MediaItem -> Html Msg
viewMessageMedia item =
    Html.div [ Attr.class "hs-staged-chip message-media-chip" ]
        [ Html.span [ Attr.class "hs-staged-icon" ]
            [ Html.text (mediaTypeIcon item.mediaType) ]
        , Html.span [ Attr.class "hs-staged-name" ]
            [ Html.text (Maybe.withDefault (String.left 40 item.uri) item.name) ]
        ]


mediaTypeIcon : T.MediaType -> String
mediaTypeIcon mt =
    case mt of
        T.Image -> "🖼"
        T.Audio -> "🎵"
        T.Video -> "🎬"
        T.Document -> "📄"


resizeHandleString : ResizeHandle -> String
resizeHandleString handle =
    case handle of
        N -> "n"
        S -> "s"
        W -> "w"
        E -> "e"
        NW -> "nw"
        NE -> "ne"
        SW -> "sw"
        SE -> "se"


viewResizeHandle : String -> ResizeHandle -> Html Msg
viewResizeHandle sid handle =
    let
        className =
            "resize-handle resize-handle-" ++ resizeHandleString handle
    in
    Html.div
        [ Attr.class className
        , Ev.preventDefaultOn "mousedown"
            (D.map2
                (\clientX clientY ->
                    ( ResizeStart sid handle clientX clientY, True )
                )
                (D.field "clientX" D.float)
                (D.field "clientY" D.float)
            )
        ]
        []


type alias ResizeResult =
    { x : Int, y : Int, w : Int, h : Int }


type alias ResizeConfig =
    { handle : ResizeHandle
    , dx : Int
    , dy : Int
    , startX : Int
    , startY : Int
    , startW : Int
    , startH : Int
    , minW : Int
    , minH : Int
    }


resizeDimensions : ResizeConfig -> ResizeResult
resizeDimensions config =
    case config.handle of
        E ->
            { x = config.startX, y = config.startY, w = max config.minW (config.startW + config.dx), h = config.startH }

        W ->
            { x = config.startX + config.dx, y = config.startY, w = max config.minW (config.startW - config.dx), h = config.startH }

        S ->
            { x = config.startX, y = config.startY, w = config.startW, h = max config.minH (config.startH + config.dy) }

        N ->
            { x = config.startX, y = config.startY + config.dy, w = config.startW, h = max config.minH (config.startH - config.dy) }

        NE ->
            { x = config.startX, y = config.startY + config.dy, w = max config.minW (config.startW + config.dx), h = max config.minH (config.startH - config.dy) }

        NW ->
            { x = config.startX + config.dx, y = config.startY + config.dy, w = max config.minW (config.startW - config.dx), h = max config.minH (config.startH - config.dy) }

        SE ->
            { x = config.startX, y = config.startY, w = max config.minW (config.startW + config.dx), h = max config.minH (config.startH + config.dy) }

        SW ->
            { x = config.startX + config.dx, y = config.startY, w = max config.minW (config.startW - config.dx), h = max config.minH (config.startH + config.dy) }


-- ─── Overlay ──────────────────────────────────────────────────────────

viewOverlay : Msg -> List (Html Msg) -> Html Msg
viewOverlay onClose children =
    Html.div [ Attr.class "overlay" ]
        [ Html.div [ Attr.class "overlay-page", Ev.stopPropagationOn "click" (D.succeed ( NoOp, True )) ]
            ([ Html.button
                [ Attr.class "overlay-close"
                , Ev.stopPropagationOn "click" (D.succeed ( onClose, True ))
                , Attr.title "Close"
                ]
                [ Html.text "✕" ]
             ]
                ++ children
            )
        ]


-- ─── Confirm Overlay ─────────────────────────────────────────────────

viewConfirmOverlay : String -> T.SessionState -> Html Msg
viewConfirmOverlay sid session =
    case session.pendingConfirm of
        first :: _ ->
            viewOverlay (CloseConfirm sid)
                [ Overlay.ConfirmTool.view
                    { onConfirm = \id allowed -> ConfirmTool sid id allowed
                    }
                    first
                ]

        [] ->
            Html.text ""


-- ─── MCP Init Overlay ────────────────────────────────────────────────

viewMcpInitOverlay : String -> T.SessionState -> Html Msg
viewMcpInitOverlay sid session =
    let
        showOverlay =
            case session.mcpStatus of
                Just "connecting" -> not (List.isEmpty session.mcpServers)
                Just "auth_required" -> True
                Just "auth_running" -> True
                Just "failed" -> True
                _ -> False
    in
    if showOverlay then
        viewOverlay (CloseMcpInit sid)
            [ Overlay.McpInit.view
                { mcpStatus = session.mcpStatus
                , mcpServers = session.mcpServers
                , pendingMcpAuth = session.pendingMcpAuth
                , onClose = CloseMcpAuthOverlay sid
                , onCancelAll = McpCancelAll sid
                , onAuthConfirm = McpAuthConfirm sid
                , onAuthDeny = \s -> McpAuthDeny sid s
                , onFillUrl = \url -> ForSession sid (FillMcpAuthUrl url)
                }
            ]

    else
        Html.text ""


-- ─── File Picker Overlay ──────────────────────────────────────────────

viewFilePickerOverlay : String -> T.SessionState -> Html Msg
viewFilePickerOverlay sid session =
    if session.showFilePicker then
        viewOverlay (ForSession sid CloseFilePicker)
            [ Overlay.FilePicker.view
                { sessionId = sid
                , entries = filterEntries session
                , input = session.filePickerInput
                , filter = session.filePickerFilter
                , selected = session.filePickerSelected
                , mode = session.filePickerMode
                , loading = session.filePickerLoading
                , noOp = NoOp
                , onInput = \v -> ForSession sid (SetFilePickerInput v)
                , onConfirm = ForSession sid FilePickerConfirmItem
                , onPick = \i -> ForSession sid (FilePickerPickItem i)
                , onUrlConfirm = ForSession sid ConfirmFilePickerUrl
                , onToggleMode = ForSession sid FilePickerToggleMode
                }
            ]
    else
        Html.text ""


-- ─── Model Selector Overlay ──────────────────────────────────────────

viewModelSelectorOverlay : String -> T.SessionState -> Html Msg
viewModelSelectorOverlay sid session =
    if session.showModelSelector then
        viewOverlay (ForSession sid CloseModelSelector)
            [ Overlay.Selector.viewPage
                { title = "Model Selector"
                , page = session.modelSelector.page
                , dirty = Sel.isDirty session.modelSelector
                , syncError = session.modelSelector.syncError
                , listView =
                    viewModelSelectorList sid session
                , editorView =
                    case session.modelSelector.draft of
                        Just draft ->
                            Overlay.ModelEditor.view
                                { sessionId = sid
                                , draft = draft
                                , isNew = draft.id == 0
                                , onBack = ForSession sid ModelSelectorEditBack
                                , onSave = ForSession sid ModelSelectorEditSave
                                , onField = \field value -> ForSession sid (ModelSelectorEditField field value)
                                }

                        Nothing ->
                            Html.text ""
                , onSync = ForSession sid ModelSelectorConfirmSync
                , onDiscard = ForSession sid ModelSelectorDiscardClose
                , onCancelSync = ForSession sid ModelSelectorCancelSyncPrompt
                }
            ]
    else
        Html.text ""


viewModelSelectorList : String -> T.SessionState -> Html Msg
viewModelSelectorList sid session =
    let
        st =
            session.modelSelector
    in
    Overlay.Selector.viewList
        { title = "Model Selector"
        , inputId = "model-selector-input-" ++ sid
        , itemIdPrefix = "model-selector-item-" ++ sid
        , placeholder = "Search models…"
        , emptyText = "No models configured."
        , noMatchText = "No models match your search."
        , items = st.working
        , input = st.input
        , selected = st.selected
        , confirmDeleteId = st.confirmDelete
        , canDelete = List.length st.working > 1
        , currentLabel = "Current: "
        , currentValue =
            if session.activeModelName == "" then
                "none"

            else
                session.activeModelName
        , addTitle = "Add model"
        , itemId = \m -> m.id
        , itemTitle = \m -> m.name
        , itemSubtitle = \_ -> ""
        , isActive = \m -> session.activeModelId == Just m.id
        , editTitle = \m ->
            if session.activeModelId == Just m.id then
                "Active model cannot be edited"

            else
                "Edit model"
        , deleteTitle = \m ->
            if session.activeModelId == Just m.id then
                "Active model cannot be deleted"

            else if List.length st.working <= 1 then
                "At least one model must remain"

            else
                "Delete model"
        , onSelect = \i -> ForSession sid (ModelSelectorSelectItem i)
        , onConfirm = ForSession sid ModelSelectorConfirmItem
        , noOp = NoOp
        , onInput = \v -> ForSession sid (SetModelSelectorInput v)
        , onEdit = \id -> ForSession sid (ModelSelectorEditModel id)
        , onDelete = \id -> ForSession sid (ModelSelectorDeleteModel id)
        , onDeleteConfirm = \id -> ForSession sid (ModelSelectorConfirmDelete id)
        , onDeleteCancel = ForSession sid ModelSelectorCancelDelete
        , onAdd = ForSession sid ModelSelectorAddModel
        }


viewDefaultModelsEditorOverlay : Model -> Html Msg
viewDefaultModelsEditorOverlay model =
    let
        ed =
            model.defaultModelsEditor
    in
    if ed.show then
        viewOverlay CloseDefaultModelsEditor
            [ Overlay.Selector.viewPage
                { title = "Model Selector"
                , page = ed.state.page
                , dirty = Sel.isDirty ed.state
                , syncError = ed.state.syncError
                , listView =
                    viewDefaultModelsList ed
                , editorView =
                    case ed.state.draft of
                        Just draft ->
                            Overlay.ModelEditor.view
                                { sessionId = "default"
                                , draft = draft
                                , isNew = draft.id == 0
                                , onBack = DefaultModelsEditBack
                                , onSave = DefaultModelsEditSave
                                , onField = DefaultModelsEditField
                                }

                        Nothing ->
                            Html.text ""
                , onSync = DefaultModelsConfirmSync
                , onDiscard = DefaultModelsDiscardClose
                , onCancelSync = DefaultModelsCancelSyncPrompt
                }
            ]
    else
        Html.text ""


viewDefaultModelsList : DefaultModelsEditor -> Html Msg
viewDefaultModelsList ed =
    Overlay.Selector.viewList
        { title = "Model Selector"
        , inputId = "model-selector-input-default"
        , itemIdPrefix = "model-selector-item-default"
        , placeholder = "Search models…"
        , emptyText = "No models configured."
        , noMatchText = "No models match your search."
        , items = ed.state.working
        , input = ed.state.input
        , selected = ed.state.selected
        , confirmDeleteId = ed.state.confirmDelete
        , canDelete = List.length ed.state.working > 1
        , currentLabel = "Preset: "
        , currentValue = ed.preset
        , addTitle = "Add model"
        , itemId = \m -> m.id
        , itemTitle = \m -> m.name
        , itemSubtitle = \_ -> ""
        , isActive = \_ -> False
        , editTitle = \_ -> "Edit model"
        , deleteTitle = \_ ->
            if List.length ed.state.working <= 1 then
                "At least one model must remain"

            else
                "Delete model"
        , onSelect = DefaultModelsSelectItem
        , onConfirm = DefaultModelsConfirmItem
        , noOp = NoOp
        , onInput = SetDefaultModelsInput
        , onEdit = DefaultModelsEditModel
        , onDelete = DefaultModelsDeleteModel
        , onDeleteConfirm = DefaultModelsConfirmDelete
        , onDeleteCancel = DefaultModelsCancelDelete
        , onAdd = DefaultModelsAddModel
        }


viewMcpEditorOverlay : Model -> Html Msg
viewMcpEditorOverlay model =
    let
        ed =
            model.mcpEditor
    in
    if ed.show then
        viewOverlay CloseMcpEditor
            [ Overlay.Selector.viewPage
                { title = "MCP Servers"
                , page = ed.state.page
                , dirty = Sel.isDirty ed.state
                , syncError = ed.state.syncError
                , listView =
                    viewMcpList ed
                , editorView =
                    case ed.state.draft of
                        Just draft ->
                            Overlay.McpEditor.view
                                { sessionId = "default"
                                , draft = draft
                                , isNew = draft.id == 0
                                , onBack = McpEditBack
                                , onSave = McpEditSave
                                , onField = McpEditField
                                }

                        Nothing ->
                            Html.text ""
                , onSync = McpConfirmSync
                , onDiscard = McpDiscardClose
                , onCancelSync = McpCancelSyncPrompt
                }
            ]
    else
        Html.text ""


viewMcpList : McpEditor -> Html Msg
viewMcpList ed =
    let
        subtitle s =
            (if s.type_ == "stdio" then
                "STDIO"

             else
                "HTTP"
            )
                ++ (if s.url /= "" then
                        " · " ++ s.url

                    else if s.command /= "" then
                        " · " ++ s.command

                    else
                        ""
                   )
    in
    Overlay.Selector.viewList
        { title = "MCP Servers"
        , inputId = "mcp-selector-input-default"
        , itemIdPrefix = "mcp-selector-item-default"
        , placeholder = "Search servers…"
        , emptyText = "No MCP servers configured."
        , noMatchText = "No servers match your search."
        , items = ed.state.working
        , input = ed.state.input
        , selected = ed.state.selected
        , confirmDeleteId = ed.state.confirmDelete
        , canDelete = List.length ed.state.working > 1
        , currentLabel = "Preset: "
        , currentValue = ed.preset
        , addTitle = "Add MCP server"
        , itemId = \s -> s.id
        , itemTitle = \s -> s.server
        , itemSubtitle = subtitle
        , isActive = \_ -> False
        , editTitle = \_ -> "Edit server"
        , deleteTitle = \_ ->
            if List.length ed.state.working <= 1 then
                "At least one server must remain"

            else
                "Delete server"
        , onSelect = McpSelectItem
        , onConfirm = McpConfirmItem
        , noOp = NoOp
        , onInput = SetMcpInput
        , onEdit = McpEditServer
        , onDelete = McpDeleteServer
        , onDeleteConfirm = McpConfirmDelete
        , onDeleteCancel = McpCancelDelete
        , onAdd = McpAddServer
        }


viewSettingsEditorOverlay : Model -> Html Msg
viewSettingsEditorOverlay model =
    let
        ed =
            model.settingsEditor
    in
    if ed.show then
        viewOverlay CloseSettingsEditor
            [ Overlay.Settings.view
                { toolConfirm = ed.toolConfirm
                , loading = ed.loading
                , syncing = ed.syncing
                , error = ed.error
                , onInput = SetToolConfirm
                , onSave = SettingsSave
                , onCancel = CloseSettingsEditor
                }
            ]
    else
        Html.text ""


-- Pick an unused copy name for duplicating a preset: "<source>-copy",
-- then "<source>-copy-2", "-3", … until it's free. Hyphens keep the name
-- valid (letters, digits, '-' and '_' only — no spaces).
nextCopyName : String -> List PresetInfo -> String
nextCopyName source presets =
    let
        taken =
            List.map .name presets |> Set.fromList

        base =
            source ++ "-copy"

        find n =
            let
                cand =
                    base ++ "-" ++ String.fromInt n
            in
            if Set.member cand taken then
                find (n + 1)

            else
                cand
    in
    if Set.member base taken then
        find 2

    else
        base


viewPresetManagerOverlay : Model -> Html Msg
viewPresetManagerOverlay model =
    let
        pm =
            model.presetManager
    in
    if pm.show then
        viewOverlay ClosePresetManager
            [ Overlay.PresetManager.view
                { presets = model.presets
                , loading = pm.loading
                , busy = pm.busy
                , renaming = pm.renaming
                , renameInput = pm.renameInput
                , editing = pm.editing
                , confirmDelete = pm.confirmDelete
                , error = pm.error
                , onCopy = PresetCopy
                , onSetActive = PresetSetActive
                , onRenameStart = PresetRenameStart
                , onRenameInput = SetPresetRenameInput
                , onRenameSave = PresetRenameSave
                , onRenameCancel = PresetRenameCancel
                , onToggleEdit = PresetToggleEdit
                , onEditModels = EditPresetModels
                , onEditMcp = EditPresetMcp
                , onEditSettings = EditPresetSettings
                , onDelete = PresetDelete
                , onDeleteConfirm = PresetConfirmDelete
                , onDeleteCancel = PresetCancelDelete
                }
            ]
    else
        Html.text ""


-- ─── Help Window Overlay ─────────────────────────────────────────────

viewHelpWindowOverlay : String -> T.SessionState -> Html Msg
viewHelpWindowOverlay sid session =
    if session.showHelpWindow then
        viewOverlay (ForSession sid CloseHelpWindow)
            [ Overlay.HelpWindow.view
                { sessionId = sid
                , items = helpItems
                , filter = session.helpFilter
                , selected = session.helpSelected
                , noOp = NoOp
                , onFilter = \v -> ForSession sid (SetHelpFilter v)
                , onCmd = \v -> ForSession sid (HelpCmdMsg v)
                }
            ]
    else
        Html.text ""


-- SVG icons


