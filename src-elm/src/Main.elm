module Main exposing (main)

import Browser
import Browser.Dom as Dom
import Browser.Events as Evts
import Task
import Dict exposing (Dict)
import Set exposing (Set)
import Html exposing (Html, Attribute)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D
import Json.Encode as E
import Time
import Session.Types as T
import Session.Protocol as P
import Session.Handlers as H
import Markdown
import Ports
import Fuzzy


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
    , statusMsg : String
    , notifications : List ( String, String )  -- (id, text)
    , nextNotifId : Int
    , atBottom : Bool
    , prevMsgCount : Int
    , sessionOrder : List String
    , pendingSwitchOnCreate : Bool
    , inputRows : Int
    , displayFocused : Bool
    , cursorMsgId : Maybe String
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
      , statusMsg = ""
      , notifications = []
      , nextNotifId = 0
      , atBottom = True
      , prevMsgCount = 0
      , sessionOrder = []
      , pendingSwitchOnCreate = False
      , inputRows = 1
      , displayFocused = False
      , cursorMsgId = Nothing
      }
    , Ports.createSession { toolConfirm = Just "execute_command" }
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


getActiveSession : Model -> Maybe T.SessionState
getActiveSession model =
    case model.activeId of
        Just sid ->
            Dict.get sid model.sessions

        Nothing ->
            Nothing


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
    | ConfirmTool String Bool
    | McpAuthConfirm
    | McpAuthDeny String
    | McpCancelAll
    | CloseConfirm
    | CloseMcpInit
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
    | FilePickerKeyDown Int
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
    | SelectAllSessions
      -- Window
    | WindowMaximized Bool
    | StartDragging
    | Minimize
    | ToggleMaximize
    | CloseWindow
      -- Model Selector
    | OpenModelSelector
    | CloseModelSelector
    | SetModelSelectorInput String
    | ModelSelectorSelectItem Int
    | ModelSelectorConfirmItem
      -- Help Window
    | OpenHelpWindow
    | CloseHelpWindow
    | SetHelpFilter String
    | HelpSelectItem Int
    | HelpCmdMsg String
      -- Display navigation
    | ToggleFocus
    | FocusDisplay
    | FocusInput
    | MoveCursorUp
    | MoveCursorDown
    | ScrollLines Int
    | ScrollHalfPage Int
    | GotoTop
    | GotoBottom
    | SetCursorMsgId String
    | ToggleMsgFold String
    | NavigateToPrevPrompt
    | NavigateToNextPrompt
      -- Internal
    | NoOp
    | FocusNow
    | KeyDown String Bool Bool
    | ScrollPosition Float Float Float


-- UPDATE

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Session Lifecycle
        CreateSession ->
            ( { model | pendingSwitchOnCreate = True }
            , Ports.createSession { toolConfirm = Just "execute_command" }
            )

        SessionCreated id ->
            let
                newSession =
                    T.emptySession id

                newSessions =
                    Dict.insert id newSession model.sessions

                -- Only auto-switch on initial creation (activeId was Nothing)
                -- If user is already viewing a session, don't steal focus
                newActiveId =
                    if model.pendingSwitchOnCreate || model.activeId == Nothing then
                        Just id
                    else
                        model.activeId

                cmds =
                    if model.pendingSwitchOnCreate || model.activeId == Nothing then
                        Cmd.batch [ Task.attempt (\_ -> NoOp) (Dom.focus "msg-input"), Ports.scrollToBottom {} ]
                    else
                        Cmd.none
            in
            ( { model
                | sessions = newSessions
                , activeId = newActiveId
                , initializing = False
                , atBottom = True
                , sessionOrder = model.sessionOrder ++ [ id ]
                , pendingSwitchOnCreate = False
              }
            , cmds
            )

        CloseSession id ->
            ( { model
                | sessions = Dict.remove id model.sessions
                , sessionOrder = List.filter (\k -> k /= id) model.sessionOrder
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
                                            [ Ports.scrollToBottom {}
                                            , Task.attempt (\_ -> NoOp) (Dom.focus "msg-input")
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
                            ( model, Cmd.none )

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

                                cmds =
                                    if msgCountChanged && model.atBottom then
                                        Cmd.batch
                                            [ Ports.scrollToBottom {}
                                            , Task.attempt (\_ -> NoOp) (Dom.focus "msg-input")
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
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        StatusEvent raw ->
            case D.decodeValue P.statusEventDecoder raw of
                Ok ev ->
                    case Dict.get ev.sessionId model.sessions of
                        Just session ->
                            ( { model
                                | sessions = Dict.insert ev.sessionId
                                    { session
                                        | connected = ev.connected
                                        , statusMsg = ev.message
                                    }
                                    model.sessions
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

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
                    ( { model | statusMsg = "Cancelling…" }
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

        ConfirmTool id allowed ->
            case model.activeId of
                Just sid ->
                    ( updateAfterConfirm model sid
                    , Ports.confirmTool { sessionId = sid, id = id, allowed = allowed }
                    )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthConfirm ->
            case getActiveSession model of
                Just s ->
                    case s.pendingMcpAuth of
                        Just auth ->
                            let
                                newSessions =
                                    Dict.insert s.id { s | pendingMcpAuth = Nothing } model.sessions

                                authUrl =
                                    Maybe.withDefault "" auth.toolInput

                                serverName =
                                    Maybe.withDefault "" auth.toolName
                            in
                            ( { model | sessions = newSessions }
                            , Ports.startMcpAuthFlow
                                { sessionId = s.id
                                , serverName = serverName
                                , authUrl = authUrl
                                }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthDeny server ->
            case model.activeId of
                Just sid ->
                    let
                        s =
                            Dict.get sid model.sessions
                    in
                    case s of
                        Just sess ->
                            ( { model | sessions = Dict.insert sid { sess | pendingMcpAuth = Nothing } model.sessions }
                            , Ports.sendCommand { sessionId = sid, command = ":mcp_auth " ++ server }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        McpCancelAll ->
            case model.activeId of
                Just sid ->
                    let
                        s =
                            Dict.get sid model.sessions
                    in
                    case s of
                        Just sess ->
                            ( { model
                                | sessions = Dict.insert sid
                                    { sess | pendingMcpAuth = Nothing, mcpStatus = Nothing }
                                    model.sessions
                              }
                            , Ports.sendCommand { sessionId = sid, command = ":mcp_cancel" }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        CloseConfirm ->
            case model.activeId of
                Just sid ->
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
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        CloseMcpInit ->
            update McpCancelAll model

        ForkMessage historyId ->
            case model.activeId of
                Just sid ->
                    ( model
                    , Ports.forkSession { sourceSessionId = sid, historyId = historyId }
                    )

                Nothing ->
                    ( model, Cmd.none )

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
                        , Cmd.none
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
            ( { model | activeId = Just id }, Task.attempt (\_ -> NoOp) (Dom.focus "msg-input") )

        -- File Picker
        OpenFilePicker ->
            case getActiveSession model of
                Just _ ->
                    ( updateActiveSession model (\s ->
                        { s
                            | showFilePicker = True
                            , filePickerMode = T.Local
                            , filePickerInput = ""
                            , filePickerSelected = 0
                            , filePickerLoading = True
                        }
                      )
                    , Ports.fsHomeDir {}
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseFilePicker ->
            ( updateActiveSession model (\s -> { s | showFilePicker = False })
            , Cmd.none
            )

        SetFilePickerInput val ->
            case getActiveSession model of
                Just s ->
                    let
                        ( needsResolve, resolvePath, filterText ) =
                            parsePathInput val s.filePickerDir s.filePickerBaseDir

                        cmd =
                            if needsResolve then
                                Ports.fsResolvePath { path = resolvePath }
                            else
                                Cmd.none

                        -- Clamp selection to filtered list length
                        previewSession =
                            { s | filePickerInput = val, filePickerFilter = filterText }

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
                            | filePickerInput = val
                            , filePickerFilter = filterText
                            , filePickerSelected = clampedIdx
                        }
                      )
                    , cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerNavigateDir name ->
            case getActiveSession model of
                Just s ->
                    let
                        newPath =
                            if s.filePickerDir == "" then
                                name
                            else
                                s.filePickerDir ++ "/" ++ name

                        newInput =
                            if String.startsWith "/" s.filePickerInput || String.startsWith "~" s.filePickerInput then
                                -- Keep the path prefix + directory name
                                s.filePickerInput ++ "/" ++ name
                            else
                                -- Relative navigation from list
                                name ++ "/"
                    in
                    ( updateActiveSession model (\sess ->
                        { sess
                            | filePickerLoading = True
                            , filePickerInput = newInput
                            , filePickerFilter = ""
                        }
                      )
                    , Ports.fsResolvePath { path = newPath }
                    )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerSelectItem idx ->
            ( updateActiveSession model (\s -> { s | filePickerSelected = idx })
            , Cmd.none
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
                                update (FilePickerNavigateDir entry.name) model

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
                                    }
                                  )
                                , Ports.fsReadFileDataUri { path = fullPath }
                                )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerToggleMode ->
            ( updateActiveSession model (\s ->
                { s
                    | filePickerMode =
                        case s.filePickerMode of
                            T.Local -> T.Url
                            T.Url -> T.Local
                    , filePickerInput = ""
                }
              )
            , Cmd.none
            )

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
                                , filePickerInput = ".."
                                , filePickerFilter = ""
                            }
                          )
                        , Ports.fsResolvePath { path = parentDir }
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerKeyDown _ ->
            ( model, Cmd.none )

        FsListDirResult entries ->
            let
                parsed =
                    List.filterMap decodeDirEntry entries
            in
            ( updateActiveSession model (\s ->
                { s
                    | filePickerEntries = parsed
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
                    , filePickerLoading = True
                }
              )
            , Ports.fsListDir { path = home }
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
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        FsResolvePathResult result ->
            case D.decodeValue resolvePathResultDecoder result of
                Ok rp ->
                    if rp.exists && rp.isDir then
                        ( updateActiveSession model (\s ->
                            { s
                                | filePickerDir = rp.resolved
                                , filePickerSelected = 0
                                , filePickerLoading = True
                            }
                          )
                        , Ports.fsListDir { path = rp.resolved }
                        )

                    else
                        ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        -- Session Manager
        OpenSessionManager ->
            ( { model | showSessionManager = True }, Ports.listSessionDirs {} )

        CloseSessionManager ->
            ( { model | showSessionManager = False }, Cmd.none )

        SessionDirsResult dirs ->
            ( { model | sessionDirs = dirs }, Cmd.none )

        ResumeSession id ->
            ( model, Ports.resumeSession { sessionId = id } )

        DeleteSession id ->
            ( model, Ports.deleteSessionDir { sessionId = id } )

        SelectAllSessions ->
            ( model, Cmd.none )

        -- Window
        WindowMaximized v ->
            ( { model | isMaximized = v }, Cmd.none )

        StartDragging ->
            ( model, Ports.startDragging {} )

        Minimize ->
            ( model, Ports.minimizeWindow {} )

        ToggleMaximize ->
            ( model, Ports.toggleMaximize {} )

        CloseWindow ->
            ( model, Ports.closeWindow {} )

        -- Model Selector
        OpenModelSelector ->
            ( updateActiveSession model (\s ->
                { s
                    | showModelSelector = True
                    , modelSelectorInput = ""
                    , modelSelectorSelected = 0
                    , modelSelectorScroll = 0
                }
              )
            , Cmd.none
            )

        CloseModelSelector ->
            ( updateActiveSession model (\s -> { s | showModelSelector = False })
            , Cmd.none
            )

        SetModelSelectorInput val ->
            ( updateActiveSession model (\s ->
                let
                    filtered =
                        filterModels s.models val

                    -- Clamp selected index if filter reduces list
                    clampedSelected =
                        if List.length filtered <= s.modelSelectorSelected then
                            max 0 (List.length filtered - 1)
                        else
                            s.modelSelectorSelected
                in
                { s
                    | modelSelectorInput = val
                    , modelSelectorSelected = clampedSelected
                }
              )
            , Cmd.none
            )

        ModelSelectorSelectItem idx ->
            ( updateActiveSession model (\s -> { s | modelSelectorSelected = idx })
            , Cmd.none
            )

        ModelSelectorConfirmItem ->
            case getActiveSession model of
                Just s ->
                    let
                        filtered =
                            filterModels s.models s.modelSelectorInput

                        selectedModel =
                            List.head (List.drop s.modelSelectorSelected filtered)
                    in
                    case selectedModel of
                        Just m ->
                            ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelectorInput = "" })
                            , Ports.setModel { sessionId = s.id, modelId = m.id }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        -- Help Window
        OpenHelpWindow ->
            ( updateActiveSession model (\s ->
                { s
                    | showHelpWindow = True
                    , helpFilter = ""
                    , helpSelected = 0
                    , helpScroll = 0
                }
              )
            , Cmd.none
            )

        CloseHelpWindow ->
            ( updateActiveSession model (\s -> { s | showHelpWindow = False })
            , Cmd.none
            )

        SetHelpFilter val ->
            ( updateActiveSession model (\s -> { s | helpFilter = val })
            , Cmd.none
            )

        HelpSelectItem idx ->
            ( updateActiveSession model (\s -> { s | helpSelected = idx })
            , Cmd.none
            )

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
                    , Task.attempt (\_ -> NoOp) (Dom.focus "msg-input")
                    )

                Nothing ->
                    ( model, Cmd.none )

        -- Display Navigation
        ToggleFocus ->
            if model.displayFocused then
                ( { model | displayFocused = False }
                , Task.attempt (\_ -> NoOp) (Dom.focus "msg-input")
                )
            else
                ( { model | displayFocused = True }
                , Ports.blurInput {}
                )

        FocusDisplay ->
            ( { model | displayFocused = True }
            , Ports.blurInput {}
            )

        FocusInput ->
            ( { model | displayFocused = False }
            , Task.attempt (\_ -> NoOp) (Dom.focus "msg-input")
            )

        MoveCursorUp ->
            case getActiveSession model of
                Just s ->
                    let
                        msgIds =
                            List.map .id s.messages

                        newCursor =
                            case model.cursorMsgId of
                                Just cur ->
                                    case listElemIndex cur msgIds of
                                        Just idx ->
                                            if idx > 0 then
                                                Just (Maybe.withDefault cur (List.head (List.drop (idx - 1) msgIds)))
                                            else
                                                Just cur

                                        Nothing ->
                                            List.head (List.reverse msgIds)

                                Nothing ->
                                    List.head (List.reverse msgIds)
                    in
                    ( { model | cursorMsgId = newCursor }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        MoveCursorDown ->
            case getActiveSession model of
                Just s ->
                    let
                        msgIds =
                            List.map .id s.messages

                        newCursor =
                            case model.cursorMsgId of
                                Just cur ->
                                    case listElemIndex cur msgIds of
                                        Just idx ->
                                            if idx < List.length msgIds - 1 then
                                                Just (Maybe.withDefault cur (List.head (List.drop (idx + 1) msgIds)))
                                            else
                                                Just cur

                                        Nothing ->
                                            List.head msgIds

                                Nothing ->
                                    List.head msgIds
                    in
                    ( { model | cursorMsgId = newCursor }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        ScrollLines n ->
            ( model, Ports.scrollBy { dx = 0, dy = toFloat (n * 28) } )

        ScrollHalfPage n ->
            ( model
            , Ports.scrollBy { dx = 0, dy = toFloat (n * 200) }
            )

        GotoTop ->
            ( model, Ports.scrollToY { y = 0 } )

        GotoBottom ->
            ( model, Ports.scrollToY { y = 999999 } )

        SetCursorMsgId id ->
            ( { model | cursorMsgId = Just id }, Cmd.none )

        ToggleMsgFold id ->
            case model.activeId of
                Just sid ->
                    let
                        s =
                            Dict.get sid model.sessions
                    in
                    case s of
                        Just sess ->
                            let
                                newCollapsed =
                                    if Set.member id sess.collapsedMsgIds then
                                        Set.remove id sess.collapsedMsgIds
                                    else
                                        Set.insert id sess.collapsedMsgIds
                            in
                            ( { model | sessions = Dict.insert sid { sess | collapsedMsgIds = newCollapsed } model.sessions }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        NavigateToPrevPrompt ->
            case getActiveSession model of
                Just s ->
                    let
                        userMsgIds =
                            List.filterMap
                                (\m ->
                                    if m.role == T.User then
                                        Just m.id
                                    else
                                        Nothing
                                )
                                s.messages

                        newCursor =
                            case model.cursorMsgId of
                                Just cur ->
                                    case listElemIndex cur userMsgIds of
                                        Just idx ->
                                            if idx > 0 then
                                                Just (Maybe.withDefault cur (List.head (List.drop (idx - 1) userMsgIds)))
                                            else
                                                Just cur

                                        Nothing ->
                                            List.head (List.reverse userMsgIds)

                                Nothing ->
                                    List.head (List.reverse userMsgIds)
                    in
                    ( { model | cursorMsgId = newCursor }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        NavigateToNextPrompt ->
            case getActiveSession model of
                Just s ->
                    let
                        userMsgIds =
                            List.filterMap
                                (\m ->
                                    if m.role == T.User then
                                        Just m.id
                                    else
                                        Nothing
                                )
                                s.messages

                        newCursor =
                            case model.cursorMsgId of
                                Just cur ->
                                    case listElemIndex cur userMsgIds of
                                        Just idx ->
                                            if idx < List.length userMsgIds - 1 then
                                                Just (Maybe.withDefault cur (List.head (List.drop (idx + 1) userMsgIds)))
                                            else
                                                Just cur

                                        Nothing ->
                                            List.head userMsgIds

                                Nothing ->
                                    List.head userMsgIds
                    in
                    ( { model | cursorMsgId = newCursor }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        FocusNow ->
            ( model, Task.attempt (\_ -> NoOp) (Dom.focus "msg-input") )

        ScrollPosition scrollTop scrollHeight clientHeight ->
            let
                atBottom =
                    scrollTop + clientHeight >= scrollHeight - 5
            in
            ( { model | atBottom = atBottom }, Cmd.none )

        KeyDown key ctrl alt ->
            -- Escape closes any open overlay
            if key == "Escape" then
                case getActiveSession model of
                    Just s ->
                        if s.showModelSelector then
                            update CloseModelSelector model
                        else if s.showHelpWindow then
                            update CloseHelpWindow model
                        else if s.showFilePicker then
                            update CloseFilePicker model
                        else
                            ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

            -- Tab toggles focus between display and input
            else if key == "Tab" then
                update ToggleFocus model

            -- Ctrl+G cancels task
            else if key == "g" && ctrl then
                update CancelTask model

            -- Ctrl+L opens model selector
            else if key == "l" && ctrl && not alt then
                update OpenModelSelector model

            -- Ctrl+H opens help
            else if key == "h" && ctrl && not alt then
                update OpenHelpWindow model

            -- Ctrl+A opens file picker
            else if key == "a" && ctrl && not alt && not model.showSessionManager then
                case getActiveSession model of
                    Just s ->
                        if not s.showFilePicker then
                            update OpenFilePicker model
                        else
                            ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

            -- Display navigation keys (only when display is focused)
            else if model.displayFocused then
                case key of
                    "j" -> update MoveCursorDown model
                    "k" -> update MoveCursorUp model
                    "ArrowDown" -> update MoveCursorDown model
                    "ArrowUp" -> update MoveCursorUp model
                    "J" -> update (ScrollLines 1) model  -- Shift+J = scroll down
                    "K" -> update (ScrollLines -1) model  -- Shift+K = scroll up
                    "g" -> update GotoTop model
                    "G" -> update GotoBottom model
                    "H" -> update GotoTop model           -- H = cursor top
                    "L" -> update GotoBottom model         -- L = cursor bottom
                    "M" -> ( model, Cmd.none )             -- M = cursor mid
                    " " ->                                -- Space = toggle fold
                        case model.cursorMsgId of
                            Just cur ->
                                update (ToggleMsgFold cur) model
                            Nothing ->
                                ( model, Cmd.none )
                    "f" -> update NavigateToNextPrompt model
                    "b" -> update NavigateToPrevPrompt model
                    _ ->
                        -- Ctrl+D and Ctrl+U for half-page scroll
                        if ctrl && key == "d" then
                            update (ScrollHalfPage 1) model
                        else if ctrl && key == "u" then
                            update (ScrollHalfPage -1) model
                        else
                            ( model, Cmd.none )

            -- Regular input (not display focused)
            else
                ( model, Cmd.none )

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


decodeDirEntry : E.Value -> Maybe T.DirEntry
decodeDirEntry val =
    case D.decodeValue (D.map2 T.DirEntry (D.field "name" D.string) (D.field "isDir" D.bool)) val of
        Ok entry -> Just entry
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


isUrl : String -> Bool
isUrl s =
    String.startsWith "http://" s || String.startsWith "https://" s


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

-- ─── List Helpers ───────────────────────────────────────────────────

listElemIndex : a -> List a -> Maybe Int
listElemIndex target items =
    listElemIndexHelp target items 0


listElemIndexHelp : a -> List a -> Int -> Maybe Int
listElemIndexHelp target items idx =
    case items of
        first :: rest ->
            if first == target then
                Just idx
            else
                listElemIndexHelp target rest (idx + 1)

        [] ->
            Nothing


shortenPath : String -> String
shortenPath path =
    if path == "" then
        ""

    else
        let
            home =
                Maybe.withDefault "~" (Maybe.map (\_ -> "~") (String.indexes "/home/" path |> List.head))

            parts =
                String.split "/" path

            numParts =
                List.length parts
        in
        if numParts <= 4 then
            path

        else
            let
                first =
                    Maybe.withDefault "" (List.head parts)

                lastFew =
                    List.drop (numParts - 3) parts |> String.join "/"
            in
            first ++ "/…/" ++ lastFew


-- ─── Model Selector Helpers ──────────────────────────────────────────

filterModels : List T.ModelInfo -> String -> List T.ModelInfo
filterModels models term =
    let
        trimmed =
            String.trim term
    in
    if String.isEmpty trimmed then
        models

    else
        List.filter (\m -> Fuzzy.fuzzyMatch (String.toLower trimmed) (String.toLower m.name)) models


-- ─── Help Items ──────────────────────────────────────────────────────

type alias HelpItem =
    { id : Int
    , key : String
    , desc : String
    , isSection : Bool
    , isCommand : Bool
    }


helpItems : List HelpItem
helpItems =
    [ { id = 1, key = "Commands", desc = "", isSection = True, isCommand = False }
    , { id = 2, key = ":confirm <id> <yes|no>", desc = "Confirm or deny pending tool", isSection = False, isCommand = True }
    , { id = 3, key = ":mcp_auth <server> <code> <redirect_uri>", desc = "Confirm OAuth authorization", isSection = False, isCommand = True }
    , { id = 4, key = ":mcp_auth <server>", desc = "Decline OAuth authorization", isSection = False, isCommand = True }
    , { id = 5, key = ":mcp_cancel", desc = "Cancel MCP initialization", isSection = False, isCommand = True }
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
    , { id = 20, key = "Global Shortcuts", desc = "", isSection = True, isCommand = False }
    , { id = 21, key = "Tab", desc = "Toggle focus display/input", isSection = False, isCommand = False }
    , { id = 22, key = "Enter", desc = "Submit prompt or command", isSection = False, isCommand = False }
    , { id = 23, key = "Ctrl+H", desc = "Open help window", isSection = False, isCommand = False }
    , { id = 24, key = "Ctrl+G", desc = "Cancel current task", isSection = False, isCommand = False }
    , { id = 25, key = "Ctrl+C", desc = "Clear text", isSection = False, isCommand = False }
    , { id = 26, key = "Ctrl+S", desc = "Save session", isSection = False, isCommand = False }
    , { id = 27, key = "Ctrl+A", desc = "Open attachment picker", isSection = False, isCommand = False }
    , { id = 28, key = "Ctrl+L", desc = "Open model selector", isSection = False, isCommand = False }
    , { id = 29, key = "Ctrl+R", desc = "Force redraw screen", isSection = False, isCommand = False }
    , { id = 30, key = "Ctrl+P", desc = "Open theme selector", isSection = False, isCommand = False }
    , { id = 31, key = "Ctrl+Z", desc = "Suspend process", isSection = False, isCommand = False }
    , { id = 32, key = "Display Mode", desc = "", isSection = True, isCommand = False }
    , { id = 33, key = "j/k", desc = "Move window cursor", isSection = False, isCommand = False }
    , { id = 34, key = "J/K", desc = "Scroll one line", isSection = False, isCommand = False }
    , { id = 35, key = "Ctrl+D/U", desc = "Scroll half screen", isSection = False, isCommand = False }
    , { id = 36, key = "g", desc = "Go to first window", isSection = False, isCommand = False }
    , { id = 37, key = "G", desc = "Follow the last window", isSection = False, isCommand = False }
    , { id = 38, key = "H/L/M", desc = "Cursor top/btm/mid", isSection = False, isCommand = False }
    , { id = 39, key = "e", desc = "Open in editor", isSection = False, isCommand = False }
    , { id = 40, key = "f/b", desc = "Next/prev prompt", isSection = False, isCommand = False }
    , { id = 41, key = ":", desc = "Enter command mode", isSection = False, isCommand = False }
    , { id = 42, key = "Space", desc = "Toggle window fold", isSection = False, isCommand = False }
    , { id = 43, key = "Ctrl+F", desc = "Fork session from cursor", isSection = False, isCommand = False }
    ]


filterHelpItems : String -> List HelpItem -> List HelpItem
filterHelpItems term items =
    let
        trimmed =
            String.trim term
    in
    if String.isEmpty trimmed then
        items

    else
        let
            lower =
                String.toLower trimmed
        in
        List.filter
            (\item ->
                if item.isSection then
                    True
                else
                    Fuzzy.fuzzyMatch lower (String.toLower (item.key ++ " " ++ item.desc))
            )
            items


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
        , Ports.onSessionCreated (\id -> SessionCreated id)
        , Ports.onSessionDirs (\dirs -> SessionDirsResult dirs)
        , Ports.onFsListDir (\entries -> FsListDirResult entries)
        , Ports.onFsHomeDir (\home -> FsHomeDirResult home)
        , Ports.onFsReadFileDataUri (\uri -> FsReadFileResult uri)
        , Ports.onFsResolvePath (\result -> FsResolvePathResult result)
        , Ports.onWindowMaximized (\v -> WindowMaximized v)
        , Evts.onKeyDown <|
            D.map3 KeyDown
                (D.field "key" D.string)
                (D.field "ctrlKey" D.bool)
                (D.field "altKey" D.bool)
        ]


-- VIEW

view : Model -> Html Msg
view model =
    case getActiveSession model of
        Just session ->
            viewMain model session

        Nothing ->
            viewNoSession model


viewNoSession : Model -> Html Msg
viewNoSession model =
    Html.div [ Attr.class "app" ]
        [ Html.div [ Attr.class "hs-bg-layer" ]
            [ Html.div [ Attr.class "hs-bg-orb hs-bg-orb-1" ] []
            , Html.div [ Attr.class "hs-bg-orb hs-bg-orb-2" ] []
            , Html.div [ Attr.class "hs-bg-orb hs-bg-orb-3" ] []
            ]
        , Html.header [ Attr.class "app-header", Attr.attribute "data-tauri-drag-region" "" ]
            [ Html.div [ Attr.class "header-top" ]
                [ Html.button [ Attr.class "connect-btn", Ev.onClick CreateSession ] [ Html.text "+ New Session" ]
                , viewWindowControls model
                ]
            ]
        , Html.div [ Attr.class "chat-area chat-area-centered" ]
            [ if model.initializing then
                Html.div [ Attr.class "hs-container-inline" ]
                    [ Html.div [ Attr.class "hs-logo" ] [ Html.text "AlayaFace" ]
                    , Html.div [ Attr.class "hs-tagline" ] [ Html.text "Connecting…" ]
                    ]

              else
                Html.div [ Attr.class "hs-container-inline" ]
                    [ Html.div [ Attr.class "hs-tagline", Attr.style "color" "#ef4444" ]
                        [ Html.text (Maybe.withDefault "Failed to start" model.initError) ]
                    , Html.button [ Attr.class "connect-btn", Attr.style "margin-top" "12px", Ev.onClick CreateSession ]
                        [ Html.text "Retry" ]
                    ]
            ]
        ]


viewMain : Model -> T.SessionState -> Html Msg
viewMain model session =
    Html.div [ Attr.class "app" ]
        [ Html.div [ Attr.class "hs-bg-layer" ]
            [ Html.div [ Attr.class "hs-bg-orb hs-bg-orb-1" ] []
            , Html.div [ Attr.class "hs-bg-orb hs-bg-orb-2" ] []
            , Html.div [ Attr.class "hs-bg-orb hs-bg-orb-3" ] []
            ]
        , viewNotifications model
        , viewHeader model session
        , viewChatArea model session
        , viewConfirmOverlay session
        , viewMcpInitOverlay session
        , viewFilePickerOverlay model
        , viewModelSelectorOverlay model
        , viewHelpWindowOverlay model
        ]


viewWindowControls : Model -> Html Msg
viewWindowControls model =
    Html.div [ Attr.class "window-controls" ]
        [ Html.button [ Attr.class "win-btn", Ev.onClick Minimize, Attr.title "Minimize" ]
            [ svgMinimize ]
        , Html.button [ Attr.class "win-btn", Ev.onClick ToggleMaximize, Attr.title (if model.isMaximized then "Restore" else "Maximize") ]
            [ if model.isMaximized then svgRestore else svgMaximize ]
        , Html.button [ Attr.class "win-btn win-close", Ev.onClick CloseWindow, Attr.title "Close" ]
            [ svgClose ]
        ]


viewHeader : Model -> T.SessionState -> Html Msg
viewHeader model session =
    let
        sessionKeys =
            model.sessionOrder
    in
    Html.header [ Attr.class "app-header", Attr.attribute "data-tauri-drag-region" "" ]
        [ Html.div [ Attr.class "header-top" ] []
        , if List.isEmpty sessionKeys then
            Html.div []
                [ Html.button [ Attr.class "connect-btn", Ev.onClick CreateSession ] [ Html.text "+ New Session" ] ]

          else
            Html.div [ Attr.class "tab-bar", Attr.attribute "data-tauri-drag-region" "" ]
                (List.indexedMap (\i id -> viewTab i id model) sessionKeys
                    ++ [ Html.button [ Attr.class "tab-new", Ev.onClick CreateSession, Attr.title "New session" ] [ Html.text "+" ]
                       , Html.button [ Attr.class "tab-btn", Ev.onClick OpenSessionManager, Attr.title "Session manager" ] [ Html.text "☰" ]
                       , viewWindowControls model
                       ]
                )
        ]


viewTab : Int -> String -> Model -> Html Msg
viewTab i id model =
    let
        session =
            Dict.get id model.sessions

        isActive =
            model.activeId == Just id

        isConnected =
            Maybe.map .connected session |> Maybe.withDefault False
    in
    Html.div
        [ Attr.class ("tab"
            ++ (if isActive then " tab-active" else "")
            ++ (if not isConnected then " tab-disconnected" else "")
            )
        , Ev.onClick (SwitchSession id)
        ]
        [ Html.span [ Attr.class "tab-dot" ] []
        , Html.span [ Attr.class "tab-label" ] [ Html.text ("Session " ++ String.fromInt (i + 1)) ]
        , Html.button
            [ Attr.class "tab-close"
            , Ev.onClick (CloseSession id)
            , Ev.stopPropagationOn "click" (D.succeed ( NoOp, True ))
            , Attr.title "Close session"
            ]
            [ Html.text "✕" ]
        ]


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
                (List.map (viewMessage model.displayFocused model.cursorMsgId) session.messages

                    ++ [ Html.div [] [] ]
                )

          else
            Html.text ""
        , viewInputBar model session
        ]


viewMessage : Bool -> Maybe String -> T.Message -> Html Msg
viewMessage displayFocused cursorMsgId msg =
    let
        isCursor =
            case cursorMsgId of
                Just c -> c == msg.id
                Nothing -> False

        cursorClass =
            if displayFocused && isCursor then
                " message-cursor"
            else
                ""
    in
    case msg.role of
        T.Assistant ->
            Html.div
                [ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass)
                , Ev.onClick (SetCursorMsgId msg.id)
                ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Markdown.toHtmlWith
                        { githubFlavored = Just { tables = True, breaks = True }
                        , defaultHighlighting = Nothing
                        , sanitize = False
                        , smartypants = False
                        }
                        [ Attr.class "md" ]
                        msg.content
                    ]
                ]

        T.Reasoning ->
            Html.div [ Attr.class "message-reasoning-wrap" ]
                [ Html.div [ Attr.class ("message message-reasoning" ++ cursorClass) ]
                    [ Html.text msg.content ]
                ]

        T.Tool ->
            Html.div [ Attr.class "message-reasoning-wrap" ]
                [ Html.div [ Attr.class ("message message-tool" ++ cursorClass) ]
                    [ Html.text msg.content ]
                ]

        T.User ->
            Html.div
                [ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass)
                , Ev.onClick (SetCursorMsgId msg.id)
                ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Html.text msg.content ]
                ]

        T.System ->
            Html.div
                [ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass) ]
                [ Html.div [ Attr.class "message-content" ]
                    (List.map (\line -> Html.span [] [ Html.text line ]) (String.lines msg.content))
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
            [ if hasStaged then
                Html.div [ Attr.class "hs-staged-row" ]
                    (List.map viewStagedChip session.staged)

              else
                Html.text ""
            , Html.div [ Attr.class "message message-user input-bubble" ]
                [ Html.textarea
                    [ Attr.id "msg-input"
                    , Attr.class "input-text"
                    , Attr.placeholder "Type a message…"
                    , Attr.value session.input
                    , Ev.onInput SetInput
                    , Ev.preventDefaultOn "keydown" <|
                        D.map3 (\key ctrl shift ->
                            if key == "Enter" && not ctrl && not shift then
                                ( SendPrompt, True )
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
                        [ Attr.class "attach-btn-small"
                        , Ev.onClick OpenFilePicker
                        , Attr.title "Attach media (Ctrl+A)"
                        , Attr.disabled (not session.connected)
                        ]
                        [ Html.text "📎" ]
                    , Html.span [ Attr.class "input-hint" ]
                        [ Html.text
                            (if model.displayFocused then
                                "Tab ← input  ·  j/k ↑↓  ·  g/G top/btm  ·  Space fold"
                             else
                                "Ctrl+L Model  ·  Ctrl+H Help  ·  ↵ Send"
                            )
                        ] ]
                , Html.div [ Attr.class "input-footer-right" ]
                    [ Html.button
                        [ Attr.class ("send-btn" ++ (if session.taskRunning then " cancel" else ""))
                        , Ev.onClick
                            (if session.taskRunning then CancelTask else SendPrompt)
                        , Attr.disabled (not session.connected)
                        ]
                        [ if session.taskRunning then Html.text "Cancel" else Html.text "Send" ]
                    ]
                ]
            ]
        ]


-- ─── Staged Media Chips ──────────────────────────────────────────────

viewStagedChip : T.StagedMedia -> Html Msg
viewStagedChip item =
    Html.div [ Attr.class "hs-staged-chip" ]
        [ Html.span [ Attr.class "hs-staged-icon" ]
            [ Html.text (mediaTypeIcon item.mediaType) ]
        , Html.span [ Attr.class "hs-staged-name" ]
            [ Html.text (Maybe.withDefault (String.left 40 item.uri) item.name) ]
        , Html.button
            [ Attr.class "hs-staged-remove"
            , Ev.onClick (RemoveStaged item.id)
            , Attr.title "Remove"
            ]
            [ Html.text "✕" ]
        ]


mediaTypeIcon : T.MediaType -> String
mediaTypeIcon mt =
    case mt of
        T.Image -> "🖼"
        T.Audio -> "🎵"
        T.Video -> "🎬"
        T.Document -> "📄"


-- ─── Overlay ──────────────────────────────────────────────────────────

viewOverlay : Msg -> List (Html Msg) -> Html Msg
viewOverlay onBackdropClick children =
    Html.div [ Attr.class "overlay", Ev.onClick onBackdropClick ]
        [ Html.div [ Attr.class "overlay-page", Ev.stopPropagationOn "click" (D.succeed ( NoOp, True )) ]
            children
        ]


-- ─── Confirm Overlay ─────────────────────────────────────────────────

viewConfirmOverlay : T.SessionState -> Html Msg
viewConfirmOverlay session =
    let
        -- Check tool confirm first (higher priority)
        toolPending =
            case session.pendingConfirm of
                first :: _ ->
                    Just first

                [] ->
                    Nothing

        -- Then check MCP auth
        authPending =
            session.pendingMcpAuth
    in
    case ( toolPending, authPending ) of
        ( Just p, _ ) ->
            viewOverlay CloseConfirm [ viewConfirmToolPage p ]

        ( _, Just auth ) ->
            viewOverlay CloseConfirm [ viewConfirmMcpAuthPage auth ]

        ( _, _ ) ->
            Html.text ""


viewConfirmToolPage : T.PendingConfirm -> Html Msg
viewConfirmToolPage p =
    Html.div [ Attr.class "confirm-page" ]
        [ Html.div [ Attr.class "confirm-page-title" ]
            [ Html.text ("Allow \"" ++ Maybe.withDefault "Tool" p.toolName ++ "\" to run?") ]
        , case p.toolInput of
            Just input ->
                Html.div [ Attr.class "confirm-page-input" ]
                    [ Html.text input ]

            Nothing ->
                Html.text ""
        , Html.div [ Attr.class "confirm-page-buttons" ]
            [ Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-allow"
                , Ev.onClick (ConfirmTool p.id True)
                ]
                [ Html.text "✓ Allow" ]
            , Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-deny"
                , Ev.onClick (ConfirmTool p.id False)
                ]
                [ Html.text "✕ Deny" ]
            ]
        ]


viewConfirmMcpAuthPage : T.PendingConfirm -> Html Msg
viewConfirmMcpAuthPage auth =
    Html.div [ Attr.class "confirm-page" ]
        [ Html.div [ Attr.class "confirm-page-title" ]
            [ Html.text ("Authorize MCP server \"" ++ Maybe.withDefault "?" auth.toolName ++ "\"?") ]
        , case auth.toolInput of
            Just url ->
                Html.div [ Attr.class "confirm-page-input" ]
                    [ Html.text url ]

            Nothing ->
                Html.text ""
        , Html.div [ Attr.class "confirm-page-buttons" ]
            [ Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-cancel-all"
                , Ev.onClick McpCancelAll
                ]
                [ Html.text "✕ Cancel All" ]
            , Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-allow"
                , Ev.onClick McpAuthConfirm
                ]
                [ Html.text "✓ Authorize" ]
            , Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-deny"
                , Ev.onClick (McpAuthDeny (Maybe.withDefault "" auth.toolName))
                ]
                [ Html.text "✕ Deny" ]
            ]
        ]


-- ─── MCP Init Overlay ────────────────────────────────────────────────

viewMcpInitOverlay : T.SessionState -> Html Msg
viewMcpInitOverlay session =
    case session.mcpStatus of
        Just "connecting" ->
            if List.isEmpty session.mcpServers then
                Html.text ""
            else
                viewOverlay CloseMcpInit [ viewMcpInitPage session ]

        Just "auth_running" ->
            viewOverlay CloseMcpInit [ viewMcpInitPage session ]

        Just "failed" ->
            viewOverlay CloseMcpInit [ viewMcpInitPage session ]

        _ ->
            Html.text ""


viewMcpInitPage : T.SessionState -> Html Msg
viewMcpInitPage session =
    let
        statusText =
            case session.mcpStatus of
                Just "connecting" ->
                    if List.isEmpty session.mcpServers then
                        "Initializing MCP servers…"
                    else
                        "Connecting to MCP servers:"

                Just "auth_running" ->
                    "Waiting for OAuth authorization…"

                Just "failed" ->
                    "MCP initialization failed."

                _ ->
                    "Initializing MCP servers…"
    in
    Html.div [ Attr.class "mcp-init-page" ]
        [ Html.div [ Attr.class "confirm-page-title" ]
            [ Html.text "Initializing MCP Servers" ]
        , Html.div [ Attr.class "mcp-init-status" ]
            [ Html.text statusText ]
        , if not (List.isEmpty session.mcpServers) then
            Html.div [ Attr.class "mcp-init-list" ]
                (List.map (\s -> Html.div [ Attr.class "mcp-init-server" ]
                    [ Html.span [ Attr.class "mcp-init-dot" ] [ Html.text "⟳" ]
                    , Html.span [ Attr.class "mcp-init-name" ] [ Html.text s ]
                    ]
                ) session.mcpServers)

          else
            Html.text ""
        , Html.div [ Attr.class "mcp-init-hint" ]
            [ Html.text "Press Ctrl+G to cancel MCP initialization." ]
        ]


-- ─── File Picker Overlay ──────────────────────────────────────────────

viewFilePickerOverlay : Model -> Html Msg
viewFilePickerOverlay model =
    case getActiveSession model of
        Just s ->
            if s.showFilePicker then
                viewOverlay CloseFilePicker [ viewFilePickerPage s ]
            else
                Html.text ""

        Nothing ->
            Html.text ""


viewFilePickerPage : T.SessionState -> Html Msg
viewFilePickerPage s =
    let
        entries =
            filterEntries s

        inputIsUrl =
            isUrl (String.trim s.filePickerInput)

        isUrlMode =
            s.filePickerMode == T.Url

        placeholder =
            if isUrlMode then
                "Paste a URL…"
            else
                "Type a file name or path…"

        modeLabel =
            if isUrlMode then "URL" else "Local"

        filteredLen =
            List.length entries
    in
    Html.div [ Attr.class "fp-page" ]
        [ Html.div [ Attr.class "fp-page-input-row" ]
            [ Html.input
                [ Attr.class "fp-page-input"
                , Attr.type_ "text"
                , Attr.value s.filePickerInput
                , Ev.onInput SetFilePickerInput
                , Attr.placeholder placeholder
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        -- Ctrl+A toggles mode
                        if key == "a" && ctrl && not alt then
                            ( FilePickerToggleMode, True )
                        -- Enter confirms (URL mode or local file)
                        else if key == "Enter" && not ctrl then
                            if isUrlMode then
                                ( ConfirmFilePickerUrl, True )
                            else
                                ( FilePickerConfirmItem, True )
                        -- j/k navigate list
                        else if (key == "j" || key == "ArrowDown") && not ctrl && not alt && not shift && not isUrlMode then
                            let
                                newIdx =
                                    min (s.filePickerSelected + 1) (max 0 (filteredLen - 1))
                            in
                            ( FilePickerSelectItem newIdx, True )
                        else if (key == "k" || key == "ArrowUp") && not ctrl && not alt && not shift && not isUrlMode then
                            let
                                newIdx =
                                    max 0 (s.filePickerSelected - 1)
                            in
                            ( FilePickerSelectItem newIdx, True )
                        -- Escape: close picker, or go up a directory
                        else if key == "Escape" then
                            if not isUrlMode && s.filePickerDir /= "" then
                                ( FilePickerNavigateUp, True )
                            else
                                ( CloseFilePicker, True )
                        else
                            ( NoOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                []
            , Html.div [ Attr.class "fp-page-mode" ]
                [ Html.text modeLabel ]
            ]
        , Html.div [ Attr.class "fp-page-dir" ]
            [ if isUrlMode then
                Html.text "Paste a URL and press Enter to attach"
              else
                Html.text (shortenPath s.filePickerDir)
            ]
        , if s.filePickerLoading then
            Html.div [ Attr.class "fp-page-status" ] [ Html.text "Loading…" ]

          else if isUrlMode then
            Html.div [ Attr.class "fp-page-status" ] [ Html.text "Press Enter to attach URL" ]

          else if List.isEmpty entries then
            Html.div [ Attr.class "fp-page-status" ] [ Html.text "No files found" ]

          else
            Html.div [ Attr.class "fp-page-list" ]
                (List.indexedMap (\i e -> viewFilePickerPageEntry i e s) entries)
        ]


viewFilePickerPageEntry : Int -> T.DirEntry -> T.SessionState -> Html Msg
viewFilePickerPageEntry idx entry s =
    Html.div
        [ Attr.class ("fp-page-item" ++ (if idx == s.filePickerSelected then " fp-page-item-selected" else ""))
        , Ev.onClick
            (if entry.isDir then
                FilePickerNavigateDir entry.name

             else
                FilePickerConfirmItem
            )
        , Ev.onMouseEnter (FilePickerSelectItem idx)
        ]
        [ Html.span [ Attr.class "fp-page-item-icon" ] [ Html.text (if entry.isDir then "📁" else "📄") ]
        , Html.span [ Attr.class "fp-page-item-name" ] [ Html.text entry.name ]
        ]


-- ─── Model Selector Overlay ──────────────────────────────────────────

viewModelSelectorOverlay : Model -> Html Msg
viewModelSelectorOverlay model =
    case getActiveSession model of
        Just s ->
            if s.showModelSelector then
                viewOverlay CloseModelSelector [ viewModelSelectorPage s ]
            else
                Html.text ""

        Nothing ->
            Html.text ""


viewModelSelectorPage : T.SessionState -> Html Msg
viewModelSelectorPage s =
    let
        filtered =
            filterModels s.models s.modelSelectorInput
    in
    Html.div [ Attr.class "sel-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Model Selector" ]
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.type_ "text"
                , Attr.value s.modelSelectorInput
                , Ev.onInput SetModelSelectorInput
                , Attr.placeholder "Search models…"
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        let
                            filteredLen =
                                List.length filtered
                        in
                        if key == "Enter" && not ctrl then
                            ( ModelSelectorConfirmItem, True )
                        else if key == "ArrowDown" || (key == "j" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    min (s.modelSelectorSelected + 1) (max 0 (filteredLen - 1))
                            in
                            ( ModelSelectorSelectItem newIdx, True )
                        else if key == "ArrowUp" || (key == "k" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    max 0 (s.modelSelectorSelected - 1)
                            in
                            ( ModelSelectorSelectItem newIdx, True )
                        else if key == "Escape" then
                            ( CloseModelSelector, True )
                        else
                            ( NoOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                []
            ]
        , if s.activeModelName /= "" then
            Html.div [ Attr.class "sel-page-current" ]
                [ Html.span [ Attr.class "sel-page-current-label" ] [ Html.text "Current: " ]
                , Html.span [ Attr.class "sel-page-current-name" ] [ Html.text s.activeModelName ]
                ]

          else
            Html.text ""
        , if List.isEmpty s.models then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No models configured." ]

          else if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No models match your search." ]

          else
            Html.div [ Attr.class "sel-page-list" ]
                (List.indexedMap (\i m -> viewModelSelectorItem i m s) filtered)
        ]


viewModelSelectorItem : Int -> T.ModelInfo -> T.SessionState -> Html Msg
viewModelSelectorItem idx model s =
    let
        isSelected =
            idx == s.modelSelectorSelected

        isActive =
            s.activeModelId == Just model.id
    in
    Html.div
        [ Attr.class ("sel-page-item"
            ++ (if isSelected then " sel-page-item-selected" else "")
            ++ (if isActive then " sel-page-item-active" else "")
          )
        , Ev.onClick (ModelSelectorSelectItem idx)
        , Ev.onDoubleClick ModelSelectorConfirmItem
        , Ev.onMouseEnter (ModelSelectorSelectItem idx)
        ]
        [ Html.span [ Attr.class "sel-page-item-id" ] [ Html.text (String.fromInt model.id) ]
        , Html.span [ Attr.class "sel-page-item-name" ] [ Html.text model.name ]
        , Html.span [ Attr.class "sel-page-item-check" ]
            [ if isActive then Html.text "●" else Html.text "" ]
        ]


-- ─── Help Window Overlay ─────────────────────────────────────────────

viewHelpWindowOverlay : Model -> Html Msg
viewHelpWindowOverlay model =
    case getActiveSession model of
        Just s ->
            if s.showHelpWindow then
                viewOverlay CloseHelpWindow [ viewHelpWindowPage s ]
            else
                Html.text ""

        Nothing ->
            Html.text ""


viewHelpWindowPage : T.SessionState -> Html Msg
viewHelpWindowPage s =
    let
        allItems =
            helpItems

        filtered =
            filterHelpItems s.helpFilter allItems

        filteredLen =
            List.length filtered
    in
    Html.div [ Attr.class "help-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Help" ]
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.type_ "text"
                , Attr.value s.helpFilter
                , Ev.onInput SetHelpFilter
                , Attr.placeholder "Filter command or key…"
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        if key == "Enter" && not ctrl then
                            let
                                selectedItem =
                                    List.head (List.drop s.helpSelected filtered)
                            in
                            case selectedItem of
                                Just item ->
                                    if item.isCommand then
                                        ( HelpCmdMsg item.key, True )
                                    else
                                        ( NoOp, False )

                                Nothing ->
                                    ( NoOp, False )
                        else if key == "ArrowDown" || (key == "j" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    min (s.helpSelected + 1) (max 0 (filteredLen - 1))
                            in
                            ( HelpSelectItem newIdx, True )
                        else if key == "ArrowUp" || (key == "k" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    max 0 (s.helpSelected - 1)
                            in
                            ( HelpSelectItem newIdx, True )
                        else if key == "Escape" then
                            ( CloseHelpWindow, True )
                        else
                            ( NoOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                []
            ]
        , if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No matching commands or keys." ]

          else
            Html.div [ Attr.class "sel-page-list" ]
                (List.indexedMap (\i item -> viewHelpItem i item s.helpSelected) filtered)
        ]


viewHelpItem : Int -> HelpItem -> Int -> Html Msg
viewHelpItem idx item selectedIdx =
    let
        isSelected =
            idx == selectedIdx
    in
    if item.isSection then
        Html.div [ Attr.class "help-page-section" ]
            [ Html.text ("── " ++ item.key) ]

    else
        Html.div
            [ Attr.class ("help-page-item"
                ++ (if isSelected then " help-page-item-selected" else "")
              )
            , Ev.onMouseEnter (HelpSelectItem idx)
            , Ev.onClick
                (if item.isCommand then
                    HelpCmdMsg item.key
                 else
                    NoOp
                )
            ]
            [ Html.span [ Attr.class "help-page-item-key" ] [ Html.text item.key ]
            , Html.span [ Attr.class "help-page-item-desc" ] [ Html.text item.desc ]
            ]


viewNotifications : Model -> Html Msg
viewNotifications model =
    Html.div [ Attr.class "notifications-container" ]
        (List.map
            (\( id, text ) ->
                Html.div [ Attr.class "notification notification-notify", Attr.attribute "key" id ]
                    [ Html.span [ Attr.class "notification-text" ] [ Html.text text ] ]
            )
            model.notifications
        )


-- SVG icons

svgMinimize : Html Msg
svgMinimize =
    Html.text "🗕"


svgMaximize : Html Msg
svgMaximize =
    Html.text "🗖"


svgRestore : Html Msg
svgRestore =
    Html.text "🗗"


svgClose : Html Msg
svgClose =
    Html.text "✕"


svgArrow : Html Msg
svgArrow =
    Html.text "↑"


svgStop : Html Msg
svgStop =
    Html.text "■"
