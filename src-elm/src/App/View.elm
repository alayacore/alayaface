module App.View exposing
    ( view
    )

{-| All view functions for the application shell (sessions, overlays,
menus, input bar). Overlay pages live in Overlay/*; this module wires
them to app state and messages.
-}

import Html exposing (Html, Attribute)
import Html.Attributes as Attr
import Html.Events as Ev
import Html.Keyed as Keyed
import Json.Decode as D
import Json.Encode as E
import Dict exposing (Dict)
import Set exposing (Set)
import Markdown
import App.Types exposing (..)
import App.Update exposing (SessionDir, decodeSessionDir, filterEntries, helpItems, nextCopyName)
import Session.Types as T
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


-- Shared Markdown render config


markdownOptions : Markdown.Options
markdownOptions =
    { githubFlavored = Just { tables = True, breaks = True }
    , defaultHighlighting = Nothing
    , sanitize = False
    , smartypants = False
    }




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
                (List.map (viewMessage model.cursorMsgId session) session.messages

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


viewMessage : Maybe String -> T.SessionState -> T.Message -> Html Msg
viewMessage cursorMsgId session msg =
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

        collapsed =
            T.isMsgCollapsed session.msgCollapsed msg

        collapsedClass =
            if collapsed then
                " collapsed"
            else
                ""

        -- Right-click handler for messages with historyId
        ctxAttrs =
            case msg.historyId of
                Just hid ->
                    [ Ev.preventDefaultOn "contextmenu"
                        (D.map2
                            (\clientX clientY ->
                                ( ShowCtxMenu (round clientX) (round clientY) hid session.id, True )
                            )
                            (D.field "clientX" D.float)
                            (D.field "clientY" D.float)
                        )
                    ]

                Nothing ->
                    []

        frameClass =
            "message message-" ++ T.roleToString msg.role ++ collapsedClass ++ cursorClass
    in
    Html.div
        ([ Attr.class frameClass ]
            ++ ctxAttrs
        )
        [ Html.div
            [ Attr.class "msg-header"
            , Ev.onClick (ToggleMsgCollapse session.id msg.id)
            , Attr.title (if collapsed then "Expand" else "Collapse")
            ]
            (viewMsgHeader msg collapsed)
        , if collapsed then
            Html.text ""

          else
            viewMsgBody msg
        ]


-- Header row of a message window: role label, optional tool info, and a
-- one-line preview when collapsed. The whole row toggles on click.
viewMsgHeader : T.Message -> Bool -> List (Html Msg)
viewMsgHeader msg collapsed =
    [ Html.span [ Attr.class "msg-label" ]
        [ Html.text (String.toUpper (T.roleToString msg.role)) ]
    , case msg.role of
        T.Tool ->
            Html.span [ Attr.class "msg-tool-info" ]
                [ Html.span [ Attr.class "msg-name" ]
                    [ Html.text (Maybe.withDefault "" msg.toolName) ]
                , Html.span [ Attr.class "msg-status" ]
                    [ Html.text (toolStatus msg) ]
                ]

        _ ->
            Html.text ""
    , if collapsed && msg.role /= T.Tool then
        Html.span [ Attr.class "msg-preview" ]
            [ Html.text (previewText msg) ]

      else
        Html.text ""
    ]


-- Tool state icon derived from the message, no handler changes:
-- ❌ error (UF error), ⏳ running (AF/Af/Uf stages), ✅ done (UF success).
toolStatus : T.Message -> String
toolStatus msg =
    if msg.isError then
        "❌"

    else if String.startsWith "🔧" (String.trim msg.content) then
        "⏳"

    else
        "✅"


-- One-line preview used by the collapsed header. Shows the first line of
-- the body, truncated to 80 chars with an ellipsis.
previewText : T.Message -> String
previewText msg =
    let
        first =
            case List.head (String.lines msg.content) of
                Just l ->
                    String.trim l

                Nothing ->
                    ""
    in
    if String.isEmpty first then
        ""

    else if String.length first > 80 then
        String.left 80 first ++ "…"

    else
        first


viewMsgBody : T.Message -> Html Msg
viewMsgBody msg =
    case msg.role of
        T.Assistant ->
            Html.div [ Attr.class "msg-body" ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Markdown.toHtmlWith markdownOptions
                        [ Attr.class "md" ]
                        msg.content
                    ]
                ]

        T.Reasoning ->
            Html.div [ Attr.class "msg-body" ]
                [ Html.text msg.content ]

        T.Tool ->
            Html.div [ Attr.class "msg-body" ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Markdown.toHtmlWith markdownOptions
                        [ Attr.class "md" ]
                        msg.content
                    ]
                ]

        T.User ->
            Html.div [ Attr.class "msg-body" ]
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
            Html.div [ Attr.class "msg-body" ]
                [ Html.div [ Attr.class "message-content" ]
                    (List.map (\line -> Html.span [] [ Html.text line ]) (String.lines msg.content))
                ]

        T.Notify ->
            Html.div [ Attr.class "msg-body" ]
                [ Html.div [ Attr.class "message-content" ]
                    [ Html.text msg.content ]
                ]

        T.Error ->
            Html.div [ Attr.class "msg-body" ]
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
