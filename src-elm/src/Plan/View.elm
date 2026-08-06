module Plan.View exposing
    ( viewDag
    )

{-| Plan DAG view: renders the plan as an HTML/CSS graph (no SVG
dependency). Absolutely-positioned node cards over orthogonal edge
segments, sized from Plan.Layout geometry.

    viewDag onNodeClick runStates plan

`onNodeClick` receives the task id. `runStates` (empty for a plan that
has not been run) drives node status colors, retry badges and failure
tooltips; the Runner (P4) fills it.
-}

import Dict exposing (Dict)
import Html exposing (Html, Attribute)
import Html.Attributes as Attr
import Html.Events as Ev
import Plan.Layout as L
import Plan.Types as PT


viewDag : (String -> msg) -> Dict String PT.NodeRunState -> PT.Plan -> Html msg
viewDag onNodeClick runStates plan =
    let
        ( nodes, edges ) =
            L.layout plan

        tasksById =
            Dict.fromList (List.map (\t -> ( t.id, t )) plan.tasks)

        w =
            L.dagWidth nodes

        h =
            L.dagHeight nodes

        segAttr : L.Segment -> List (Attribute msg)
        segAttr s =
            [ Attr.class "plan-edge-seg"
            , Attr.style "left" (px s.x)
            , Attr.style "top" (px s.y)
            , Attr.style "width" (px s.w)
            , Attr.style "height" (px s.h)
            ]
    in
    Html.div
        [ Attr.class "plan-dag"
        , Attr.style "width" (px w)
        , Attr.style "height" (px h)
        ]
        (List.concatMap
            (\e ->
                [ Html.div (segAttr e.v1) []
                , Html.div (segAttr e.h) []
                , Html.div (segAttr e.v2) []
                ]
            )
            edges
            ++ List.map (viewNode onNodeClick runStates tasksById) nodes
        )


viewNode : (String -> msg) -> Dict String PT.NodeRunState -> Dict String PT.TaskNode -> L.NodeLayout -> Html msg
viewNode onNodeClick runStates tasksById pos =
    let
        task =
            Dict.get pos.id tasksById

        title =
            Maybe.map .title task |> Maybe.withDefault pos.id

        preset =
            task |> Maybe.andThen .preset |> Maybe.withDefault "default"

        tools =
            task |> Maybe.andThen .tools

        runState =
            Dict.get pos.id runStates

        status =
            Maybe.map .status runState |> Maybe.withDefault PT.Pending

        attempts =
            Maybe.map .attempts runState |> Maybe.withDefault 0

        failureTip =
            runState
                |> Maybe.andThen (\rs -> List.head rs.failures)
                |> Maybe.map (\f -> "第 " ++ String.fromInt f.attempt ++ " 次失败: " ++ f.reason)
    in
    Html.div
        [ Attr.class ("plan-node plan-node-" ++ statusClass status)
        , Attr.style "left" (px pos.x)
        , Attr.style "top" (px pos.y)
        , Attr.style "width" (px L.nodeW)
        , Attr.style "height" (px L.nodeH)
        , Ev.onClick (onNodeClick pos.id)
        , Attr.title (Maybe.withDefault title failureTip)
        ]
        [ Html.div [ Attr.class "plan-node-head" ]
            [ Html.span [ Attr.class "plan-node-id" ] [ Html.text pos.id ]
            , Html.span [ Attr.class "plan-node-status" ] [ Html.text (statusIcon status) ]
            ]
        , Html.div [ Attr.class "plan-node-title" ] [ Html.text title ]
        , Html.div [ Attr.class "plan-node-meta" ]
            [ Html.span [ Attr.class "plan-node-preset" ] [ Html.text preset ]
            , if attempts > 0 then
                Html.span [ Attr.class "plan-node-attempts" ]
                    [ Html.text ("x" ++ String.fromInt attempts) ]

              else
                Html.text ""
            ]
        , case tools of
            Just t ->
                Html.div [ Attr.class "plan-node-tools" ]
                    [ Html.text ("tools: " ++ t) ]

            Nothing ->
                Html.text ""
        ]


px : Float -> String
px v =
    String.fromFloat v ++ "px"


statusClass : PT.NodeStatus -> String
statusClass s =
    case s of
        PT.Pending ->
            "pending"

        PT.Starting ->
            "starting"

        PT.Running ->
            "running"

        PT.Waiting ->
            "waiting"

        PT.Succeeded ->
            "succeeded"

        PT.Failed ->
            "failed"

        PT.Blocked ->
            "blocked"

        PT.Canceled ->
            "canceled"


statusIcon : PT.NodeStatus -> String
statusIcon s =
    case s of
        PT.Pending ->
            "○"

        PT.Starting ->
            "◐"

        PT.Running ->
            "◐"

        PT.Waiting ->
            "↻"

        PT.Succeeded ->
            "✓"

        PT.Failed ->
            "✗"

        PT.Blocked ->
            "⊘"

        PT.Canceled ->
            "—"
