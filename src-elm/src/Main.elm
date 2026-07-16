module Main exposing (main)

import Browser
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
    , showFilePicker : Bool
    , filePickerType : T.MediaType
    , filePickerMode : FileMode
    , filePickerInput : String
    , filePickerEntries : List DirEntry
    , filePickerDir : String
    , filePickerBaseDir : String
    , filePickerSelected : Int
    , filePickerLoading : Bool
    , filePickerError : Maybe String
    , showSessionManager : Bool
    , sessionDirs : List E.Value
    , isMaximized : Bool
    , statusMsg : String
    , notifications : List ( String, String )  -- (id, text)
    , nextNotifId : Int
    , atBottom : Bool
    , prevMsgCount : Int
    , sessionOrder : List String
    }


type FileMode
    = Local
    | Url


type alias DirEntry =
    { name : String
    , isDir : Bool
    }


init : Flags -> ( Model, Cmd Msg )
init _ =
    ( { sessions = Dict.empty
      , activeId = Nothing
      , initializing = True
      , initError = Nothing
      , showFilePicker = False
      , filePickerType = T.Image
      , filePickerMode = Local
      , filePickerInput = ""
      , filePickerEntries = []
      , filePickerDir = ""
      , filePickerBaseDir = ""
      , filePickerSelected = 0
      , filePickerLoading = False
      , filePickerError = Nothing
      , showSessionManager = False
      , sessionDirs = []
      , isMaximized = False
      , statusMsg = ""
      , notifications = []
      , nextNotifId = 0
      , atBottom = True
      , prevMsgCount = 0
      , sessionOrder = []
      }
    , Ports.createSession { toolConfirm = Just "execute_command" }
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
    | ConfirmTool String Bool
    | McpAuthConfirm
    | McpAuthDeny String
    | McpCancelAll
    | CloseConfirm
    | ForkMessage String
    | SetInput String
    | SwitchSession String
      -- File picker
    | OpenFilePicker T.MediaType
    | CloseFilePicker
    | SetFilePickerInput String
    | FilePickerNavigateDir String
    | FilePickerSelectItem Int
    | FilePickerConfirmItem
    | FilePickerToggleMode
    | FilePickerKeyDown Int
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
      -- Internal
    | NoOp
    | FocusNow
    | ScrollPosition Float Float Float


-- UPDATE

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Session Lifecycle
        CreateSession ->
            ( model, Ports.createSession { toolConfirm = Just "execute_command" } )

        SessionCreated id ->
            let
                newSession =
                    T.emptySession id

                newSessions =
                    Dict.insert id newSession model.sessions

                -- Only auto-switch on initial creation (activeId was Nothing)
                -- If user is already viewing a session, don't steal focus
                newActiveId =
                    case model.activeId of
                        Nothing ->
                            Just id

                        Just _ ->
                            model.activeId

                cmds =
                    case model.activeId of
                        Nothing ->
                            Cmd.batch [ Ports.focusInput {}, Ports.scrollToBottom {} ]

                        Just _ ->
                            Cmd.none
            in
            ( { model
                | sessions = newSessions
                , activeId = newActiveId
                , initializing = False
                , atBottom = True
                , sessionOrder = model.sessionOrder ++ [ id ]
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
                                            , Ports.focusInput {}
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
                                            , Ports.focusInput {}
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
            case activeSession model of
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
                            | sessions = Dict.insert s.id
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
            case activeSession model of
                Just s ->
                    case s.pendingMcpAuth of
                        Just auth ->
                            let
                                newSessions =
                                    Dict.insert s.id { s | pendingMcpAuth = Nothing } model.sessions
                            in
                            ( { model | sessions = newSessions }
                            , case auth.toolInput of
                                Just url ->
                                    Ports.openUrl { url = url }

                                Nothing ->
                                    Cmd.none
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
                    let
                        s =
                            Dict.get sid model.sessions
                    in
                    case s of
                        Just sess ->
                            ( { model
                                | sessions = Dict.insert sid
                                    { sess
                                        | pendingConfirm = []
                                        , pendingMcpAuth = Nothing
                                    }
                                    model.sessions
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ForkMessage historyId ->
            case model.activeId of
                Just sid ->
                    ( model
                    , Ports.forkSession { sourceSessionId = sid, historyId = historyId }
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
                            ( { model | sessions = Dict.insert sid { sess | input = val } model.sessions }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        SwitchSession id ->
            ( { model | activeId = Just id }, Cmd.none )

        -- File Picker
        OpenFilePicker mt ->
            ( { model
                | showFilePicker = True
                , filePickerType = mt
                , filePickerMode = Local
                , filePickerInput = ""
                , filePickerSelected = 0
                , filePickerLoading = True
              }
            , Ports.fsHomeDir {}
            )

        CloseFilePicker ->
            ( { model | showFilePicker = False }, Cmd.none )

        SetFilePickerInput val ->
            let
                newModel =
                    { model | filePickerInput = val }
            in
            if String.startsWith "/" val || String.startsWith "~" val || String.contains "/" val || val == ".." then
                ( newModel
                , Ports.fsResolvePath { path = val }
                )

            else
                ( newModel, Cmd.none )

        FilePickerNavigateDir name ->
            let
                newPath =
                    if model.filePickerDir == "" then
                        name
                    else
                        model.filePickerDir ++ "/" ++ name
            in
            ( { model | filePickerLoading = True }
            , Ports.fsResolvePath { path = newPath }
            )

        FilePickerSelectItem idx ->
            ( { model | filePickerSelected = idx }, Cmd.none )

        FilePickerConfirmItem ->
            let
                entries =
                    filterEntries model
            in
            case List.head (List.drop model.filePickerSelected entries) of
                Just entry ->
                    if entry.isDir then
                        update (FilePickerNavigateDir entry.name) model

                    else
                        let
                            fullPath =
                                if model.filePickerDir == "" then
                                    entry.name
                                else
                                    model.filePickerDir ++ "/" ++ entry.name
                        in
                        ( { model | filePickerLoading = True }
                        , Ports.fsReadFileDataUri { path = fullPath }
                        )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerToggleMode ->
            ( { model
                | filePickerMode =
                    case model.filePickerMode of
                        Local -> Url
                        Url -> Local
                , filePickerInput = ""
              }
            , Cmd.none
            )

        FilePickerKeyDown _ ->
            ( model, Cmd.none )

        FsListDirResult entries ->
            let
                parsed =
                    List.filterMap decodeDirEntry entries
            in
            ( { model
                | filePickerEntries = parsed
                , filePickerLoading = False
                , filePickerError = Nothing
              }
            , Cmd.none
            )

        FsHomeDirResult home ->
            ( { model | filePickerBaseDir = home, filePickerDir = home, filePickerLoading = True }
            , Ports.fsListDir { path = home }
            )

        FsReadFileResult _ ->
            -- File read as data URI, add to staged
            ( { model | showFilePicker = False }, Cmd.none )

        FsResolvePathResult _ ->
            -- Simplified for now
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

        FocusNow ->
            ( model, Ports.focusInput {} )

        ScrollPosition scrollTop scrollHeight clientHeight ->
            let
                atBottom =
                    scrollTop + clientHeight >= scrollHeight - 5
            in
            ( { model | atBottom = atBottom }, Cmd.none )

        NoOp ->
            ( model, Cmd.none )


-- Helpers

activeSession : Model -> Maybe T.SessionState
activeSession model =
    case model.activeId of
        Just id ->
            Dict.get id model.sessions

        Nothing ->
            Nothing


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


decodeDirEntry : E.Value -> Maybe DirEntry
decodeDirEntry val =
    case D.decodeValue (D.map2 DirEntry (D.field "name" D.string) (D.field "isDir" D.bool)) val of
        Ok entry -> Just entry
        Err _ -> Nothing


filterEntries : Model -> List DirEntry
filterEntries model =
    let
        term =
            String.trim (String.toLower model.filePickerInput)
    in
    if String.isEmpty term then
        model.filePickerEntries

    else
        List.filter (\e -> Fuzzy.fuzzyMatch term (String.toLower e.name)) model.filePickerEntries


-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions _ =
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
        ]


-- VIEW

view : Model -> Html Msg
view model =
    case activeSession model of
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
        , viewConfirmDialog session
        , viewFilePicker model
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
                (List.map viewMessage session.messages
                    ++ (if session.sendPending then
                            [ Html.div [ Attr.class "message message-assistant cursor-blink" ] [ Html.text "▊" ] ]

                        else
                            []
                       )
                    ++ [ Html.div [] [] ]
                )

          else
            Html.text ""
        , viewInputBar model session
        ]


viewMessage : T.Message -> Html Msg
viewMessage msg =
    case msg.role of
        T.Reasoning ->
            Html.div [ Attr.class "message-reasoning-wrap" ]
                [ Html.div [ Attr.class "message message-reasoning" ]
                    [ Html.text msg.content ]
                ]

        T.Tool ->
            Html.div [ Attr.class "message-reasoning-wrap" ]
                [ Html.div [ Attr.class "message message-tool" ]
                    [ Html.text msg.content ]
                ]

        _ ->
            Html.div
                [ Attr.class ("message message-" ++ T.roleToString msg.role) ]
                [ Html.div [ Attr.class "message-content" ]
                    (List.map (\line -> Html.span [] [ Html.text line ]) (String.lines msg.content))
                ]


viewInputBar : Model -> T.SessionState -> Html Msg
viewInputBar model session =
    let
        hasMessages =
            not (List.isEmpty session.messages)

        inputClass =
            "session-input-bar" ++ (if not hasMessages then " session-input-bar-centered" else "")
    in
    Html.div [ Attr.class inputClass ]
        [ Html.div [ Attr.class "hs-search-wrapper" ]
            [ Html.div [ Attr.class "hs-search-form" ]
                [ Html.textarea
                    [ Attr.id "msg-input"
                    , Attr.class "hs-search-input"
                    , Attr.placeholder "Type a message…"
                    , Attr.value session.input
                    , Ev.onInput SetInput
                    , Ev.preventDefaultOn "keydown" <|
                        D.map3 (\key ctrl shift ->
                            if key == "Enter" && not ctrl && not shift then
                                ( SendPrompt, True )
                            else
                                ( NoOp, False )
                        ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "shiftKey" D.bool)
                    , Attr.disabled (not session.connected)
                    , Attr.rows 1
                    ]
                    []
                , Html.div [ Attr.class "hs-search-controls" ]
                    [ Html.div [ Attr.class "hs-controls-right" ]
                        [ Html.button
                            [ Attr.class "hs-send-btn"
                            , Ev.onClick
                                (if session.taskRunning then CancelTask else SendPrompt)
                            , Attr.disabled (not session.connected)
                            ]
                            [ if session.taskRunning then svgStop else svgArrow ]
                        ]
                    ]
                ]
            ]
        ]


viewConfirmDialog : T.SessionState -> Html Msg
viewConfirmDialog session =
    let
        pending =
            case session.pendingConfirm of
                first :: _ ->
                    Just first

                [] ->
                    session.pendingMcpAuth
    in
    case pending of
        Just p ->
            Html.div [ Attr.class "modal-overlay confirm-overlay", Ev.onClick CloseConfirm ]
                [ Html.div [ Attr.class "confirm-dialog" ]
                    [ Html.div [ Attr.class "confirm-title" ]
                        [ Html.text ("Allow \"" ++ Maybe.withDefault "Tool" p.toolName ++ "\" to run?") ]
                    , case p.toolInput of
                        Just input ->
                            Html.div [ Attr.class "confirm-input" ]
                                [ Html.pre [] [ Html.text input ] ]

                        Nothing ->
                            Html.text ""
                    , Html.div [ Attr.class "confirm-buttons" ]
                        [ Html.button
                            [ Attr.class "confirm-btn confirm-btn-allow"
                            , Ev.onClick (ConfirmTool p.id True)
                            ]
                            [ Html.text "✓ Allow" ]
                        , Html.button
                            [ Attr.class "confirm-btn confirm-btn-deny"
                            , Ev.onClick (ConfirmTool p.id False)
                            ]
                            [ Html.text "✕ Deny" ]
                        ]
                    ]
                ]

        Nothing ->
            Html.text ""


viewFilePicker : Model -> Html Msg
viewFilePicker model =
    if not model.showFilePicker then
        Html.text ""

    else
        let
            entries =
                filterEntries model
        in
        Html.div [ Attr.class "modal-overlay fp-overlay", Ev.onClick CloseFilePicker ]
            [ Html.div [ Attr.class "fp-dialog" ]
                [ Html.div [ Attr.class "fp-header" ]
                    [ Html.span [ Attr.class "fp-title" ] [ Html.text "Attach File" ]
                    , Html.button [ Attr.class "fp-close", Ev.onClick CloseFilePicker ] [ Html.text "✕" ]
                    ]
                , Html.div [ Attr.class "fp-mode-bar" ]
                    [ Html.span
                        [ Attr.class ("fp-mode-tab" ++ (if model.filePickerMode == Local then " fp-mode-active" else ""))
                        , Ev.onClick (SetFilePickerInput "")
                        ]
                        [ Html.text "📁 Local" ]
                    , Html.span
                        [ Attr.class ("fp-mode-tab" ++ (if model.filePickerMode == Url then " fp-mode-active" else ""))
                        , Ev.onClick FilePickerToggleMode
                        ]
                        [ Html.text "🔗 URL" ]
                    ]
                , Html.div [ Attr.class "fp-input-row" ]
                    [ Html.input
                        [ Attr.class "fp-input"
                        , Attr.type_ "text"
                        , Attr.value model.filePickerInput
                        , Ev.onInput SetFilePickerInput
                        , Attr.placeholder "Search files…"
                        ]
                        []
                    ]
                , if model.filePickerLoading then
                    Html.div [ Attr.class "fp-loading" ] [ Html.text "Loading…" ]

                  else
                    Html.div [ Attr.class "fp-list" ]
                        (List.indexedMap (\i e -> viewFileEntry i e model) entries)
                ]
            ]


viewFileEntry : Int -> DirEntry -> Model -> Html Msg
viewFileEntry idx entry model =
    Html.div
        [ Attr.class ("fp-item" ++ (if idx == model.filePickerSelected then " fp-item-selected" else ""))
        , Ev.onClick
            (if entry.isDir then
                FilePickerNavigateDir entry.name

             else
                FilePickerConfirmItem
            )
        , Ev.onMouseEnter (FilePickerSelectItem idx)
        ]
        [ Html.span [ Attr.class "fp-item-icon" ] [ Html.text (if entry.isDir then "📁" else "📄") ]
        , Html.span [ Attr.class "fp-item-name" ] [ Html.text entry.name ]
        , if entry.isDir then
            Html.span [ Attr.class "fp-item-dir-slash" ] [ Html.text "/" ]

          else
            Html.text ""
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
    Html.node "svg" [ Attr.width 12, Attr.height 12, Attr.attribute "viewBox" "0 0 12 12" ]
        [ Html.node "line" [ Attr.attribute "x1" "2", Attr.attribute "y1" "6", Attr.attribute "x2" "10", Attr.attribute "y2" "6", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "1.5", Attr.attribute "stroke-linecap" "round" ] [] ]


svgMaximize : Html Msg
svgMaximize =
    Html.node "svg" [ Attr.width 12, Attr.height 12, Attr.attribute "viewBox" "0 0 12 12" ]
        [ Html.node "rect" [ Attr.attribute "x" "2", Attr.attribute "y" "2.5", Attr.width 8, Attr.height 7, Attr.attribute "rx" "1", Attr.attribute "fill" "none", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "1.3" ] [] ]


svgRestore : Html Msg
svgRestore =
    Html.node "svg" [ Attr.width 12, Attr.height 12, Attr.attribute "viewBox" "0 0 12 12" ]
        [ Html.node "rect" [ Attr.attribute "x" "4", Attr.attribute "y" "1", Attr.width 7, Attr.height 7, Attr.attribute "rx" "0.8", Attr.attribute "fill" "none", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "1.3" ] []
        , Html.node "rect" [ Attr.attribute "x" "1", Attr.attribute "y" "4", Attr.width 7, Attr.height 7, Attr.attribute "rx" "0.8", Attr.attribute "fill" "none", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "1.3" ] []
        ]


svgClose : Html Msg
svgClose =
    Html.node "svg" [ Attr.width 12, Attr.height 12, Attr.attribute "viewBox" "0 0 12 12" ]
        [ Html.node "line" [ Attr.attribute "x1" "3", Attr.attribute "y1" "3", Attr.attribute "x2" "9", Attr.attribute "y2" "9", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "1.5", Attr.attribute "stroke-linecap" "round" ] []
        , Html.node "line" [ Attr.attribute "x1" "9", Attr.attribute "y1" "3", Attr.attribute "x2" "3", Attr.attribute "y2" "9", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "1.5", Attr.attribute "stroke-linecap" "round" ] []
        ]


svgArrow : Html Msg
svgArrow =
    Html.node "svg" [ Attr.width 16, Attr.height 16, Attr.attribute "viewBox" "0 0 24 24", Attr.attribute "fill" "none", Attr.attribute "stroke" "currentColor", Attr.attribute "stroke-width" "2.5", Attr.attribute "stroke-linecap" "round", Attr.attribute "stroke-linejoin" "round" ]
        [ Html.node "line" [ Attr.attribute "x1" "12", Attr.attribute "y1" "20", Attr.attribute "x2" "12", Attr.attribute "y2" "4" ] []
        , Html.node "polyline" [ Attr.attribute "points" "6 10 12 4 18 10" ] []
        ]


svgStop : Html Msg
svgStop =
    Html.node "svg" [ Attr.width 14, Attr.height 14, Attr.attribute "viewBox" "0 0 24 24", Attr.attribute "fill" "currentColor" ]
        [ Html.node "rect" [ Attr.attribute "x" "6", Attr.attribute "y" "6", Attr.width 12, Attr.height 12, Attr.attribute "rx" "2" ] [] ]
