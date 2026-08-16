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
import Json.Decode as D
import Dict exposing (Dict)
import Set exposing (Set)
import Time
import Markdown
import App.Types exposing (..)
import App.Update exposing (SessionDir, decodeSessionDir, nextCopyName)
import Icons
import Session.Types as T
import Session.Selector as Sel exposing (Page(..))
import Session.FilePicker as FP
import Session.ToolView as ToolView
import Session.Format as F
import Plan.Types as PT
import Plan.Meta as PM
import Plan.Detect
import Plan.Cascade as PC
import Plan.Update as PU
import Plan.View
import Overlay.ConfirmTool
import Overlay.Settings
import Overlay.GlobalConfig
import Overlay.AsrConfig
import Overlay.PresetManager
import Overlay.McpInit
import Overlay.FilePicker
import Overlay.Selector
import Overlay.ModelEditor
import Overlay.McpEditor
import Overlay.MediaPreview


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
    -- Click-away close for the global menu: any click that is not
    -- stopPropagation'd by the menu button/panel bubbles here and
    -- closes the menu (idempotent when it is already closed).
    Html.div [ Attr.class "app", Ev.onClick CloseGlobalMenu ]
        [ Html.node "style"
            []
            [ Html.text (".app{--content-width:" ++ String.fromInt (min 864 (max 400 model.appWidth - 40)) ++ "px}") ]
        , Html.div
            [ Attr.id "main-content"
            , Attr.class
                ("main-content"
                    ++ (if model.drag == Nothing then "" else " panning")
                )
            -- Right-clicking the canvas (or the empty background) opens
            -- the global menu at the pointer position. Window panels
            -- stop contextmenu propagation, and message windows already
            -- stopPropagation their own context menu, so this only fires
            -- on empty canvas space.
            , Ev.preventDefaultOn "contextmenu"
                (D.map2
                    (\clientX clientY ->
                        ( ShowGlobalMenuAt (round clientX) (round clientY), True )
                    )
                    (D.field "clientX" D.float)
                    (D.field "clientY" D.float)
                )
            ]
            (if List.isEmpty model.sessionOrder && List.isEmpty model.planOrder then
                [ viewNoSessionPanel model ]

             else
                -- Infinite canvas: windows live in canvas coordinates on
                -- this layer; panning translates the whole layer.
                [ Html.div
                    [ Attr.class "canvas"
                    , Attr.style "transform" (canvasTransform model)
                    ]
                    (List.map (\id -> viewSessionPanel model id) model.sessionOrder
                        ++ List.map (\pid -> viewPlanPanel model pid) model.planOrder
                    )
                ]
            )
        , viewGlobalMenu model
        , viewContextMenu model
        , viewSessionManagerOverlay model
        , viewVersionOverlays model
        , viewPresetManagerOverlay model
        , viewDefaultModelsEditorOverlay model
        , viewMcpEditorOverlay model
        , viewSettingsEditorOverlay model
        , viewGlobalConfigOverlay model
        , viewAsrConfigOverlay model
        , viewPlanCascadeOverlay model
        ]


{-| Canvas pan is started by the pointer pipeline (App.Pointer +
App/Update FSM), not by DOM mousedown handlers: transport.js classifies
the pointerdown target, captures draggable surfaces, and forwards raw
events; a drag activates only after the primary pointer crosses the
slop. See App/Pointer.elm and the Pointer* handlers in App/Update.
-}

canvasTransform : Model -> String
canvasTransform model =
    "translate3d("
        ++ String.fromInt model.canvasOffset.x
        ++ "px,"
        ++ String.fromInt model.canvasOffset.y
        ++ "px,0) scale("
        ++ String.fromFloat model.canvasScale
        ++ ")"


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
                 , Attr.attribute "data-session" id
                 , Ev.onClick (SwitchSession id)
                 -- stopPropagation so window mousedowns never reach the
                 -- canvas pan handler on main-content.
                 , Ev.stopPropagationOn "mousedown" (D.succeed ( ActivateSession id, True ))
                 -- Right-clicking inside a window must not open the
                 -- global menu (the canvas context menu); keep the
                 -- browser's default menu for copy/paste etc.
                 , Ev.stopPropagationOn "contextmenu" (D.succeed ( NoOp, True ))
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
                    , Attr.title "Drag to move"
                    ]
                    [ Html.span [ Attr.class "session-bar-title" ]
                        [ Html.text
                            ((case Dict.get id model.planNodeSessions of
                                Just lbl ->
                                    "[Plan · " ++ lbl ++ "] "

                                Nothing ->
                                    ""
                             )
                                ++ (if session.activeModelName /= "" then
                                        "Session " ++ String.fromInt idx ++ " — " ++ session.activeModelName

                                    else
                                        "Session " ++ String.fromInt idx
                                   )
                            )
                        ]
                    , let
                        tokenLabel =
                            F.formatTokenUsage session.contextTokens session.contextLimit
                      in
                      if tokenLabel == "" then
                        Html.text ""

                      else
                        Html.span
                            [ Attr.class "session-bar-tokens"
                            , Attr.title
                                ("Context: "
                                    ++ String.fromInt session.contextTokens
                                    ++ " / "
                                    ++ String.fromInt session.contextLimit
                                    ++ " tokens"
                                )
                            ]
                            [ Html.text tokenLabel ]
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
        [ Html.div [ Attr.class "hs-container-inline" ]
            [ Html.div [ Attr.class "hs-logo" ] [ Html.text "AlayaFace" ]
            , Html.div [ Attr.class "hs-tagline" ]
                [ Html.text "No session open — right-click the canvas and pick a preset under New Session" ]
            ]
        ]


viewGlobalMenu : Model -> Html Msg
viewGlobalMenu model =
    if model.showGlobalMenu then
        Html.div
            [ Attr.class "global-menu"
            , Attr.style "left" (String.fromInt model.globalMenuX ++ "px")
            , Attr.style "top" (String.fromInt model.globalMenuY ++ "px")
            ]
            [ Html.div
                [ Attr.class "global-menu-panel"
                -- Clicks inside the panel must not bubble to the app root's
                -- close handler; each menu item closes the menu through its
                -- own action, and clicking the panel background keeps it
                -- open. The menu closes only when clicking OUTSIDE it.
                , Ev.stopPropagationOn "click" (D.succeed ( NoOp, True ))
                ]
                [ Html.div
                    [ Attr.class
                        ("global-menu-item"
                            ++ (if model.presetSubmenuOpen then " global-menu-item-hover" else "")
                        )
                    -- Click toggles the preset flyout (no hover — a
                    -- mouse over the item must not open it). Tapping
                    -- outside closes the menu (the .app click handler),
                    -- which also resets the flyout.
                    , Ev.onClick (SetPresetSubmenu (not model.presetSubmenuOpen))
                    ]
                    [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "+" ]
                    , Html.text " New Session"
                    , if model.presetSubmenuOpen then
                        Html.div [ Attr.class "global-menu-submenu" ]
                            (if List.isEmpty model.presets then
                                [ Html.div [ Attr.class "global-menu-submenu-empty" ] [ Html.text "No presets yet." ] ]

                             else
                                List.map
                                    (\p ->
                                        Html.div
                                            [ Attr.class "global-menu-submenu-item"
                                            , Ev.onClick (CreateSessionWith p.name)
                                            ]
                                            [ Html.text p.name ]
                                    )
                                    model.presets
                            )

                      else
                        Html.text ""
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
                    , Html.text "Preset Manager"
                    ]
                , Html.div
                    [ Attr.class "global-menu-item"
                    , Ev.onClick OpenGlobalConfig
                    ]
                    [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "⚙" ]
                    , Html.text "Global config"
                    ]
                , Html.div
                    [ Attr.class "global-menu-item"
                    , Ev.onClick OpenAsrConfig
                    ]
                    [ Html.span [ Attr.class "global-menu-icon" ] [ Icons.mic ]
                    , Html.text "ASR config"
                    ]
                , Html.div
                    [ Attr.class "global-menu-item"
                    , Ev.onClick CanvasZoomReset
                    , Attr.title "Reset zoom to 100%"
                    ]
                    [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "🔍" ]
                    , Html.text
                        ("Zoom "
                            ++ String.fromInt (round (model.canvasScale * 100))
                            ++ "%"
                        )
                    ]
                ]
            ]

    else
        Html.text ""


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
            -- C2b (§8.1): the session manager only lists Session ROOTS —
            -- directories with a refs record (registered by plain creation
            -- and by the restart scan). Work-copy directories
            -- (sessions/<forkId>/) are not session identities and are not shown.
            dirs =
                List.filterMap decodeSessionDir model.sessionDirs
                    |> List.filter (\d -> Dict.member d.id model.sessionRefs)
        in
        viewOverlay CloseSessionManager
            [ Html.div [ Attr.class "sel-page" ]
                [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Session Manager" ]
                , Html.div [ Attr.class "sel-page-status sel-page-status-fixed" ]
                    [ Html.text "Resume re-opens a saved session (its history is replayed from disk)." ]
                , case model.sessionManagerError of
                    Just err ->
                        Html.div [ Attr.class "sel-page-status sel-page-status-error" ] [ Html.text err ]

                    Nothing ->
                        Html.text ""
                , if List.isEmpty dirs then
                    Html.div [ Attr.class "sel-page-status" ] [ Html.text "No saved sessions." ]

                  else
                    Html.div [ Attr.class "sel-page-list" ]
                        (List.map (\dir ->
                            let
                                active =
                                    isSessionDirActive model dir.id

                                canResume =
                                    not active
                            in
                            Html.div
                                [ Attr.class "sel-page-item" ]
                                [ Html.div [ Attr.class "sel-page-item-main" ]
                                    [ Html.span
                                        [ Attr.class "sel-page-item-name"
                                        , Attr.title dir.id
                                        ]
                                        [ Html.text (String.left 8 dir.id) ]
                                    , Html.span [ Attr.class "sel-page-item-sub" ]
                                        [ Html.text (formatEpoch dir.createdAt) ]
                                    , if active then
                                        Html.span [ Attr.class "sel-page-item-sub sel-page-item-active" ] [ Html.text "· active" ]

                                      else
                                        Html.text ""
                                    ]
                                , Html.button
                                    [ Attr.class "sel-page-item-btn sel-page-item-btn-allow"
                                    , Ev.onClick (ResumeSession dir.id)
                                    , Attr.disabled (not canResume)
                                    , Attr.title
                                        (if active then
                                            "Session is already open"

                                         else
                                            "Re-open this session (replays its history)"
                                        )
                                    ]
                                    [ Html.text "Resume" ]
                                , Html.button
                                    [ Attr.class "sel-page-item-btn"
                                    , Ev.onClick (OpenVersionList dir.id)
                                    , Attr.title "Browse this session's versions (read-only history)"
                                    ]
                                    [ Html.text ("Versions (" ++ String.fromInt (List.length (Maybe.withDefault [] (Maybe.map .versions (Dict.get dir.id model.sessionRefs)))) ++ ")") ]
                                , Html.button
                                    [ Attr.class "sel-page-item-btn sel-page-item-btn-deny"
                                    , Ev.onClick (DeleteSession dir.id)
                                    , Attr.title "Delete this session's files on disk"
                                    ]
                                    [ Html.text "Delete" ]
                                ]
                            ) dirs
                        )
                ]
            ]
    else
        Html.text ""



-- ─── C4 version browsing (read-only history) ───────────────────────

{-| C4 version-browsing overlay: the version list (session-manager
entry point) or a version detail (read-only messages + plan status).
D8: old versions are read-only, no materialization.
-}
viewVersionOverlays : Model -> Html Msg
viewVersionOverlays model =
    case model.versionViewFor of
        Just hash ->
            viewVersionDetail model hash

        Nothing ->
            case model.versionListFor of
                Just sid ->
                    viewVersionList model sid

                Nothing ->
                    Html.text ""


viewVersionList : Model -> String -> Html Msg
viewVersionList model sid =
    let
        versions =
            Dict.get sid model.sessionRefs
                |> Maybe.map .versions
                |> Maybe.withDefault []

        headHash =
            Dict.get sid model.sessionRefs |> Maybe.map .head
    in
    viewOverlay CloseVersionList
        [ Html.div [ Attr.class "sel-page" ]
            [ Html.div [ Attr.class "sel-page-title" ] [ Html.text ("Versions · " ++ String.left 8 sid) ]
            , Html.div [ Attr.class "sel-page-status" ]
                [ Html.text "Read-only snapshots of this session's history (head = current world)." ]
            , Html.div [ Attr.class "sel-page-list" ]
                (List.indexedMap
                    (\i h ->
                        let
                            isHead =
                                headHash == Just h
                        in
                        Html.div [ Attr.class "sel-page-item" ]
                            [ Html.div [ Attr.class "sel-page-item-main" ]
                                [ Html.span [ Attr.class "sel-page-item-name" ] [ Html.text ("v" ++ String.fromInt i) ]
                                , Html.span [ Attr.class "sel-page-item-sub" ]
                                    [ Html.text (String.left 12 h ++ (if isHead then " · head" else "")) ]
                                ]
                            , Html.button
                                [ Attr.class "sel-page-item-btn sel-page-item-btn-allow"
                                , Ev.onClick (ViewVersion sid h)
                                , Attr.title "View this version's messages (read-only)"
                                ]
                                [ Html.text "View" ]
                            ]
                    )
                    versions
                )
            ]
        ]


viewVersionDetail : Model -> String -> Html Msg
viewVersionDetail model hash =
    let
        sid =
            Maybe.withDefault "" model.versionViewSession

        version =
            Dict.get hash model.versionCache

        msgs =
            case version of
                Just v ->
                    List.concatMap
                        (\b -> Dict.get b model.blockCache |> Maybe.withDefault [])
                        v.blocks

                Nothing ->
                    []

        planLines =
            case version of
                Just v ->
                    Dict.foldl
                        (\pid maybeRun acc ->
                            let
                                status =
                                    case maybeRun of
                                        Just runHash ->
                                            Dict.get runHash model.runSummaries
                                                |> Maybe.map .status
                                                |> Maybe.withDefault "?"

                                        Nothing ->
                                            "not-started"
                            in
                            Html.div [ Attr.class "version-plan-line" ]
                                [ Html.text ("[Plan: " ++ String.left 16 pid ++ "…] " ++ status) ]
                                :: acc
                        )
                        []
                        v.planViews

                Nothing ->
                    []
    in
    viewOverlay CloseVersionView
        [ Html.div [ Attr.class "sel-page" ]
            [ Html.div [ Attr.class "sel-page-title" ]
                [ Html.text ("Version · " ++ String.left 8 sid ++ " · " ++ String.left 12 hash) ]
            , Html.div [ Attr.class "sel-page-status" ]
                [ Html.text "Read-only snapshot — changes here never touch the live session." ]
            , case version of
                Just _ ->
                    Html.div [ Attr.class "version-body" ]
                        (List.map viewVersionMsg msgs ++ planLines)

                Nothing ->
                    Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading version…" ]
            ]
        ]


viewVersionMsg : T.Message -> Html Msg
viewVersionMsg m =
    Html.div [ Attr.class "version-msg" ]
        [ Html.span [ Attr.class "version-msg-role" ] [ Html.text (T.roleToString m.role) ]
        , Html.span [ Attr.class "version-msg-content" ] [ Html.text m.content ]
        ]


-- PLAN MODE VIEWS

-- PLAN MODE VIEWS

{-| A plan window: draggable/resizable like a session window, owns its
run state. Multiple plans can be open at once; the global menu lists
them all.
-}
viewPlanPanel : Model -> String -> Html Msg
viewPlanPanel model planId =
    case Dict.get planId model.planWindows of
        Just win ->
            let
                isActive =
                    model.planActiveId == Just planId

                winPos =
                    Dict.get planId model.windowPositions

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

                pv =
                    win.view

                runStates =
                    win.run
                        |> Maybe.map .nodes
                        |> Maybe.withDefault Dict.empty

                -- Clicking a node opens its session (activating it if
                -- alive, resuming it from disk if it was closed); nodes
                -- without a session fall back to the detail panel.
                nodeClick nodeId =
                    PlanOpenNodeSession planId nodeId

                planName =
                    pv.plan |> Maybe.map .name |> Maybe.withDefault planId
            in
            Html.div
                ([ Attr.class
                    ("session-panel plan-panel"
                        ++ (if isActive then " session-panel-active" else "")
                    )
                 , Attr.attribute "data-plan" planId
                 , Ev.onClick (PlanActivate planId)
                 -- stopPropagation so window mousedowns never reach the
                 -- canvas pan handler on main-content.
                 , Ev.stopPropagationOn "mousedown" (D.succeed ( PlanActivate planId, True ))
                 -- Right-clicking inside a window must not open the
                 -- global menu (the canvas context menu); keep the
                 -- browser's default menu for copy/paste etc.
                 , Ev.stopPropagationOn "contextmenu" (D.succeed ( NoOp, True ))
                 ]
                    ++ positionStyles
                )
                [ viewPlanResizeHandle planId NW
                , viewPlanResizeHandle planId N
                , viewPlanResizeHandle planId NE
                , viewPlanResizeHandle planId W
                , viewPlanResizeHandle planId E
                , viewPlanResizeHandle planId SW
                , viewPlanResizeHandle planId S
                , viewPlanResizeHandle planId SE
                , Html.div
                    [ Attr.class "session-bar plan-bar"
                    , Attr.title "Drag to move"
                    ]
                    [ Html.span [ Attr.class "session-bar-title" ]
                        [ Html.span
                            [ Attr.class ("plan-run-dot plan-run-dot-" ++ runStatusClassOf win)
                            , Attr.title (runStatusLabelOf win)
                            ]
                            []
                        , Html.text ("Plan — " ++ planName)
                        ]
                    , Html.button
                        [ Attr.class "plan-bar-info-btn"
                        , Ev.stopPropagationOn "mousedown" (D.succeed ( NoOp, True ))
                        , Ev.stopPropagationOn "click" (D.succeed ( PlanToggleInfo, True ))
                        , Attr.title "Plan description (goal, tasks, run log)"
                        ]
                        [ Html.text "?" ]
                    , Html.button
                        [ Attr.class "session-bar-close"
                        , Ev.stopPropagationOn "mousedown" (D.succeed ( NoOp, True ))
                        , Ev.stopPropagationOn "click" (D.succeed ( PlanClose planId, True ))
                        , Attr.title "Close plan window"
                        ]
                        [ Html.text "✕" ]
                    ]
                , Html.div [ Attr.class "plan-panel-body" ]
                    [ case pv.errors of
                        err :: _ ->
                            Html.div [ Attr.class "plan-error-banner" ]
                                [ Html.text (String.join "\n" pv.errors) ]

                        [] ->
                            Html.text ""
                    , case pv.plan of
                        Just plan ->
                            Html.div [ Attr.class "plan-page" ]
                                [ Html.div [ Attr.class "plan-page-canvas" ]
                                    [ Plan.View.viewDag nodeClick runStates plan ]
                                , viewPlanRunStrip win
                                , if win.infoOpen then
                                    viewPlanInfoWindow planId win plan

                                  else
                                    Html.text ""
                                ]

                        Nothing ->
                            Html.text ""
                    ]
                ]

        Nothing ->
            Html.text ""


viewPlanResizeHandle : String -> ResizeHandle -> Html Msg
viewPlanResizeHandle planId handle =
    let
        className =
            "resize-handle resize-handle-" ++ resizeHandleString handle
    in
    Html.div
        [ Attr.class className
        , Attr.attribute "data-handle" (resizeHandleString handle)
        ]
        []


runStatusClassOf : PlanWindow -> String
runStatusClassOf win =
    case win.run |> Maybe.map .status of
        Just st ->
            runStatusClass st

        Nothing ->
            "idle"


runStatusLabelOf : PlanWindow -> String
runStatusLabelOf win =
    case win.run |> Maybe.map .status of
        Just st ->
            runStatusLabel st

        Nothing ->
            "Not started"


{-| P37: the run controls are a compact semi-transparent strip overlaid
on the canvas top-right. Only the buttons valid for the current run
state are rendered (no disabled buttons, consumes no layout height).
-}
viewPlanRunStrip : PlanWindow -> Html Msg
viewPlanRunStrip win =
    let
        runStatus =
            win.run |> Maybe.map .status

        canRun =
            runStatus == Nothing || List.member runStatus [ Just PT.NotStarted, Just PT.Completed, Just PT.FailedRun, Just PT.Stopped ]

        canPause =
            runStatus == Just PT.InProgress

        canResume =
            runStatus == Just PT.Paused

        canStop =
            runStatus == Just PT.InProgress || runStatus == Just PT.Paused

        canLoadRun =
            win.view.path /= Nothing
                && (runStatus == Nothing || List.member runStatus [ Just PT.Completed, Just PT.FailedRun, Just PT.Stopped, Just PT.NotStarted ])

        buttons =
            List.filterMap identity
                [ if canRun then
                    Just (stripBtn "Run" PlanRunStart "Run all tasks")

                  else
                    Nothing
                , if canPause then
                    Just (stripBtn "Pause" PlanRunPause "Pause launching new tasks")

                  else
                    Nothing
                , if canResume then
                    Just (stripBtn "Resume" PlanRunResume "Resume a paused run")

                  else
                    Nothing
                , if canStop then
                    Just (stripBtn "Stop" PlanRunStop "Stop all running tasks")

                  else
                    Nothing
                , if canLoadRun then
                    Just (stripBtn "Load run" PlanResume "Load the saved run state and continue unfinished tasks")

                  else
                    Nothing
                ]
    in
    if List.isEmpty buttons then
        Html.text ""

    else
        Html.div [ Attr.class "plan-run-strip" ] buttons


stripBtn : String -> Msg -> String -> Html Msg
stripBtn label msg tip =
    Html.button
        [ Attr.class "plan-strip-btn"
        , Ev.onClick msg
        , Attr.title tip
        ]
        [ Html.text label ]


runStatusLabel : PT.RunStatus -> String
runStatusLabel st =
    case st of
        PT.NotStarted ->
            "Not started"

        PT.InProgress ->
            "Running…"

        PT.Paused ->
            "Paused"

        PT.Completed ->
            "Completed"

        PT.FailedRun ->
            "Failed"

        PT.Stopped ->
            "Stopped"


runStatusClass : PT.RunStatus -> String
runStatusClass st =
    case st of
        PT.NotStarted ->
            "idle"

        PT.InProgress ->
            "running"

        PT.Paused ->
            "paused"

        PT.Completed ->
            "completed"

        PT.FailedRun ->
            "failed"

        PT.Stopped ->
            "stopped"


{-| P37: the floating info window — all plan text lives here. Plan tab
(open with the "?" button) = goal + full task list + run log + saved
path; Node tab (clicking a node without a session) = that node's
prompt / dependencies / failures / output / attempt sessions / Retry.
-}
viewPlanInfoWindow : String -> PlanWindow -> PT.Plan -> Html Msg
viewPlanInfoWindow planId win plan =
    let
        tabTitle =
            case win.selectedNode of
                Just nodeId ->
                    "Node " ++ nodeId

                Nothing ->
                    "Plan info"
    in
    Html.div [ Attr.class "plan-info" ]
        [ Html.div [ Attr.class "plan-info-head" ]
            [ Html.span [ Attr.class "plan-info-title" ] [ Html.text tabTitle ]
            , Html.button
                [ Attr.class "plan-info-close"
                , Ev.onClick PlanCloseInfo
                , Attr.title "Close"
                ]
                [ Html.text "✕" ]
            ]
        , Html.div [ Attr.class "plan-info-body" ]
            [ case win.selectedNode of
                Just nodeId ->
                    case List.filter (\t -> t.id == nodeId) plan.tasks |> List.head of
                        Just t ->
                            viewPlanNodeInfo planId win t

                        Nothing ->
                            viewPlanOverview win plan

                Nothing ->
                    viewPlanOverview win plan
            ]
        ]


{-| Plan tab: goal, the full task list, run log, saved path. -}
viewPlanOverview : PlanWindow -> PT.Plan -> Html Msg
viewPlanOverview win plan =
    Html.div [ Attr.class "plan-info-overview" ]
        [ Html.div [ Attr.class "plan-node-detail-label" ] [ Html.text "Goal" ]
        , Html.div [ Attr.class "plan-info-goal" ]
            [ Html.text (if plan.goal == "" then "(no goal)" else plan.goal) ]
        , Html.div [ Attr.class "plan-node-detail-label" ]
            [ Html.text ("Tasks (" ++ String.fromInt (List.length plan.tasks) ++ ")") ]
        , Html.div [ Attr.class "plan-info-tasks" ]
            (List.map (\t -> viewPlanTaskInfo win t) plan.tasks)
        , viewPlanRunLog win
        , case win.view.path of
            Just p ->
                Html.div [ Attr.class "plan-info-path" ]
                    [ Html.text ("Saved: " ++ p) ]

            Nothing ->
                Html.text ""
        ]


viewPlanTaskInfo : PlanWindow -> PT.TaskNode -> Html Msg
viewPlanTaskInfo win t =
    let
        nodeOutput =
            win.run
                |> Maybe.andThen (\run -> Dict.get t.id run.nodes)
                |> Maybe.andThen .output

        deps =
            if List.isEmpty t.dependsOn then
                "—"

            else
                String.join ", " t.dependsOn
    in
    Html.div [ Attr.class "plan-info-task" ]
        [ Html.div [ Attr.class "plan-node-detail-head" ]
            [ Html.span [ Attr.class "plan-task-id" ] [ Html.text t.id ]
            , Html.span [ Attr.class "plan-task-title" ] [ Html.text t.title ]
            ]
        , Html.div [ Attr.class "plan-node-detail-row" ]
            [ Html.text ("depends on: " ++ deps ++ " · preset: " ++ Maybe.withDefault "default" t.preset ++ " · max attempts: " ++ String.fromInt t.maxAttempts) ]
        , Html.div [ Attr.class "plan-info-task-prompt" ] [ Html.text t.prompt ]
        , case nodeOutput of
            Just out ->
                Html.div []
                    [ Html.div [ Attr.class "plan-node-detail-label" ] [ Html.text "Output" ]
                    , Html.div [ Attr.class "plan-node-detail-output" ] [ Html.text out ]
                    ]

            Nothing ->
                Html.text ""
        ]


viewPlanNodeInfo : String -> PlanWindow -> PT.TaskNode -> Html Msg
viewPlanNodeInfo planId win t =
    let
        nodeId =
            t.id

        nodeStatus =
            win.run
                |> Maybe.andThen (\run -> Dict.get nodeId run.nodes)
                |> Maybe.map .status

        canRetry =
            case nodeStatus of
                Just st ->
                    List.member st [ PT.Failed, PT.Canceled, PT.Waiting ]

                Nothing ->
                    False

        retryLabel =
            case nodeStatus of
                Just PT.Waiting ->
                    "Retry now"

                _ ->
                    "Retry node"

        failures =
            win.run
                |> Maybe.andThen (\run -> Dict.get nodeId run.nodes)
                |> Maybe.map .failures
                |> Maybe.withDefault []

        attemptSessions =
            win.run
                |> Maybe.andThen (\run -> Dict.get nodeId run.nodes)
                |> Maybe.map .attemptSessions
                |> Maybe.withDefault []

        nodeOutput =
            win.run
                |> Maybe.andThen (\run -> Dict.get nodeId run.nodes)
                |> Maybe.andThen .output
    in
    Html.div [ Attr.class "plan-node-detail" ]
        [ Html.div [ Attr.class "plan-node-detail-head" ]
            [ Html.span [ Attr.class "plan-task-id" ] [ Html.text t.id ]
            , Html.span [ Attr.class "plan-task-title" ] [ Html.text t.title ]
            , case nodeStatus of
                Just st ->
                    Html.span [ Attr.class ("plan-node-detail-status plan-node-detail-status-" ++ statusClassFor st) ]
                        [ Html.text (statusLabelFor st) ]

                Nothing ->
                    Html.text ""
            ]
        , Html.div [ Attr.class "plan-node-detail-row" ]
            [ Html.text ("preset: " ++ Maybe.withDefault "default" t.preset) ]
        , Html.div [ Attr.class "plan-node-detail-row" ]
            [ Html.text ("max attempts: " ++ String.fromInt t.maxAttempts) ]
        , Html.div [ Attr.class "plan-node-detail-row" ]
            [ Html.text
                ("depends on: "
                    ++ (if List.isEmpty t.dependsOn then
                            "—"

                        else
                            String.join ", " t.dependsOn
                       )
                )
            ]
        , if List.isEmpty failures then
            Html.text ""

          else
            Html.div [ Attr.class "plan-node-detail-failures" ]
                (List.map
                    (\f ->
                        Html.div [ Attr.class "plan-node-detail-failure" ]
                            [ Html.text ("Attempt " ++ String.fromInt f.attempt ++ " failed: " ++ f.reason) ]
                    )
                    (List.reverse failures)
                )
        , if List.isEmpty attemptSessions then
            Html.text ""

          else
            Html.div [ Attr.class "plan-node-detail-attempts" ]
                [ Html.div [ Attr.class "plan-node-detail-label" ]
                    [ Html.text ("History sessions (" ++ String.fromInt (List.length attemptSessions) ++ ")") ]
                , Html.div [ Attr.class "plan-node-detail-attempt-row" ]
                    (List.map
                        (\sid ->
                            Html.button
                                [ Attr.class "plan-node-detail-attempt"
                                , Attr.title ("Open session " ++ sid)
                                , Ev.onClick (PlanOpenAttemptSession planId nodeId sid)
                                ]
                                [ Html.text (shortSessionId sid) ]
                        )
                        attemptSessions
                    )
                ]
        , Html.div []
            [ Html.div [ Attr.class "plan-node-detail-label" ] [ Html.text "Output" ]
            , Html.div [ Attr.class "plan-node-detail-output" ]
                [ Html.text (Maybe.withDefault "(no output recorded)" nodeOutput) ]
            ]
        , Html.div [ Attr.class "plan-node-detail-label" ] [ Html.text "Prompt" ]
        , Html.div [ Attr.class "plan-node-detail-prompt" ] [ Html.text t.prompt ]
        , Html.button
            [ Attr.class "confirm-page-btn"
            , Attr.disabled (not canRetry)
            , Ev.onClick (PlanRunRetryNode nodeId)
            ]
            [ Html.text retryLabel ]
        ]


statusClassFor : PT.NodeStatus -> String
statusClassFor st =
    case st of
        PT.Pending -> "pending"
        PT.Starting -> "starting"
        PT.Running -> "running"
        PT.Waiting -> "waiting"
        PT.Succeeded -> "succeeded"
        PT.Failed -> "failed"
        PT.Blocked -> "blocked"
        PT.Canceled -> "canceled"
        PT.WaitingForPlan -> "waiting-for-plan"


statusLabelFor : PT.NodeStatus -> String
statusLabelFor st =
    case st of
        PT.Pending -> "Pending"
        PT.Starting -> "Starting…"
        PT.Running -> "Running…"
        PT.Waiting -> "Retrying…"
        PT.Succeeded -> "Succeeded"
        PT.Failed -> "Failed"
        PT.Blocked -> "Blocked"
        PT.Canceled -> "Canceled"
        PT.WaitingForPlan -> "Waiting for plan…"


{-| Compact display of a session id (UUID): first 8 chars + ellipsis. -}
shortSessionId : String -> String
shortSessionId sid =
    if String.length sid > 11 then
        String.left 8 sid ++ "…"

    else
        sid


viewPlanRunLog : PlanWindow -> Html Msg
viewPlanRunLog win =
    if List.isEmpty win.runLog then
        Html.text ""

    else
        Html.div [ Attr.class "plan-run-log" ]
            [ Html.div [ Attr.class "plan-run-log-title" ] [ Html.text "Run log" ]
            , Html.div [ Attr.class "plan-run-log-lines" ]
                (List.map
                    (\l -> Html.div [ Attr.class "plan-run-log-line" ] [ Html.text l ])
                    (List.reverse (List.take 15 win.runLog))
                )
            ]


{-| P38: re-run impact-scope confirmation (§7.4.2) — shown before a Run
click that would truncate parent sessions and cascade upward. One
authorization covers the whole chain (no per-level dialogs).
-}
viewPlanCascadeOverlay : Model -> Html Msg
viewPlanCascadeOverlay model =
    case model.planCascadePreview of
        Nothing ->
            Html.text ""

        Just scope ->
            let
                totalUser =
                    scope.rootUserMessages
                        + List.sum (List.map .truncateUserMessages scope.levels)
            in
            viewOverlay PlanCascadeCancel
                [ Html.div [ Attr.class "cascade-page" ]
                    [ Html.div [ Attr.class "sel-page-title" ]
                        [ Html.text ("Re-run affects " ++ String.fromInt (1 + List.length scope.levels) ++ " plan(s)") ]
                    , Html.div [ Attr.class "cascade-scope" ]
                        [ viewCascadeChain scope ]
                    , Html.div [ Attr.class "cascade-warning" ]
                        [ Html.text ("Re-running will truncate the parent session's old results and everything after them (including your " ++ String.fromInt totalUser ++ " message(s))") ]
                    , Html.div [ Attr.class "cascade-warning-sub" ]
                        [ Html.text "New results are inserted into this session and the cascade propagates upward; ancestor nodes will re-answer and re-run their downstream branches." ]
                    , if List.isEmpty scope.closePlanIds then
                        Html.text ""

                      else
                        Html.div [ Attr.class "cascade-close-plans" ]
                            [ Html.text ("Child plans to close: " ++ String.join ", " scope.closePlanIds) ]
                    , Html.div [ Attr.class "sel-page-input-row" ]
                        [ Html.button
                            [ Attr.class "confirm-page-btn confirm-page-btn-allow"
                            , Ev.onClick PlanCascadeConfirm
                            ]
                            [ Html.text "Re-run" ]
                        , Html.button
                            [ Attr.class "confirm-page-btn"
                            , Ev.onClick PlanCascadeCancel
                            ]
                            [ Html.text "Cancel" ]
                        ]
                    ]
                ]


viewCascadeChain : PC.ImpactScope -> Html Msg
viewCascadeChain scope =
    let
        rootPart =
            scope.rootPlanName ++ " (re-run)"

        levelPart lvl =
            lvl.planName
                ++ " (partial: "
                ++ (if List.isEmpty lvl.branchNodes then
                        "affected branch"

                    else
                        String.join ", " lvl.branchNodes
                   )
                ++ ")"

        topPart =
            case scope.topSessionId of
                Just _ ->
                    "top session"

                Nothing ->
                    "…"
    in
    Html.div [ Attr.class "cascade-chain" ]
        [ Html.text (String.join "  →  " (rootPart :: List.map levelPart scope.levels ++ [ topPart ])) ]


viewChatArea : Model -> T.SessionState -> Html Msg
viewChatArea model session =
    let
        hasMessages =
            not (List.isEmpty session.messages)
    in
    Html.div
        [ Attr.class "chat-area" ]
        [ if hasMessages then
            Html.div
                [ Attr.class "messages"
                , Attr.attribute "data-session" session.id
                ]
                (viewMessages model session

                    ++ [ Html.div [] [] ]
                )

          else
            Html.text ""
        , viewInputBar model session
        , viewConfirmOverlay session.id session
        , viewMcpInitOverlay session.id session
        , viewFilePickerOverlay session.id session
        , viewModelSelectorOverlay session.id session
        , viewMediaPreviewOverlay session.id session
        ]


{-| Render the message list, threading the session's plan index: every
message whose content is a detected plan message (same predicate as the
auto-create detector) bumps the index, and the status bar looks up the
binding by (sessionId, planIndex) — the order of plan messages in a
session is stable, unlike message ids.
-}
viewMessages : Model -> T.SessionState -> List (Html Msg)
viewMessages model session =
    let
        step msg ( idx, acc ) =
            let
                isPlan =
                    Plan.Detect.isPlanMessage msg.content

                idx2 =
                    if isPlan then
                        idx + 1

                    else
                        idx

                -- Only plan messages look up a binding (0 never matches).
                msgIdx =
                    if isPlan then
                        idx2

                    else
                        0
            in
            ( idx2, viewMessage model session msgIdx msg :: acc )
    in
    List.foldl step ( 0, [] ) session.messages
        |> Tuple.second
        |> List.reverse


viewMessage : Model -> T.SessionState -> Int -> T.Message -> Html Msg
viewMessage model session planIndex msg =
    let
        isCursor =
            case model.cursorMsgId of
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
            (viewMsgHeader session msg collapsed)
        , if collapsed then
            Html.text ""

          else
            -- The body box lives UNDER the title row: the header is a
            -- standalone row above the bordered window, not a title bar
            -- embedded in it. The plan status bar stays inside the box,
            -- directly below the body (same position as before).
            Html.div [ Attr.class "msg-window" ]
                [ viewMsgBody model session.id msg
                , viewPlanStatusBar model session.id planIndex
                ]
        ]


{-| Whether the session directory is currently open (under C2b/C3
windows are keyed by Session.id — checking sessions is enough).
-}
isSessionDirActive : Model -> String -> Bool
isSessionDirActive model dirId =
    Dict.member dirId model.sessions


pad : Int -> String
pad n =
    if n < 10 then
        "0" ++ String.fromInt n

    else
        String.fromInt n


monthNum : Time.Month -> Int
monthNum m =
    case m of
        Time.Jan -> 1
        Time.Feb -> 2
        Time.Mar -> 3
        Time.Apr -> 4
        Time.May -> 5
        Time.Jun -> 6
        Time.Jul -> 7
        Time.Aug -> 8
        Time.Sep -> 9
        Time.Oct -> 10
        Time.Nov -> 11
        Time.Dec -> 12


{-| Format a Unix-seconds timestamp (as returned by list_session_dirs) as
"YYYY-MM-DD HH:mm" in UTC.
-}
formatEpoch : String -> String
formatEpoch s =
    case String.toInt s of
        Just sec ->
            let
                p =
                    Time.millisToPosix (sec * 1000)
            in
            String.fromInt (Time.toYear Time.utc p)
                ++ "-"
                ++ pad (monthNum (Time.toMonth Time.utc p))
                ++ "-"
                ++ pad (Time.toDay Time.utc p)
                ++ " "
                ++ pad (Time.toHour Time.utc p)
                ++ ":"
                ++ pad (Time.toMinute Time.utc p)

        Nothing ->
            ""


{-| R3: the plan status bar under the assistant message that auto-created
a plan — bound via meta.json origin (sessionId + planIndex → planId).
Shows the plan name + run status; [Open] focuses the window (or opens
from disk after a restart). Failed/Stopped plans show the status too;
the [Re-run] action arrives with the R4 re-run cascade.
-}
viewPlanStatusBar : Model -> String -> Int -> Html Msg
viewPlanStatusBar model sid planIndex =
    case planMetaForMessage model sid planIndex of
        Just ( planId, meta ) ->
            let
                -- The real display name comes from the plan's meta
                -- (snapshotted at creation) — not the planId, which is
                -- slugified and timestamped and would duplicate itself
                -- in the [Plan: …] prefix.
                name =
                    meta.name

                ( statusLabel, statusClass, canRestart ) =
                    planStatusFor model sid planId (Just meta)
            in
            Html.div [ Attr.class "plan-offer" ]
                [ Html.button
                    [ Attr.class ("plan-offer-btn plan-status-" ++ statusClass)
                    , Ev.onClick (PlanStatusOpen planId)
                    , Attr.title ("Open plan " ++ planId)
                    ]
                    [ Html.text ("[Plan: " ++ planId ++ "] " ++ name ++ " · " ++ statusLabel) ]
                , if canRestart then
                    Html.button
                        [ Attr.class "plan-offer-btn plan-restart-btn"
                        , Ev.onClick (PlanRunRestart planId)
                        , Attr.title "Re-run: skip succeeded nodes, rerun unfinished nodes (including sub-plans)"
                        ]
                        [ Html.text "Re-run" ]

                  else
                    Html.text ""
                ]

        Nothing ->
            -- The plan message was detected but NOT auto-created (the
            -- delayed auto-open suppressed it because the message was not
            -- the session's last one — history replay, follow-up message).
            -- Give the user a manual open entry (R6).
            if planIndex > 0 then
                Html.div [ Attr.class "plan-offer" ]
                    [ Html.button
                        [ Attr.class "plan-offer-btn plan-open-btn"
                        , Ev.onClick (PlanOpenFromMessage sid planIndex)
                        , Attr.title "Open the plan from this message"
                        ]
                        [ Html.text "Open plan" ]
                    ]

            else
                Html.text ""


{-| The plan whose meta binds (sessionId, planIndex) — status-bar lookup.
All logic lives in Plan.Update.planMetaForMessage (one binding rule,
resume + fork aware, unit-tested); the View only renders.
-}
planMetaForMessage : Model -> String -> Int -> Maybe ( String, PM.PlanMeta )
planMetaForMessage =
    PU.planMetaForMessage


planStatusFor : Model -> String -> String -> Maybe PM.PlanMeta -> ( String, String, Bool )
planStatusFor model sid planId meta =
    -- C architecture: the session-version view takes priority — the same
    -- plan can have different states across session versions (an old
    -- session sees the old state; this is the fix for the "old session A
    -- shows executed" bug).
    case PU.versionPlanStatus model sid planId of
        Just statusStr ->
            case PT.runStatusFromString statusStr of
                Just st ->
                    runStatusView st

                Nothing ->
                    ( "Open", "created", False )

        Nothing ->
            case Dict.get planId model.planWindows of
                Just win ->
                    case win.run of
                        Just run ->
                            runStatusView run.status

                        Nothing ->
                            runStatusView PT.NotStarted

                Nothing ->
                    -- Window closed (auto-close on completion, or never opened):
                    -- fall back to the last known run status kept in memory, then
                    -- to the status persisted in meta.json (survives restarts).
                    case Dict.get planId model.planRunStatuses of
                        Just st ->
                            runStatusView st

                        Nothing ->
                            case meta of
                                Just m ->
                                    case PT.runStatusFromString m.lastStatus of
                                        Just st ->
                                            runStatusView st

                                        Nothing ->
                                            ( "Open", "created", False )

                                Nothing ->
                                    ( "Open", "created", False )


{-| The (label, css-class, can-restart) triple for a run status — used by
the status bar whether the status comes from a live window, the in-memory
cache or the meta.json snapshot.
-}
runStatusView : PT.RunStatus -> ( String, String, Bool )
runStatusView st =
    case st of
        PT.NotStarted -> ( "Created", "created", False )
        PT.InProgress -> ( "Running…", "running", False )
        PT.Paused -> ( "Paused", "paused", True )
        PT.Completed -> ( "Completed", "completed", False )
        PT.FailedRun -> ( "Failed", "failed", True )
        PT.Stopped -> ( "Stopped", "stopped", True )


-- Header row of a message: chevron + role label, optional tool info, and
-- a one-line preview when collapsed. Renders ABOVE the body box (see
-- viewMessage). The whole row toggles on click. The chevron shows both
-- states — right (>) while collapsed, rotated 90° (down, V) while
-- expanded — via CSS (.message:not(.collapsed) .msg-chevron).
viewMsgHeader : T.SessionState -> T.Message -> Bool -> List (Html Msg)
viewMsgHeader session msg collapsed =
    [ Html.span [ Attr.class "msg-chevron" ]
        [ Icons.chevron ]
    , Html.span [ Attr.class "msg-label" ]
        [ Html.text (String.toUpper (T.roleToString msg.role)) ]
    , case msg.role of
        T.Tool ->
            Html.span [ Attr.class "msg-tool-info" ]
                [ Html.span [ Attr.class "msg-name" ]
                    [ Html.text (Maybe.withDefault "" msg.toolName) ]
                , Html.span [ Attr.class "msg-status" ]
                    [ toolStatus session msg ]
                ]

        _ ->
            Html.text ""
    , if collapsed then
        -- One-line preview for every collapsed message. Tool windows are
        -- collapsed by default, so this is how streamed tool input (Af
        -- deltas) surfaces while the window is folded — the preview shows
        -- the accumulating delta text, truncated to one line.
        previewHtml msg

      else
        Html.text ""
    ]


{-| Preview span for the collapsed header. Stays populated even when the
preview text is empty: under `align-items: baseline` an empty flex child
has no baseline and aligns by its bottom edge instead, so the header
jumps vertically while streamed deltas toggle the preview between empty
and non-empty. A non-breaking space keeps a real baseline and a stable
height.
-}
previewHtml : T.Message -> Html Msg
previewHtml msg =
    let
        p =
            previewText msg
    in
    Html.span [ Attr.class "msg-preview" ]
        [ Html.text (if String.isEmpty p then "\u{00A0}" else p) ]


-- Tool state icon derived from the tool call lifecycle: ✓ done,
-- ⟳ running (input streaming / preview), ✗ error (UF error).
-- Chunky SVG icons (Icons.check / Icons.running / Icons.cross) in the
-- same style as the other UI icons; the semantic color comes from the
-- CSS classes (msg-status-icon icon-*).
toolStatus : T.SessionState -> T.Message -> Html Msg
toolStatus session msg =
    if msg.isError then
        Html.span [ Attr.class "msg-status-icon icon-cross" ]
            [ Icons.cross ]

    else
        case Dict.get (Maybe.withDefault "" msg.toolId) session.toolCalls of
            Just tc ->
                if tc.output /= Nothing || tc.accumulatedDelta /= Nothing || tc.inputReceived then
                    Html.span [ Attr.class "msg-status-icon icon-running" ]
                        [ Icons.running ]

                else
                    Html.span [ Attr.class "msg-status-icon icon-check" ]
                        [ Icons.check ]

            Nothing ->
                Html.span [ Attr.class "msg-status-icon icon-check" ]
                    [ Icons.check ]


-- One-line preview used by the collapsed header. Collapsed and expanded
-- views treat streaming deltas differently:
--   * expanded: the FULL accumulated content is rendered;
--   * collapsed: the LAST line is shown, so newly streamed deltas (which
--     are appended to the tail of multi-line reasoning/assistant text)
--     surface in the preview and the user can tell data is arriving.
-- Tool deltas are single-line JSON, so last-line == first-line there.
-- Truncated to 80 chars with an ellipsis.
previewText : T.Message -> String
previewText msg =
    let
        last =
            case List.reverse (String.lines msg.content) |> List.head of
                Just l ->
                    String.trim l

                Nothing ->
                    ""
    in
    if String.isEmpty last then
        ""

    else if String.length last > 80 then
        String.left 80 last ++ "…"

    else
        last


viewMsgBody : Model -> String -> T.Message -> Html Msg
viewMsgBody model sid msg =
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
            -- Per-tool rendering (Session/ToolView.elm): edit_file shows a
            -- red/green diff, write_file a green new-file block,
            -- execute_command a terminal block, unknown tools fall back to
            -- pretty-printed JSON. The output stays plain text. The tool
            -- input lives in session.toolCalls (in-memory), looked up by
            -- msg.toolId; while the input is streaming (Af) the call may be
            -- missing, in which case the body falls back to plain text.
            let
                session =
                    Dict.get sid model.sessions

                toolCall =
                    case ( session, msg.toolId ) of
                        ( Just s, Just tid ) ->
                            Dict.get tid s.toolCalls

                        _ ->
                            Nothing
            in
            Html.div [ Attr.class "msg-body" ]
                [ ToolView.viewToolCall toolCall msg ]

        T.User ->
            Html.div [ Attr.class "msg-body" ]
                [ case msg.media of
                    Just items ->
                        Html.div [ Attr.class "hs-staged-row" ]
                            (List.map (viewMessageMedia sid) items)

                    Nothing ->
                        Html.text ""
                , Html.div [ Attr.class "message-content" ]
                    (viewTextWithPlanLinks model msg.content)
                ]

        T.System ->
            Html.div [ Attr.class "msg-body" ]
                [ Html.div [ Attr.class "message-content" ]
                    (viewTextWithPlanLinks model msg.content)
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


{-| Render text with `[Plan: <planId>]` markers as clickable buttons —
the second entry point into a plan (the first is the status bar). Used
for feedback messages so the link survives restarts (it lives in the
message text, which persists in session.alaya).
-}
viewTextWithPlanLinks : Model -> String -> List (Html Msg)
viewTextWithPlanLinks model text =
    let
        go rest acc =
            case String.indexes "[Plan: " rest |> List.head of
                Nothing ->
                    List.reverse (Html.text rest :: acc)

                Just idx ->
                    let
                        before =
                            String.left idx rest

                        after =
                            String.dropLeft (idx + 7) rest
                    in
                    case String.indexes "]" after |> List.head of
                        Nothing ->
                            List.reverse (Html.text rest :: acc)

                        Just endIdx ->
                            let
                                planId =
                                    String.left endIdx after

                                rest2 =
                                    String.dropLeft (endIdx + 1) after

                                link =
                                    Html.button
                                        [ Attr.class "plan-link"
                                        , Ev.onClick (PlanStatusOpen planId)
                                        , Attr.title ("Open plan " ++ planId)
                                        ]
                                        [ Html.text ("[Plan: " ++ planId ++ "]") ]
                            in
                            go rest2 (link :: Html.text before :: acc)
    in
    go text []


-- ─── Reasoning Level ────────────────────────────────────────────────

reasoningLevelName : Int -> String
reasoningLevelName lvl =
    case lvl of
        0 -> "Off"
        1 -> "Balanced"
        2 -> "Deep"
        _ -> String.fromInt lvl


viewInputBar : Model -> T.SessionState -> Html Msg
viewInputBar model session =
    let
        hasMessages =
            not (List.isEmpty session.messages)

        hasStaged =
            not (List.isEmpty session.staged)

        -- P39/D8: while a plan of this conversation is RUNNING, the
        -- session input is disabled — the plan's result replaces
        -- everything after its plan JSON, so a message typed mid-run
        -- would be truncated away by the completion.
        planBlocking =
            PU.planRunningForSession model session.id

        -- Voice input also locks the textarea: while recording (ASR or
        -- raw audio) and while the ASR result is still in flight (the
        -- mic button turns into a cancel so the user can abandon the
        -- transcription).
        inputDisabled =
            not session.connected || planBlocking || session.voiceActive || session.asrBusy || session.rawRecording

        -- The capture buttons must stay clickable whenever the session
        -- is usable — during their own recording (to stop) and during
        -- transcription (to cancel) — but raw recording locks the ASR
        -- mic (mutual exclusion) and vice versa.
        micLocked =
            not session.connected || planBlocking || session.rawRecording

        rawLocked =
            not session.connected || planBlocking || session.voiceActive || session.asrBusy

        inputClass =
            "session-input-bar" ++ (if not hasMessages then " session-input-bar-centered" else "")
    in
    Html.div [ Attr.class inputClass ]
        [ Html.div [ Attr.class "input-container" ]
            [ Html.div
                [ Attr.class
                    ("message message-user input-bubble"
                        ++ (if inputDisabled then " input-disabled" else "")
                    )
                ]
                [ if hasStaged then
                    Html.div [ Attr.class "hs-staged-row" ]
                        (List.map (viewStagedChip session.id) session.staged)

                  else
                    Html.text ""
                , Html.textarea
                    [ Attr.id ("msg-input-" ++ session.id)
                    , Attr.class "input-text"
                    , Attr.placeholder
                        (if planBlocking then
                            "Plan is running — input disabled until it completes…"

                         else
                            "Type a message… (drop files to attach)"
                        )
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
                    , Attr.disabled inputDisabled
                    , Attr.rows model.inputRows
                    ]
                    []
                ]
            , Html.div [ Attr.class "input-footer" ]
                [ Html.div [ Attr.class "input-footer-left" ]
                    [ Html.button
                        [ Attr.class "footer-btn"
                        , Ev.onClick (ForSession session.id OpenFilePicker)
                        , Attr.title "Attach media (or drop files onto the input)"
                        , Attr.disabled inputDisabled
                        ]
                        [ Icons.paperclip ]
                    , Html.button
                        [ Attr.class "footer-btn"
                        , Ev.onClick (ForSession session.id OpenModelSelector)
                        , Attr.title "Select model"
                        , Attr.disabled inputDisabled
                        ]
                        [ Icons.chip ]
                    , Html.span
                        [ Attr.class
                            ("reasoning-wrap"
                                ++ (if inputDisabled then " disabled" else "")
                            )
                        , Attr.title "Reasoning level: Off (0) | Balanced (1) | Deep (2)"
                        ]
                        [ Icons.bulb
                        , Html.select
                            [ Attr.class "reasoning-select"
                            , Attr.disabled inputDisabled
                            , Ev.onInput
                                (\v ->
                                    ForSession session.id
                                        (SetReasoningLevel (Maybe.withDefault 1 (String.toInt v)))
                                )
                            ]
                            (List.map
                                (\lvl ->
                                    Html.option
                                        [ Attr.value (String.fromInt lvl)
                                        , Attr.selected (session.reasoningLevel == lvl)
                                        ]
                                        [ Html.text (reasoningLevelName lvl) ]
                                )
                                [ 0, 1, 2 ]
                            )
                        ]
                    ]
                , Html.div [ Attr.class "input-footer-right" ]
                    [ Html.button
                        [ Attr.class
                            ("footer-btn mic-btn"
                                ++ (if session.voiceActive then " recording" else "")
                                ++ (if session.asrBusy then " cancel" else "")
                            )
                        , Ev.onClick
                            (if session.asrBusy then
                                ForSession session.id CancelAsr

                             else
                                ForSession session.id VoiceInput
                            )
                        , Attr.title
                            (if session.asrBusy then
                                "Cancel transcription (discard the result)"

                             else if session.voiceActive then
                                "Stop recording and transcribe"

                             else
                                "Voice input (record speech, insert at the cursor)"
                            )
                        , Attr.disabled micLocked
                        ]
                        [ if session.asrBusy then
                            Icons.stop

                          else
                            Icons.mic
                        ]
                    , Html.button
                        [ Attr.class
                            ("footer-btn raw-btn"
                                ++ (if session.rawRecording then " recording" else "")
                            )
                        , Ev.onClick (ForSession session.id RawAudioInput)
                        , Attr.title
                            (if session.rawRecording then
                                "Stop recording and send as audio"

                             else
                                "Record audio and send it to the model"
                            )
                        , Attr.disabled rawLocked
                        ]
                        [ Icons.audio ]
                    , Html.button
                        [ Attr.class
                            ("footer-btn send-btn"
                                ++ (if session.taskRunning then " cancel" else "")
                            )
                        , Ev.onClick
                            (if session.taskRunning then ForSession session.id CancelTask else ForSession session.id SendPrompt)
                        , Attr.title (if session.taskRunning then "Cancel task" else "Send")
                        , Attr.disabled inputDisabled
                        ]
                        [ if session.taskRunning then
                            Icons.stop

                          else
                            Icons.send
                        ]
                    ]
                ]
            ]
        ]


-- ─── Staged Media Chips ──────────────────────────────────────────────

viewStagedChip : String -> T.StagedMedia -> Html Msg
viewStagedChip sid item =
    Html.div
        [ Attr.class "hs-staged-chip"
        , Ev.onClick (ForSession sid (OpenMediaPreview { mediaType = item.mediaType, uri = item.uri, name = item.name }))
        , Attr.title "Click to preview"
        ]
        [ Html.span [ Attr.class "hs-staged-icon" ]
            [ Html.text (mediaTypeIcon item.mediaType) ]
        , Html.span [ Attr.class "hs-staged-name" ]
            [ Html.text (Maybe.withDefault (String.left 40 item.uri) item.name) ]
        , Html.button
            [ Attr.class "hs-staged-remove"
            , Ev.stopPropagationOn "click" (D.succeed ( ForSession sid (RemoveStaged item.id), True ))
            , Attr.title "Remove"
            ]
            [ Html.text "✕" ]
        ]


-- ─── Message Media Previews ─────────────────────────────────────────

viewMessageMedia : String -> T.MediaItem -> Html Msg
viewMessageMedia sid item =
    Html.div
        [ Attr.class "hs-staged-chip message-media-chip"
        , Ev.onClick (ForSession sid (OpenMediaPreview item))
        , Attr.title "Click to preview"
        ]
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
        , Attr.attribute "data-handle" (resizeHandleString handle)
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
                , pendingAuths = session.pendingMcpAuths
                , authRunning = session.mcpAuthRunning
                , onClose = CloseMcpAuthOverlay sid
                , onCancelAll = McpCancelAll sid
                , onAuthConfirm = \server -> McpAuthConfirm sid server
                , onAuthDeny = \s -> McpAuthDeny sid s
                , onFillUrl = \server url -> ForSession sid (FillMcpAuthUrl server url)
                }
            ]

    else
        Html.text ""


-- ─── File Picker Overlay ──────────────────────────────────────────────

viewFilePickerOverlay : String -> T.SessionState -> Html Msg
viewFilePickerOverlay sid session =
    if session.filePicker.show then
        viewOverlay (ForSession sid CloseFilePicker)
            [ Overlay.FilePicker.view
                { sessionId = sid
                , entries = FP.filterEntries session.filePicker
                , input = session.filePicker.input
                , filter = session.filePicker.filter
                , selected = session.filePicker.selected
                , mode = session.filePicker.mode
                , loading = session.filePicker.loading
                , title = "Attach Media"
                , placeholder = "Type a path or filter files…"
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
        , confirmOnClick = True
        , onActivate = Nothing
        , activateTitle = ""
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
        , onConfirm = \id -> ForSession sid (ModelSelectorConfirmItem id)
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
                    case ed.error of
                        Just err ->
                            Html.div []
                                [ Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                                    [ Html.text ("Failed to set default model: " ++ err) ]
                                , viewDefaultModelsList ed
                                ]

                        Nothing ->
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
        , currentLabel = "Preset / default: "
        , currentValue =
            let
                name =
                    List.filterMap
                        (\m ->
                            if ed.activeModelId == Just m.id then
                                Just m.name

                            else
                                Nothing
                        )
                        ed.state.working
                        |> List.head
                        |> Maybe.withDefault "—"
            in
            ed.preset ++ " · " ++ name
        , addTitle = "Add model"
        , itemId = \m -> m.id
        , itemTitle = \m -> m.name
        , itemSubtitle = \_ -> ""
        , isActive = \m -> ed.activeModelId == Just m.id
        , confirmOnClick = False
        , onActivate = Just DefaultModelsSetActive
        , activateTitle = "Make this the preset's default model (new sessions start on it)"
        , editTitle = \m ->
            if ed.activeModelId == Just m.id then
                "Default model cannot be edited"

            else
                "Edit model"
        , deleteTitle = \m ->
            if ed.activeModelId == Just m.id then
                "Default model cannot be deleted"

            else if List.length ed.state.working <= 1 then
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
        , confirmOnClick = False
        , onActivate = Nothing
        , activateTitle = ""
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
                , builtinTools = ed.builtinTools
                , systemPrompt = ed.systemPrompt
                , reasoningLevel = ed.reasoningLevel
                , loading = ed.loading
                , syncing = ed.syncing
                , error = ed.error
                , onInput = SetToolConfirm
                , onBuiltinToolsInput = SetBuiltinTools
                , onSystemPromptInput = SetSystemPrompt
                , onReasoningLevelInput = SetSettingsReasoningLevel
                , onSave = SettingsSave
                , onCancel = CloseSettingsEditor
                }
            ]
    else
        Html.text ""


viewGlobalConfigOverlay : Model -> Html Msg
viewGlobalConfigOverlay model =
    let
        ed =
            model.globalConfigEditor
    in
    if ed.show then
        viewOverlay CloseGlobalConfig
            [ Overlay.GlobalConfig.view
                { input = ed.input
                , loading = ed.loading
                , syncing = ed.syncing
                , error = ed.error
                , onInput = SetRecursionLimit
                , onSave = GlobalConfigSave
                , onCancel = CloseGlobalConfig
                }
            ]
    else
        Html.text ""


viewAsrConfigOverlay : Model -> Html Msg
viewAsrConfigOverlay model =
    let
        ed =
            model.asrConfigEditor

        row p =
            { id = p.id
            , name = p.name
            , protocol = p.protocol
            , url = p.url
            , isActive = p.id == model.asrConfig.active
            }
    in
    if ed.show then
        viewOverlay CloseAsrConfig
            [ Overlay.AsrConfig.view
                { inForm = ed.inForm
                , profiles = List.map row model.asrConfig.profiles
                , loading = ed.loading
                , syncing = ed.syncing
                , confirmDelete = ed.confirmDelete
                , error = ed.error
                , isNew = ed.editingId == Nothing
                , name = ed.name
                , protocol = ed.protocol
                , url = ed.url
                , apiKey = ed.apiKey
                , model = ed.model
                , language = ed.language
                , onAdd = AsrConfigAdd
                , onEdit = AsrConfigEdit
                , onSetActive = AsrConfigSetActive
                , onDelete = AsrConfigDelete
                , onDeleteConfirm = AsrConfigDeleteConfirm
                , onDeleteCancel = AsrConfigDeleteCancel
                , onClose = CloseAsrConfig
                , onName = SetAsrName
                , onProtocol = SetAsrProtocol
                , onUrl = SetAsrUrl
                , onApiKey = SetAsrApiKey
                , onModel = SetAsrModel
                , onLanguage = SetAsrLanguage
                , onSave = AsrConfigSave
                , onBack = AsrConfigBack
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
                , dragFrom = pm.dragFrom
                , dragOver = pm.dragOver
                , onDragStart = PresetDragStart
                , onDragOver = PresetDragOver
                , onDragEnd = PresetDragEnd
                , onDrop = PresetDrop
                }
            ]
    else
        Html.text ""


-- ─── Media Preview Overlay ──────────────────────────────────────────

viewMediaPreviewOverlay : String -> T.SessionState -> Html Msg
viewMediaPreviewOverlay sid session =
    case session.mediaPreview of
        Just item ->
            Overlay.MediaPreview.view
                { item = item
                , onClose = ForSession sid CloseMediaPreview
                , noOp = NoOp
                }

        Nothing ->
            Html.text ""


-- SVG icons
