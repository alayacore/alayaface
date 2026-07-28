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
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Time
import Session.Types as T
import Session.Protocol as P
import Session.Handlers as H
import Overlay.ConfirmTool
import Overlay.McpInit
import Overlay.FilePicker
import Overlay.ModelSelector
import Overlay.HelpWindow exposing (HelpItem, filterHelpItems, view)
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
    , cursorMsgId : Maybe String
    , contentWidth : Int
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
      , cursorMsgId = Nothing
      , contentWidth = 864
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


isOverlayOpen : Model -> Bool
isOverlayOpen model =
    case getActiveSession model of
        Just s ->
            s.showModelSelector || s.showHelpWindow || s.showFilePicker || not (List.isEmpty s.pendingConfirm) || s.mcpStatus /= Nothing

        Nothing ->
            False




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
    | FillMcpAuthUrl String
      -- Session wrapper
    | ForSession String Msg
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

                                mcpJustCompleted =
                                    session.mcpStatus /= Nothing && newSession.mcpStatus == Nothing

                                cmds =
                                    Cmd.batch
                                        (List.filterMap identity
                                            [ if msgCountChanged && model.atBottom then
                                                Just (Ports.scrollToBottom {})

                                              else
                                                Nothing
                                            , if msgCountChanged && model.atBottom || mcpJustCompleted then
                                                Just (Task.attempt (\_ -> NoOp) (Dom.focus "msg-input"))

                                              else
                                                Nothing
                                            ]
                                        )
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
                        [ Ports.sendCommand { sessionId = sid, command = ":mcp_decline " ++ server }
                        , Ports.focusElement "msg-input"
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
                        [ Ports.sendCommand { sessionId = sid, command = ":mcp_cancel" }
                        , Ports.focusElement "msg-input"
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
                        [ Ports.sendCommand { sessionId = sid, command = ":mcp_cancel" }
                        , Ports.focusElement "msg-input"
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
                    , Ports.focusElement "msg-input"
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
                        , Ports.focusElement "msg-input"
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
                            , filePickerFilter = ""
                            , filePickerSelected = 0
                            , filePickerLoading = True
                        }
                      )
                    , Cmd.batch
                        [ Ports.fsHomeDir {}
                        , Ports.focusElement "fp-page-input"
                        ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        CloseFilePicker ->
            ( updateActiveSession model (\s -> { s | showFilePicker = False, filePickerSavedLocalPath = "", filePickerSavedUrlPath = "" })
            , Ports.focusElement "msg-input"
            )

        FocusElement id ->
            ( model, Ports.focusElement id )

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
                                    Ports.scrollIntoView ("fp-item-" ++ e.name)

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
                    , Ports.focusElement "fp-page-input"
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

        FilePickerKeyDown _ ->
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
                    , Ports.focusElement "msg-input"
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
            ( { model | showSessionManager = True }, Ports.listSessionDirs {} )

        CloseSessionManager ->
            ( { model | showSessionManager = False }
            , Ports.focusElement "msg-input"
            )

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
            , Ports.focusElement "model-selector-input"
            )

        CloseModelSelector ->
            ( updateActiveSession model (\s -> { s | showModelSelector = False })
            , Ports.focusElement "msg-input"
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
            let
                scrollCmd =
                    case getActiveSession model of
                        Just s ->
                            let
                                filtered =
                                    filterModels s.models s.modelSelectorInput
                            in
                            case List.head (List.drop idx filtered) of
                                Just m ->
                                    Ports.scrollIntoView ("model-selector-item-" ++ String.fromInt m.id)

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none
            in
            ( updateActiveSession model (\s -> { s | modelSelectorSelected = idx })
            , scrollCmd
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
                            , Cmd.batch
                                [ Ports.setModel { sessionId = s.id, modelId = m.id }
                                , Ports.focusElement "msg-input"
                                ]
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
            , Ports.focusElement "help-filter-input"
            )

        CloseHelpWindow ->
            ( updateActiveSession model (\s -> { s | showHelpWindow = False })
            , Ports.focusElement "msg-input"
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
            ( updateActiveSession model (\s -> { s | helpSelected = idx })
            , Ports.scrollIntoView ("help-item-" ++ String.fromInt idx)
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

            -- Escape or Ctrl+[ closes any open overlay
            else if key == "Escape" || (key == "[" && ctrl) then
                case getActiveSession model of
                    Just s ->
                        if s.showModelSelector then
                            ( { model | activeId = Just s.id }, Cmd.none )
                        else if s.showHelpWindow then
                            ( { model | activeId = Just s.id }, Cmd.none )
                        else if s.showFilePicker then
                            ( { model | activeId = Just s.id }, Cmd.none )
                        else
                            ( model, Cmd.none )

                    Nothing ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        ForSession sid innerMsg ->
            update innerMsg { model | activeId = Just sid }

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
        , Ports.onSessionCreated (\id -> SessionCreated id)
        , Ports.onSessionDirs (\dirs -> SessionDirsResult dirs)
        , Ports.onFsListDir (\entries -> FsListDirResult entries)
        , Ports.onFsHomeDir (\home -> FsHomeDirResult home)
        , Ports.onFsReadFileDataUri (\uri -> FsReadFileResult uri)
        , Ports.onFsResolvePath (\result -> FsResolvePathResult result)
        , Ports.onWindowMaximized (\v -> WindowMaximized v)
        , Evts.onKeyDown <|
            D.map4 KeyDown
                (D.field "key" D.string)
                (D.field "ctrlKey" D.bool)
                (D.field "altKey" D.bool)
                (D.field "defaultPrevented" D.bool)
        ]


-- VIEW

view : Model -> Html Msg
view model =
    Html.div [ Attr.class "app" ]
        [ Html.node "style"
            []
            [ Html.text (".app{--content-width:" ++ String.fromInt model.contentWidth ++ "px}") ]
        , viewNotifications model
        , viewSidebar model
        , Html.div [ Attr.class "main-content" ]
            (if List.isEmpty model.sessionOrder then
                [ viewNoSessionPanel model ]

             else
                List.map (\id -> viewSessionPanel model id) model.sessionOrder
            )
        ]


viewSessionPanel : Model -> String -> Html Msg
viewSessionPanel model id =
    case Dict.get id model.sessions of
        Just session ->
            Html.div
                [ Attr.class ("session-panel" ++ (if model.activeId == Just id then " session-panel-active" else ""))
                , Ev.onClick (SwitchSession id)
                ]
                [ viewChatArea model session ]

        Nothing ->
            Html.text ""


viewNoSessionPanel : Model -> Html Msg
viewNoSessionPanel model =
    Html.div [ Attr.class "chat-area chat-area-centered" ]
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


viewMain : Model -> T.SessionState -> Html Msg
viewMain model session =
    Html.div [ Attr.class "app" ]
        [ Html.node "style"
            []
            [ Html.text (".app{--content-width:" ++ String.fromInt model.contentWidth ++ "px}") ]
        , viewNotifications model
        , viewSidebar model
        , Html.div [ Attr.class "main-content" ]
            [ viewChatArea model session ]
        ]


viewSidebar : Model -> Html Msg
viewSidebar model =
    let
        sessionKeys =
            model.sessionOrder
    in
    Html.nav [ Attr.class "sidebar" ]
        [ Html.div [ Attr.class "sidebar-tabs" ]
            (List.indexedMap (\i id -> viewTab i id model) sessionKeys
                ++ [ Html.button [ Attr.class "sidebar-btn", Ev.onClick CreateSession, Attr.title "New session" ] [ Html.text "+" ]
                   , Html.button [ Attr.class "sidebar-btn", Ev.onClick OpenSessionManager, Attr.title "Session manager" ] [ Html.text "☰" ]
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
        [ Attr.class ("sidebar-tab"
            ++ (if isActive then " sidebar-tab-active" else "")
            ++ (if not isConnected then " sidebar-tab-disconnected" else "")
            )
        , Ev.onClick (SwitchSession id)
        ]
        [ Html.span [ Attr.class "sidebar-tab-dot" ] []
        , Html.span [ Attr.class "sidebar-tab-label" ] [ Html.text (String.fromInt (i + 1)) ]
        , Html.button
            [ Attr.class "sidebar-tab-close"
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
                (List.map (viewMessage model.cursorMsgId) session.messages

                    ++ [ Html.div [] [] ]
                )

          else
            Html.text ""
        , viewInputBar model session
        , viewConfirmOverlay session.id session
        , viewMcpInitOverlay session.id session
        , viewFilePickerOverlay session.id model
        , viewModelSelectorOverlay session.id model
        , viewHelpWindowOverlay session.id model
        ]


viewMessage : Maybe String -> T.Message -> Html Msg
viewMessage cursorMsgId msg =
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
    in
    case msg.role of
        T.Assistant ->
            Html.div
                [ Attr.class ("message message-" ++ T.roleToString msg.role ++ cursorClass)
                , Ev.onClick NoOp
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
                , Ev.onClick NoOp
                ]
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
            [ Html.div [ Attr.class "message message-user input-bubble" ]
                [ if hasStaged then
                    Html.div [ Attr.class "hs-staged-row" ]
                        (List.map (viewStagedChip session.id) session.staged)

                  else
                    Html.text ""
                , Html.textarea
                    [ Attr.id "msg-input"
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


-- ─── Overlay ──────────────────────────────────────────────────────────

viewOverlay : Msg -> List (Html Msg) -> Html Msg
viewOverlay onBackdropClick children =
    Html.div [ Attr.class "overlay", Ev.onClick onBackdropClick ]
        [ Html.div [ Attr.class "overlay-page", Ev.stopPropagationOn "click" (D.succeed ( NoOp, True )) ]
            children
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

viewFilePickerOverlay : String -> Model -> Html Msg
viewFilePickerOverlay sid model =
    case getActiveSession model of
        Just s ->
            if s.showFilePicker then
                viewOverlay (ForSession sid CloseFilePicker)
                    [ Overlay.FilePicker.view
                        { entries = filterEntries s
                        , input = s.filePickerInput
                        , filter = s.filePickerFilter
                        , selected = s.filePickerSelected
                        , mode = s.filePickerMode
                        , loading = s.filePickerLoading
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

        Nothing ->
            Html.text ""


-- ─── Model Selector Overlay ──────────────────────────────────────────

viewModelSelectorOverlay : String -> Model -> Html Msg
viewModelSelectorOverlay sid model =
    case getActiveSession model of
        Just s ->
            if s.showModelSelector then
                viewOverlay (ForSession sid CloseModelSelector)
                    [ Overlay.ModelSelector.view
                        { models = s.models
                        , input = s.modelSelectorInput
                        , selected = s.modelSelectorSelected
                        , activeModelId = s.activeModelId
                        , activeModelName = s.activeModelName
                        , noOp = NoOp
                        , onSelect = \i -> ForSession sid (ModelSelectorSelectItem i)
                        , onConfirm = ForSession sid ModelSelectorConfirmItem
                        , onClose = ForSession sid CloseModelSelector
                        , onInput = \v -> ForSession sid (SetModelSelectorInput v)
                        }
                    ]
            else
                Html.text ""

        Nothing ->
            Html.text ""


-- ─── Help Window Overlay ─────────────────────────────────────────────

viewHelpWindowOverlay : String -> Model -> Html Msg
viewHelpWindowOverlay sid model =
    case getActiveSession model of
        Just s ->
            if s.showHelpWindow then
                viewOverlay (ForSession sid CloseHelpWindow)
                    [ Overlay.HelpWindow.view
                        { items = helpItems
                        , filter = s.helpFilter
                        , selected = s.helpSelected
                        , noOp = NoOp
                        , onFilter = \v -> ForSession sid (SetHelpFilter v)
                        , onCmd = \v -> ForSession sid (HelpCmdMsg v)
                        }
                    ]
            else
                Html.text ""

        Nothing ->
            Html.text ""


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


