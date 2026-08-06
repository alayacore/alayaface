module App.Update exposing
    ( update
    , SessionDir
    , decodeSessionDir
    , helpItems
    , nextCopyName
    )

{-| Application update logic. Pure enough to reason about: transports
(DeltaEvent/FrameEvent/StatusEvent), session actions, window dragging,
and the preset/editor overlays. The types live in App.Types; Main only
forwards messages here.
-}

import Browser.Dom as Dom
import Dict exposing (Dict)
import Set exposing (Set)
import Json.Decode as D
import Json.Encode as E
import Task
import App.Types exposing (..)
import App.SelectorKit as Kit
import Session.Types as T
import Session.Protocol as P
import Session.Handlers as H
import Session.Selector as Sel exposing (Page(..))
import Session.FilePicker as FP
import Overlay.HelpWindow exposing (HelpItem, filterHelpItems)
import Ports


-- Constants


defaultWinW : Int
defaultWinW = 560

defaultWinH : Int
defaultWinH = 640

minWinW : Int
minWinW = 300

minWinH : Int
minWinH = 200

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
focusInput =
    Kit.focusPrompt


focusAfterDelay : String -> Cmd Msg
focusAfterDelay =
    Kit.focusAfterDelay


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
                                    if session.atBottom then
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
                                    List.length newSession.messages /= session.prevMsgCount

                                mcpJustCompleted =
                                    session.mcpStatus /= Nothing && newSession.mcpStatus == Nothing

                                cmds =
                                    Cmd.batch
                                        (List.filterMap identity
                                            [ if msgCountChanged && session.atBottom then
                                                Just (Ports.scrollToBottom { sessionId = ev.sessionId })

                                              else
                                                Nothing
                                            , if (msgCountChanged && session.atBottom || mcpJustCompleted) && model.activeId == Just ev.sessionId then
                                                Just (Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ ev.sessionId)))

                                              else
                                                Nothing
                                            ]
                                        )

                                updatedModel =
                                    { model
                                        | sessions = Dict.insert ev.sessionId { newSession | prevMsgCount = List.length newSession.messages } model.sessions
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

        McpAuthConfirm sid server ->
            case Dict.get sid model.sessions of
                Just s ->
                    case List.filter (\a -> a.server == server) s.pendingMcpAuths |> List.head of
                        Just auth ->
                            ( { model | sessions = Dict.insert sid { s | mcpAuthRunning = Just server } model.sessions }
                            , Ports.startMcpAuthFlow
                                { sessionId = sid
                                , serverName = server
                                , authUrl = auth.url
                                }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        McpAuthDeny sid server ->
            case Dict.get sid model.sessions of
                Just sess ->
                    ( { model
                        | sessions = Dict.insert sid
                            { sess
                                | pendingMcpAuths = List.filter (\a -> a.server /= server) sess.pendingMcpAuths
                                , mcpAuthRunning =
                                    if sess.mcpAuthRunning == Just server then
                                        Nothing

                                    else
                                        sess.mcpAuthRunning
                            }
                            model.sessions
                      }
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
                                , pendingMcpAuths = []
                                , mcpAuthRunning = Nothing
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
                            { sess
                                | pendingMcpAuths = []
                                , mcpAuthRunning = Nothing
                                , mcpStatus = Nothing
                            }
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
                    ( { model
                        | sessions = Dict.insert sid
                            { sess | pendingConfirm = [] }
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

        ToggleMsgCollapse sid msgId ->
            ( updateSession model sid (\sess ->
                case List.filter (\m -> m.id == msgId) sess.messages |> List.head of
                    Just m ->
                        { sess | msgCollapsed = T.toggleMsgCollapsed sess.msgCollapsed m }

                    Nothing ->
                        sess
              )
            , Cmd.none
            )

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
                            String.trim s.filePicker.input
                    in
                    if url == "" then
                        ( model, Cmd.none )

                    else
                        let
                            detectedType =
                                FP.detectMediaType url

                            newItem =
                                { id = "url-" ++ String.fromInt (List.length s.staged)
                                , mediaType = detectedType
                                , uri = url
                                , name = Just (String.left 60 url)
                                }
                        in
                        ( updateActiveSession model (\sess ->
                            let
                                fp =
                                    sess.filePicker
                            in
                            { sess
                                | staged = sess.staged ++ [ newItem ]
                                , filePicker = { fp | show = False, input = "" }
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
                        let
                            fp =
                                sess.filePicker
                        in
                        { sess
                            | filePicker =
                                { fp
                                    | show = True
                                    , mode = T.Local
                                    , input = ""
                                    , filter = ""
                                    , selected = 0
                                    , loading = True
                                }
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
            ( updateActiveSession model (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s | filePicker = { fp | show = False, savedLocalPath = "", savedUrlPath = "" } }
              )
            , focusInput model
            )

        SetFilePickerInput val ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker
                    in
                    if fp.mode == T.Url then
                        -- URL mode: just update input, no path parsing
                        ( updateActiveSession model (\sess ->
                            { sess | filePicker = { fp | input = val } }
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
                                FP.parsePathInput safeVal fp.dir fp.baseDir

                            cmd =
                                if needsResolve then
                                    Ports.fsResolvePath { path = resolvePath }
                                else
                                    Cmd.none

                            -- Clamp selection to filtered list length
                            previewFp =
                                { fp | input = safeVal, filter = filterText }

                            filteredLen =
                                List.length (FP.filterEntries previewFp)

                            clampedIdx =
                                if fp.selected >= filteredLen then
                                    max 0 (filteredLen - 1)
                                else
                                    fp.selected
                        in
                        ( updateActiveSession model (\sess ->
                            { sess
                                | filePicker = { fp | input = safeVal, filter = filterText, selected = clampedIdx }
                            }
                          )
                        , cmd
                        )

                Nothing ->
                    ( model, Cmd.none )

        FilePickerNavigateDir name ->
            -- User clicked a directory in the file list:
            -- append the directory name + "/" to the current input path.
            case getActiveSession model of
                Just s ->
                    let
                        ( newFp, newDir ) =
                            FP.appendDirToInput s.filePicker name
                    in
                    ( updateActiveSession model (\sess ->
                        { sess | filePicker = newFp }
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
                                    FP.filterEntries s.filePicker
                            in
                            case List.head (List.drop idx entries) of
                                Just e ->
                                    Ports.scrollIntoView ("fp-item-" ++ s.id ++ "-" ++ e.name)

                                Nothing ->
                                    Cmd.none

                        Nothing ->
                            Cmd.none
            in
            ( updateActiveSession model (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s | filePicker = { fp | selected = idx } }
              )
            , scrollCmd
            )

        FilePickerConfirmItem ->
            case getActiveSession model of
                Just s ->
                    let
                        fp =
                            s.filePicker

                        entries =
                            FP.filterEntries fp
                    in
                    case List.head (List.drop fp.selected entries) of
                        Just entry ->
                            if entry.isDir then
                                -- Directory: autocomplete its name into the input path
                                let
                                    ( newFp, newDir ) =
                                        FP.appendDirToInput fp entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess | filePicker = newFp }
                                  )
                                , Ports.fsResolvePath { path = newDir }
                                )

                            else
                                -- File: select it
                                let
                                    fullPath =
                                        if fp.dir == "" then
                                            entry.name
                                        else
                                            fp.dir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePicker = { fp | loading = True, pendingFileName = entry.name }
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
                        fp =
                            s.filePicker

                        entries =
                            FP.filterEntries fp
                    in
                    case List.head (List.drop idx entries) of
                        Just entry ->
                            if entry.isDir then
                                let
                                    ( newFp, newDir ) =
                                        FP.appendDirToInput fp entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess | filePicker = { newFp | selected = idx } }
                                  )
                                , Ports.fsResolvePath { path = newDir }
                                )

                            else
                                let
                                    fullPath =
                                        if fp.dir == "" then
                                            entry.name
                                        else
                                            fp.dir ++ "/" ++ entry.name
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePicker = { fp | loading = True, selected = idx, pendingFileName = entry.name }
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
                        fp =
                            s.filePicker

                        ( newMode, newInput ) =
                            case fp.mode of
                                T.Local ->
                                    -- Switching FROM local TO URL: save local path, restore saved URL
                                    ( T.Url
                                    , fp.savedUrlPath
                                    )

                                T.Url ->
                                    -- Switching FROM URL TO local: save URL, restore saved local path
                                    let
                                        restoredLocal =
                                            if fp.savedLocalPath /= "" then
                                                fp.savedLocalPath
                                            else if fp.dir /= "" then
                                                fp.dir ++ "/"
                                            else
                                                ""
                                    in
                                    ( T.Local
                                    , restoredLocal
                                    )

                        ( savedLocal, savedUrl ) =
                            case fp.mode of
                                T.Local ->
                                    ( fp.input
                                    , ""
                                    )

                                T.Url ->
                                    ( ""
                                    , fp.input
                                    )
                    in
                    ( updateActiveSession model (\oldS ->
                        { oldS
                            | filePicker =
                                { fp
                                    | mode = newMode
                                    , input = newInput
                                    , filter = ""
                                    , savedLocalPath = savedLocal
                                    , savedUrlPath = savedUrl
                                }
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
                    let
                        fp =
                            s.filePicker
                    in
                    if fp.dir /= "" && fp.baseDir /= "" then
                        let
                            cleanPath =
                                if String.endsWith "/" fp.dir then
                                    String.dropRight 1 fp.dir
                                else
                                    fp.dir

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
                                | filePicker = { fp | loading = True, input = parentDir ++ "/", filter = "" }
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
                    List.filterMap FP.decodeDirEntry entries

                -- Filter out ".." (parent directory entry) — not useful in UI
                noDotDot =
                    List.filter (\e -> e.name /= "..") parsed
            in
            ( updateActiveSession model (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s
                    | filePicker = { fp | entries = noDotDot, loading = False, error = Nothing }
                }
              )
            , Cmd.none
            )

        FsHomeDirResult home ->
            ( updateActiveSession model (\s ->
                let
                    fp =
                        s.filePicker
                in
                { s
                    | filePicker =
                        { fp
                            | baseDir = home
                            , dir = home
                            , input = home ++ "/"
                            , filter = ""
                            , loading = True
                        }
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
                        fp =
                            s.filePicker

                        name =
                            if fp.pendingFileName /= "" then
                                Just fp.pendingFileName
                            else
                                Nothing

                        detectedType =
                            case name of
                                Just n -> FP.detectMediaType n
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
                            | filePicker = { fp | show = False, input = "", pendingFileName = "" }
                            , staged = sess.staged ++ [ newItem ]
                        }
                      )
                    , focusInput model
                    )

                Nothing ->
                    ( model, Cmd.none )

        -- Text file write/read results (Plan Mode storage).
        -- P2 wires these into the plan save/load flow; for now the
        -- result is acknowledged and surfaced in the console.
        FsWriteResult _ ->
            ( model, Cmd.none )

        FsReadResult _ ->
            ( model, Cmd.none )

        FsResolvePathResult result ->
            case getActiveSession model of
                Just s ->
                    case D.decodeValue resolvePathResultDecoder result of
                        Ok rp ->
                            if rp.exists && rp.isDir then
                                let
                                    fp =
                                        s.filePicker

                                    sameDir =
                                        rp.resolved == fp.dir
                                in
                                ( updateActiveSession model (\sess ->
                                    { sess
                                        | filePicker = { fp | dir = rp.resolved, selected = 0 }
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
            ( { model | showSessionManager = True, showGlobalMenu = False, sessionManagerError = Nothing }
            , Ports.listSessionDirs {}
            )

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

        SessionActionResult raw ->
            case D.decodeValue sessionActionResultDecoder raw of
                Ok res ->
                    if res.ok && res.kind == "resume" then
                        -- Resume succeeded: reveal the resumed session
                        ( { model | showSessionManager = False, sessionManagerError = Nothing }
                        , Cmd.none
                        )

                    else if res.ok then
                        ( { model | sessionManagerError = Nothing }, Cmd.none )

                    else
                        ( { model | sessionManagerError = Just res.error }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        ResumeSession id ->
            -- pendingSwitchOnCreate makes SessionCreated switch to the
            -- resumed session once it appears (mirrors the original UX).
            ( { model | pendingSwitchOnCreate = True, sessionManagerError = Nothing }
            , Ports.resumeSession { sessionId = id }
            )

        DeleteSession id ->
            let
                -- If the deleted dir belongs to a running session, drop
                -- its window too (delete_session_dir closes the process).
                cleaned =
                    if Dict.member id model.sessions then
                        { model
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
                    else
                        model
            in
            ( { cleaned | sessionManagerError = Nothing }
            , Ports.deleteSessionDir { sessionId = id }
            )

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
            Kit.setInput sessionModelKit val model

        ModelSelectorSelectItem idx ->
            Kit.selectItem sessionModelKit idx model

        ModelSelectorConfirmItem ->
            Kit.confirmItem sessionModelKit model

        ModelSelectorEditModel id ->
            Kit.editItem sessionModelKit id model

        ModelSelectorAddModel ->
            Kit.addItem sessionModelKit model

        ModelSelectorEditBack ->
            Kit.editBack sessionModelKit model

        ModelSelectorEditSave ->
            Kit.editSave sessionModelKit model

        ModelSelectorEditField field value ->
            Kit.editField sessionModelKit field value model

        ModelSelectorDeleteModel id ->
            Kit.deleteItem sessionModelKit id model

        ModelSelectorConfirmDelete id ->
            Kit.confirmDelete sessionModelKit id model

        ModelSelectorCancelDelete ->
            Kit.cancelDelete sessionModelKit model

        ModelSelectorConfirmSync ->
            Kit.confirmSync sessionModelKit model

        ModelSelectorDiscardClose ->
            Kit.discardClose sessionModelKit model

        ModelSelectorCancelSyncPrompt ->
            Kit.cancelSyncPrompt sessionModelKit model

        ModelSelectorSyncResult isError message ->
            case getActiveSession model of
                Just s ->
                    if s.modelSelector.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if isError then
                        Kit.syncFailed sessionModelKit message model

                    else
                        Kit.syncSuccess sessionModelKit model

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
            Kit.setInput defaultModelsKit val model

        DefaultModelsSelectItem idx ->
            Kit.selectItem defaultModelsKit idx model

        DefaultModelsConfirmItem ->
            Kit.confirmItem defaultModelsKit model

        DefaultModelsEditModel id ->
            Kit.editItem defaultModelsKit id model

        DefaultModelsAddModel ->
            Kit.addItem defaultModelsKit model

        DefaultModelsEditBack ->
            Kit.editBack defaultModelsKit model

        DefaultModelsEditSave ->
            Kit.editSave defaultModelsKit model

        DefaultModelsEditField field value ->
            Kit.editField defaultModelsKit field value model

        DefaultModelsDeleteModel id ->
            Kit.deleteItem defaultModelsKit id model

        DefaultModelsConfirmDelete id ->
            Kit.confirmDelete defaultModelsKit id model

        DefaultModelsCancelDelete ->
            Kit.cancelDelete defaultModelsKit model

        DefaultModelsConfirmSync ->
            Kit.confirmSync defaultModelsKit model

        DefaultModelsDiscardClose ->
            Kit.discardClose defaultModelsKit model

        DefaultModelsCancelSyncPrompt ->
            Kit.cancelSyncPrompt defaultModelsKit model

        DefaultModelsSyncResult raw ->
            case D.decodeValue defaultModelsSyncResultDecoder raw of
                Ok res ->
                    if model.defaultModelsEditor.state.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if res.ok then
                        Kit.syncSuccess defaultModelsKit model

                    else
                        Kit.syncFailed defaultModelsKit res.error model

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
            Kit.setInput mcpKit val model

        McpSelectItem idx ->
            Kit.selectItem mcpKit idx model

        McpConfirmItem ->
            Kit.confirmItem mcpKit model

        McpEditServer id ->
            Kit.editItem mcpKit id model

        McpAddServer ->
            Kit.addItem mcpKit model

        McpEditBack ->
            Kit.editBack mcpKit model

        McpEditSave ->
            Kit.editSave mcpKit model

        McpEditField field value ->
            Kit.editField mcpKit field value model

        McpDeleteServer id ->
            Kit.deleteItem mcpKit id model

        McpConfirmDelete id ->
            Kit.confirmDelete mcpKit id model

        McpCancelDelete ->
            Kit.cancelDelete mcpKit model

        McpConfirmSync ->
            Kit.confirmSync mcpKit model

        McpDiscardClose ->
            Kit.discardClose mcpKit model

        McpCancelSyncPrompt ->
            Kit.cancelSyncPrompt mcpKit model

        McpSyncResult raw ->
            case D.decodeValue mcpSyncResultDecoder raw of
                Ok res ->
                    if model.mcpEditor.state.page /= ModelSelSyncing then
                        ( model, Cmd.none )

                    else if res.ok then
                        Kit.syncSuccess mcpKit model

                    else
                        Kit.syncFailed mcpKit res.error model

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

        FillMcpAuthUrl server url ->
            case getActiveSession model of
                Just s ->
                    ( updateActiveSession model (\sess ->
                        { sess | mcpAuthRunning = Just server }
                      )
                    , Ports.fillMcpAuthUrl
                        { sessionId = s.id
                        , serverName = server
                        , authUrl = url
                        }
                    )

                Nothing ->
                    ( model, Cmd.none )

        OpenMediaPreview item ->
            ( updateActiveSession model (\sess -> { sess | mediaPreview = Just item })
            , Cmd.none
            )

        CloseMediaPreview ->
            ( updateActiveSession model (\sess -> { sess | mediaPreview = Nothing })
            , Cmd.none
            )

        ScrollPosition sid scrollTop scrollHeight clientHeight ->
            let
                atBottom =
                    scrollTop + clientHeight >= scrollHeight - 5
            in
            ( updateSession model sid (\s -> { s | atBottom = atBottom })
            , Cmd.none
            )

        KeyDown key ctrl alt defaultPrevented ->
            -- If another handler already processed this key (e.g. textarea), skip
            if defaultPrevented then
                ( model, Cmd.none )

            -- Escape or Ctrl+[ dismisses the context menu and the media
            -- preview. Other overlays are closed via their close buttons
            -- only (no Escape).
            else if key == "Escape" || (key == "[" && ctrl) then
                if model.ctxVisible then
                    ( { model | ctxVisible = False }, Cmd.none )

                else
                    ( updateActiveSession model (\sess -> { sess | mediaPreview = Nothing })
                    , Cmd.none
                    )

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
                            Maybe.map .w winSize |> Maybe.withDefault defaultWinW

                        winH =
                            Maybe.map .h winSize |> Maybe.withDefault defaultWinH

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


sessionActionResultDecoder : D.Decoder { ok : Bool, error : String, kind : String }
sessionActionResultDecoder =
    D.map3
        (\ok error kind -> { ok = ok, error = error, kind = kind })
        (D.field "ok" D.bool)
        (D.field "error" D.string)
        (D.field "kind" D.string)


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


-- ─── Selector kits ──────────────────────────────────────────────────
--
-- Parameterized update glue for the three list-based selectors. The
-- state machine (Session.Selector) and the view (Overlay.Selector) are
-- shared; these kits supply the per-feature accessors and behaviors so
-- the App.Update handlers can delegate to App.SelectorKit.

sessionModelKit : Kit.Kit T.ModelInfo T.ModelDraft
sessionModelKit =
    { get = \model ->
        case getActiveSession model of
            Just s ->
                s.modelSelector

            Nothing ->
                Sel.empty
    , set = \st model ->
        updateActiveSession model (\s -> { s | modelSelector = st })
    , setShow = \v model ->
        updateActiveSession model (\s -> { s | showModelSelector = v })
    , nameOf = modelName
    , idOf = \m -> m.id
    , setIdOf = \newId m -> { m | id = newId }
    , draftOf = draftFromModel
    , emptyDraft = T.emptyDraft
    , draftIdOf = \d -> d.id
    , itemOfDraft = modelFromDraft
    , updateDraftField = updateDraftField
    , inputId = \model ->
        case model.activeId of
            Just sid ->
                "model-selector-input-" ++ sid

            Nothing ->
                ""
    , editorId = \model ->
        case model.activeId of
            Just sid ->
                "model-editor-name-" ++ sid

            Nothing ->
                ""
    , scrollItemId = \model id ->
        case model.activeId of
            Just sid ->
                "model-selector-item-" ++ sid ++ "-" ++ String.fromInt id

            Nothing ->
                ""
    , confirm = \model ->
        case getActiveSession model of
            Just s ->
                case Sel.selectedItem modelName s.modelSelector of
                    Just m ->
                        if Sel.isDirty s.modelSelector then
                            -- Unsaved edits: ask to sync before leaving
                            ( updateActiveSession model (\sess -> { sess | modelSelector = Sel.askSync sess.modelSelector })
                            , Cmd.none
                            )

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
    , syncCmd = \model ->
        case getActiveSession model of
            Just s ->
                Ports.modelSync
                    { sessionId = s.id
                    , config = encodeModels s.modelSelector.working
                    }

            Nothing ->
                Cmd.none
    , syncSuccess = \model ->
        ( updateActiveSession model (\sess -> { sess | showModelSelector = False, modelSelector = Sel.close sess.modelSelector })
        , focusInput model
        )
    , afterClose = \model -> focusInput model
    }


defaultModelsKit : Kit.Kit T.ModelInfo T.ModelDraft
defaultModelsKit =
    { get = \model -> model.defaultModelsEditor.state
    , set = \st model ->
        let
            ed =
                model.defaultModelsEditor
        in
        { model | defaultModelsEditor = { ed | state = st } }
    , setShow = \v model ->
        let
            ed =
                model.defaultModelsEditor
        in
        { model | defaultModelsEditor = { ed | show = v } }
    , nameOf = modelName
    , idOf = \m -> m.id
    , setIdOf = \newId m -> { m | id = newId }
    , draftOf = draftFromModel
    , emptyDraft = T.emptyDraft
    , draftIdOf = \d -> d.id
    , itemOfDraft = modelFromDraft
    , updateDraftField = updateDraftField
    , inputId = \_ -> "model-selector-input-default"
    , editorId = \_ -> "model-editor-name-default"
    , scrollItemId = \_ id -> "model-selector-item-default-" ++ String.fromInt id
    , confirm = \model ->
        let
            ed =
                model.defaultModelsEditor
        in
        case Sel.selectedItem modelName ed.state of
            Just m ->
                ( { model | defaultModelsEditor = { ed | state = Sel.openEdit (draftFromModel m) ed.state } }
                , Kit.focusAndCursor "model-editor-name-default"
                )

            Nothing ->
                ( model, Cmd.none )
    , syncCmd = \model ->
        Ports.syncDefaultModels
            { preset = model.defaultModelsEditor.preset
            , config = encodeModels model.defaultModelsEditor.state.working
            }
    , syncSuccess = \model ->
        ( { model | defaultModelsEditor = emptyDefaultModelsEditor }
        , Cmd.none
        )
    , afterClose = \_ -> Cmd.none
    }


mcpKit : Kit.Kit T.McpInfo T.McpDraft
mcpKit =
    { get = \model -> model.mcpEditor.state
    , set = \st model ->
        let
            ed =
                model.mcpEditor
        in
        { model | mcpEditor = { ed | state = st } }
    , setShow = \v model ->
        let
            ed =
                model.mcpEditor
        in
        { model | mcpEditor = { ed | show = v } }
    , nameOf = mcpServerName
    , idOf = \s -> s.id
    , setIdOf = \newId s -> { s | id = newId }
    , draftOf = draftFromMcp
    , emptyDraft = T.emptyMcpDraft
    , draftIdOf = \d -> d.id
    , itemOfDraft = mcpFromDraft
    , updateDraftField = updateMcpDraftField
    , inputId = \_ -> "mcp-selector-input-default"
    , editorId = \_ -> "mcp-editor-server-default"
    , scrollItemId = \_ id -> "mcp-selector-item-default-" ++ String.fromInt id
    , confirm = \model ->
        let
            ed =
                model.mcpEditor
        in
        case Sel.selectedItem mcpServerName ed.state of
            Just s ->
                ( { model | mcpEditor = { ed | state = Sel.openEdit (draftFromMcp s) ed.state } }
                , Kit.focusAndCursor "mcp-editor-server-default"
                )

            Nothing ->
                ( model, Cmd.none )
    , syncCmd = \model ->
        Ports.syncDefaultMcp
            { preset = model.mcpEditor.preset
            , config = encodeMcpServers model.mcpEditor.state.working
            }
    , syncSuccess = \model ->
        ( { model | mcpEditor = emptyMcpEditor }
        , Cmd.none
        )
    , afterClose = \_ -> Cmd.none
    }
