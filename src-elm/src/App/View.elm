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
import App.Update exposing (SessionDir, decodeSessionDir, helpItems, nextCopyName)
import Session.Types as T
import Session.Selector as Sel exposing (Page(..))
import Session.FilePicker as FP
import Fuzzy
import Plan.Types as PT
import Plan.Meta as PM
import Plan.Detect
import Plan.View
import Overlay.ConfirmTool
import Overlay.Settings
import Overlay.PresetManager
import Overlay.McpInit
import Overlay.FilePicker
import Overlay.Selector
import Overlay.ModelEditor
import Overlay.McpEditor
import Overlay.MediaPreview
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
            (if List.isEmpty model.sessionOrder && List.isEmpty model.planOrder then
                [ viewNoSessionPanel model ]

             else
                List.map (\id -> viewSessionPanel model id) model.sessionOrder
                    ++ List.map (\pid -> viewPlanPanel model pid) model.planOrder
            )
        , viewGlobalMenu model
        , viewContextMenu model
        , viewSessionManagerOverlay model
        , viewPresetManagerOverlay model
        , viewDefaultModelsEditorOverlay model
        , viewMcpEditorOverlay model
        , viewSettingsEditorOverlay model
        , viewPlanManagerOverlay model
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
                 , Attr.attribute "data-session" id
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
            , Html.div
                [ Attr.class "global-menu-item"
                , Ev.onClick OpenPlanManager
                ]
                [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "🕸" ]
                , Html.text " Plans"
                ]
            , if List.isEmpty model.planOrder then
                Html.text ""

              else
                Html.div [ Attr.class "global-menu-plans" ]
                    (List.map (viewGlobalMenuPlan model) model.planOrder)
            ]
        , Html.button
            [ Attr.class "global-menu-btn"
            , Ev.onClick ToggleGlobalMenu
            , Attr.title "Menu"
            ]
            [ Html.text "⚙" ]
        ]


{-| One entry per open plan window in the global menu: clicking brings
that plan window to the front. Shows the plan name and run status.
-}
viewGlobalMenuPlan : Model -> String -> Html Msg
viewGlobalMenuPlan model planId =
    let
        win =
            Dict.get planId model.planWindows

        name =
            win
                |> Maybe.andThen (.view >> .plan)
                |> Maybe.map .name
                |> Maybe.withDefault planId

        runLabel =
            win
                |> Maybe.andThen .run
                |> Maybe.map (.status >> runStatusLabel)
                |> Maybe.withDefault ""

        isActive =
            model.planActiveId == Just planId
    in
    Html.div
        [ Attr.class
            ("global-menu-item global-menu-sub"
                ++ (if isActive then " global-menu-item-active" else "")
            )
        , Ev.onClick (PlanActivate planId)
        ]
        [ Html.span [ Attr.class "global-menu-icon" ] [ Html.text "🕸" ]
        , Html.text
            (if runLabel == "" then
                name

             else
                name ++ " — " ++ runLabel
            )
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
                , Html.div [ Attr.class "sel-page-status" ]
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
                                    [ Attr.class "confirm-page-btn confirm-page-btn-allow"
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
                 , Ev.on "mousedown" (D.succeed (PlanActivate planId))
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
                    , Ev.preventDefaultOn "mousedown"
                        (D.map2
                            (\clientX clientY ->
                                ( PlanWindowDragStart planId clientX clientY, True )
                            )
                            (D.field "clientX" D.float)
                            (D.field "clientY" D.float)
                        )
                    , Attr.title "Drag to move"
                    ]
                    [ Html.span [ Attr.class "session-bar-title" ]
                        [ Html.text ("Plan — " ++ planName) ]
                    , Html.button
                        [ Attr.class "session-bar-close"
                        , Ev.stopPropagationOn "mousedown" (D.succeed ( NoOp, True ))
                        , Ev.stopPropagationOn "click" (D.succeed ( PlanClose planId, True ))
                        , Attr.title "Close plan window"
                        ]
                        [ Html.text "✕" ]
                    ]
                , Html.div [ Attr.class "plan-panel-body" ]
                    [ Html.div [ Attr.class "plan-page" ]
                        [ case pv.errors of
                            err :: _ ->
                                Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                                    [ Html.text (String.join "\n" pv.errors) ]

                            [] ->
                                Html.text ""
                        , case pv.plan of
                            Just plan ->
                                Html.div [ Attr.class "plan-page-body" ]
                                    [ viewPlanHeader win plan
                                    , case pv.path of
                                        Just p ->
                                            Html.div [ Attr.class "plan-page-path" ]
                                                [ Html.text ("Saved: " ++ p) ]

                                        Nothing ->
                                            Html.text ""
                                    , Html.div [ Attr.class "plan-page-canvas" ]
                                        [ Plan.View.viewDag nodeClick runStates plan ]
                                    , viewPlanNodeDetail planId win plan
                                    , viewPlanRunLog win
                                    , viewPlanExport pv
                                    ]

                            Nothing ->
                                Html.text ""
                        ]
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
        , Ev.preventDefaultOn "mousedown"
            (D.map2
                (\clientX clientY ->
                    ( PlanResizeStart planId handle clientX clientY, True )
                )
                (D.field "clientX" D.float)
                (D.field "clientY" D.float)
            )
        ]
        []


viewPlanHeader : PlanWindow -> PT.Plan -> Html Msg
viewPlanHeader win plan =
    let
        runStatus =
            win.run |> Maybe.map .status

        runBadge =
            case runStatus of
                Just st ->
                    Html.span [ Attr.class ("plan-run-badge plan-run-badge-" ++ runStatusClass st) ]
                        [ Html.text (runStatusLabel st) ]

                Nothing ->
                    Html.text ""

        canRun =
            case runStatus of
                Nothing ->
                    True

                Just st ->
                    List.member st [ PT.NotStarted, PT.Completed, PT.FailedRun, PT.Stopped ]

        canPause =
            runStatus == Just PT.InProgress

        canResume =
            runStatus == Just PT.Paused

        canStop =
            runStatus == Just PT.InProgress || runStatus == Just PT.Paused

        canLoadRun =
            win.view.path /= Nothing
                && (runStatus == Nothing || runStatus == Just PT.Completed || runStatus == Just PT.FailedRun || runStatus == Just PT.Stopped || runStatus == Just PT.NotStarted)
    in
    Html.div [ Attr.class "plan-header" ]
        [ Html.div [ Attr.class "plan-header-text" ]
            [ Html.div [ Attr.class "plan-page-name" ] [ Html.text plan.name ]
            , runBadge
            ]
        , Html.div [ Attr.class "plan-header-meta-row" ]
            [ Html.div [ Attr.class "plan-page-goal" ]
                [ Html.text (if plan.goal == "" then "" else plan.goal) ]
            , Html.div [ Attr.class "plan-page-meta" ]
                [ Html.text
                    ("Concurrency: "
                        ++ String.fromInt plan.concurrency
                        ++ " · Max attempts: "
                        ++ String.fromInt plan.defaultMaxAttempts
                    )
                ]
            ]
        , Html.div [ Attr.class "plan-header-controls" ]
            [ Html.input
                [ Attr.class "plan-header-concurrency"
                , Attr.type_ "number"
                , Attr.min "1"
                , Attr.max "8"
                , Attr.placeholder "Concurrency"
                , Attr.title ("Concurrency 1-8 (empty = plan default " ++ String.fromInt plan.concurrency ++ ")")
                , Attr.value win.view.concurrencyInput
                , Ev.onInput PlanSetConcurrency
                ]
                []
            , Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-allow plan-header-btn"
                , Attr.disabled (not canRun)
                , Ev.onClick PlanRunStart
                , Attr.title "Run all tasks"
                ]
                [ Html.text "Run" ]
            , Html.button
                [ Attr.class "confirm-page-btn plan-header-btn"
                , Attr.disabled (not canPause)
                , Ev.onClick PlanRunPause
                , Attr.title "Pause launching new tasks"
                ]
                [ Html.text "Pause" ]
            , Html.button
                [ Attr.class "confirm-page-btn plan-header-btn"
                , Attr.disabled (not canResume)
                , Ev.onClick PlanRunResume
                , Attr.title "Resume a paused run"
                ]
                [ Html.text "Resume" ]
            , Html.button
                [ Attr.class "confirm-page-btn confirm-page-btn-deny plan-header-btn"
                , Attr.disabled (not canStop)
                , Ev.onClick PlanRunStop
                , Attr.title "Stop all running tasks"
                ]
                [ Html.text "Stop" ]
            , Html.button
                [ Attr.class "confirm-page-btn plan-header-btn"
                , Attr.disabled (not canLoadRun)
                , Ev.onClick PlanResume
                , Attr.title "Load the saved run state and continue unfinished tasks"
                ]
                [ Html.text "Load run" ]
            ]
        ]


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


viewPlanNodeDetail : String -> PlanWindow -> PT.Plan -> Html Msg
viewPlanNodeDetail planId win plan =
    case win.selectedNode of
        Just nodeId ->
            case List.filter (\t -> t.id == nodeId) plan.tasks |> List.head of
                Just t ->
                    let
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
                        , let
                            attemptSessions =
                                win.run
                                    |> Maybe.andThen (\run -> Dict.get nodeId run.nodes)
                                    |> Maybe.map .attemptSessions
                                    |> Maybe.withDefault []
                          in
                          if List.isEmpty attemptSessions then
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
                        , let
                            nodeOutput =
                                win.run
                                    |> Maybe.andThen (\run -> Dict.get nodeId run.nodes)
                                    |> Maybe.andThen .output
                          in
                          Html.div []
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

                Nothing ->
                    Html.text ""

        Nothing ->
            Html.text ""


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


viewPlanExport : PlanViewState -> Html Msg
viewPlanExport pv =
    Html.div [ Attr.class "plan-import-row" ]
        [ Html.input
            [ Attr.class "plan-import-input"
            , Attr.placeholder "Export to path (empty = saved copy in plans dir)…"
            , Attr.value pv.exportPath
            , Ev.onInput PlanSetExportPath
            ]
            []
        , Html.button
            [ Attr.class "confirm-page-btn confirm-page-btn-allow"
            , Ev.onClick PlanExport
            , Attr.style "padding" "4px 10px"
            , Attr.style "font-size" "0.75rem"
            , Attr.style "min-width" "auto"
            ]
            [ Html.text "Export" ]
        ]


viewPlanManagerOverlay : Model -> Html Msg
viewPlanManagerOverlay model =
    if model.planManager.show then
        viewOverlay ClosePlanManager
            [ Html.div [ Attr.class "sel-page" ]
                [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Plans" ]
                , case model.planManager.error of
                    Just err ->
                        Html.div [ Attr.class "sel-page-status sel-page-status-error" ] [ Html.text err ]

                    Nothing ->
                        Html.text ""
                , viewPlanSavedTab model
                ]
            ]

    else
        Html.text ""


{-| The saved-plans list is derived from the planMetas index — every
plan is created by a session and lives under it
(sessions/<origin>/plans/<planId>/), so no directory scan is needed.
-}
planFileListFromMetas : Model -> List PlanFileInfo
planFileListFromMetas model =
    Dict.foldl
        (\planId meta acc ->
            { name = planId
            , path =
                model.homeDir
                    ++ "/.alayaface/sessions/"
                    ++ meta.origin.sessionId
                    ++ "/plans/"
                    ++ planId
                    ++ "/"
                    ++ planId
                    ++ ".json"
            }
                :: acc
        )
        []
        model.planMetas
        |> List.sortBy .name
        |> List.reverse


viewPlanSavedTab : Model -> Html Msg
viewPlanSavedTab model =
    let
        term =
            String.trim model.planManager.filter

        visible =
            if String.isEmpty term then
                planFileListFromMetas model

            else
                List.filter
                    (\info -> Fuzzy.fuzzyMatch (String.toLower term) (String.toLower info.name))
                    (planFileListFromMetas model)
    in
    Html.div []
        [ Html.div [ Attr.class "plan-filter-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.placeholder "Filter plans…"
                , Attr.value model.planManager.filter
                , Ev.onInput PlanManagerSetFilter
                ]
                []
            ]
        , if model.planMetaLoading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else if List.isEmpty visible then
            Html.div [ Attr.class "sel-page-status" ]
                [ Html.text
                    (if String.isEmpty term then
                        "No plans yet. Ask a session to output a plan."

                     else
                        "No plans match your filter."
                    )
                ]

          else
            Html.div [ Attr.class "sel-page-list" ]
                (List.map viewPlanFile visible)
        ]


viewPlanFile : PlanFileInfo -> Html Msg
viewPlanFile info =
    Html.div [ Attr.class "sel-page-item" ]
        [ Html.span [ Attr.class "sel-page-item-name" ] [ Html.text info.name ]
        , Html.button
            [ Attr.class "confirm-page-btn confirm-page-btn-allow"
            , Ev.onClick (PlanManagerOpen info.path)
            , Attr.style "padding" "4px 10px"
            , Attr.style "font-size" "0.75rem"
            , Attr.style "min-width" "auto"
            ]
            [ Html.text "Open" ]
        , Html.button
            [ Attr.class "confirm-page-btn confirm-page-btn-deny"
            , Ev.onClick (PlanManagerDelete info.path)
            , Attr.style "padding" "4px 10px"
            , Attr.style "font-size" "0.75rem"
            , Attr.style "min-width" "auto"
            ]
            [ Html.text "Delete" ]
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
        , viewHelpWindowOverlay session.id session
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
            viewMsgBody model session.id msg
        , viewPlanStatusBar model session.id planIndex
        ]


{-| Whether the on-disk session directory is currently open (either its
own session id is live, or a resumed session was created from it — the
resume map is newId → originalDirId).
-}
isSessionDirActive : Model -> String -> Bool
isSessionDirActive model dirId =
    Dict.member dirId model.sessions
        || (Dict.values model.planResumedFrom |> List.member dirId)


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
        Just ( planId, _ ) ->
            let
                name =
                    case Dict.get planId model.planWindows of
                        Just win ->
                            Maybe.withDefault planId (Maybe.map .name win.view.plan)

                        Nothing ->
                            planId

                ( statusLabel, statusClass, canRestart ) =
                    planStatusFor model planId
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


{-| The plan whose meta origin binds (sessionId, planIndex) — the plan
auto-created from that session's Nth plan message.
-}
planMetaForMessage : Model -> String -> Int -> Maybe ( String, PM.PlanMeta )
planMetaForMessage model sid planIndex =
    -- meta origin records the session's ON-DISK id (plans live under it);
    -- the rendered session may be a resume with a fresh live id — resolve
    -- sid back to the on-disk id before comparing.
    let
        onDiskId =
            case Dict.get sid model.planResumedFrom of
                Just orig ->
                    orig

                Nothing ->
                    sid
    in
    Dict.foldl
        (\planId meta acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    -- Binding is session + plan index (the order of
                    -- plan messages in a session is stable; message
                    -- ids are per-session implementation details and
                    -- deliberately not used for matching).
                    if meta.origin.sessionId == onDiskId && meta.origin.planIndex == planIndex then
                        Just ( planId, meta )

                    else
                        Nothing
        )
        Nothing
        model.planMetas


planStatusFor : Model -> String -> ( String, String, Bool )
planStatusFor model planId =
    case Dict.get planId model.planWindows of
        Just win ->
            case win.run of
                Just run ->
                    case run.status of
                        PT.NotStarted -> ( "Created", "created", False )
                        PT.InProgress -> ( "Running…", "running", False )
                        PT.Paused -> ( "Paused", "paused", True )
                        PT.Completed -> ( "Completed", "completed", False )
                        PT.FailedRun -> ( "Failed", "failed", True )
                        PT.Stopped -> ( "Stopped", "stopped", True )

                Nothing ->
                    ( "Created", "created", False )

        Nothing ->
            -- Window closed (auto-close on completion, or never opened):
            -- fall back to the last known run status kept in memory.
            case Dict.get planId model.planRunStatuses of
                Just st ->
                    case st of
                        PT.NotStarted -> ( "Created", "created", False )
                        PT.InProgress -> ( "Running…", "running", False )
                        PT.Paused -> ( "Paused", "paused", True )
                        PT.Completed -> ( "Completed", "completed", False )
                        PT.FailedRun -> ( "Failed", "failed", True )
                        PT.Stopped -> ( "Stopped", "stopped", True )

                Nothing ->
                    ( "Open", "created", False )


-- Header row of a message window: role label, optional tool info, and a
-- one-line preview when collapsed. The whole row toggles on click.
viewMsgHeader : T.SessionState -> T.Message -> Bool -> List (Html Msg)
viewMsgHeader session msg collapsed =
    [ Html.span [ Attr.class "msg-label" ]
        [ Html.text (String.toUpper (T.roleToString msg.role)) ]
    , case msg.role of
        T.Tool ->
            Html.span [ Attr.class "msg-tool-info" ]
                [ Html.span [ Attr.class "msg-name" ]
                    [ Html.text (Maybe.withDefault "" msg.toolName) ]
                , Html.span [ Attr.class "msg-status" ]
                    [ Html.text (toolStatus session msg) ]
                ]

        _ ->
            Html.text ""
    , if collapsed && msg.role /= T.Tool then
        Html.span [ Attr.class "msg-preview" ]
            [ Html.text (previewText msg) ]

      else
        Html.text ""
    ]


-- Tool state icon derived from the tool call lifecycle:
-- ❌ error (UF error), ⏳ running (input streaming / preview), ✅ done.
toolStatus : T.SessionState -> T.Message -> String
toolStatus session msg =
    if msg.isError then
        "❌"

    else
        case Dict.get (Maybe.withDefault "" msg.toolId) session.toolCalls of
            Just tc ->
                if tc.output /= Nothing || tc.accumulatedDelta /= Nothing || tc.inputReceived then
                    "⏳"

                else
                    "✅"

            Nothing ->
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
            -- Plain text output — no markdown, no code fence border. The
            -- header carries the tool name and status, so the body is just
            -- the raw input/output text (empty while nothing has arrived).
            if String.isEmpty (String.trim msg.content) then
                Html.text ""

            else
                Html.div [ Attr.class "msg-body" ]
                    [ Html.text msg.content ]

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
                , builtinTools = ed.builtinTools
                , loading = ed.loading
                , syncing = ed.syncing
                , error = ed.error
                , onInput = SetToolConfirm
                , onBuiltinToolsInput = SetBuiltinTools
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
