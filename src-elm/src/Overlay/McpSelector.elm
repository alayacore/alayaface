module Overlay.McpSelector exposing (view)

import Fuzzy
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D
import Session.Types as T


view :
    { sessionId : String
    , servers : List T.McpInfo
    , input : String
    , selected : Int
    , confirmDeleteId : Maybe Int
    , canDelete : Bool
    , dirty : Bool
    , error : Maybe String
    , noOp : msg
    , onSelect : Int -> msg
    , onConfirm : msg
    , onClose : msg
    , onInput : String -> msg
    , onEdit : Int -> msg
    , onDelete : Int -> msg
    , onDeleteConfirm : Int -> msg
    , onDeleteCancel : msg
    , onAdd : msg
    }
    -> Html msg
view config =
    let
        filtered =
            filterServers config.servers config.input

        inputId =
            "mcp-selector-input-" ++ config.sessionId
    in
    Html.div [ Attr.class "sel-page" ]
        [ Html.div
            [ Attr.class "sel-page-title"
            , Attr.title (if config.dirty then "Unsaved changes" else "")
            ]
            [ Html.text ("MCP Servers" ++ (if config.dirty then " *" else "")) ]
        , case config.error of
            Just err ->
                Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                    [ Html.text ("Failed to load MCP servers: " ++ err) ]

            Nothing ->
                Html.text ""
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.id inputId
                , Attr.type_ "text"
                , Attr.value config.input
                , Ev.onInput config.onInput
                , Attr.placeholder "Search servers…"
                , Ev.preventDefaultOn "keydown" <|
                    D.map2 (\key ctrl ->
                        if key == "Enter" && not ctrl then
                            ( config.onConfirm, True )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool)
                ]
                []
            ]
        , Html.div [ Attr.class "sel-page-current" ]
            [ Html.span [ Attr.class "sel-page-current-label" ] [ Html.text "Servers: " ]
            , Html.span [ Attr.class "sel-page-current-name" ]
                [ Html.text (String.fromInt (List.length config.servers)) ]
            , Html.button
                [ Attr.class "sel-page-add-btn"
                , Ev.stopPropagationOn "click" (D.succeed ( config.onAdd, True ))
                , Attr.title "Add MCP server"
                ]
                [ Html.text "+ Add" ]
            ]
        , if List.isEmpty config.servers then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No MCP servers configured." ]

          else if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No servers match your search." ]

          else
            Html.div
                [ Attr.class "sel-page-list"
                , Attr.id ("mcp-selector-list-" ++ config.sessionId)
                ]
                (List.indexedMap (\i s -> viewItem i s config) filtered)
        ]


viewItem : Int -> T.McpInfo -> { a | sessionId : String, selected : Int, confirmDeleteId : Maybe Int, canDelete : Bool, onSelect : Int -> msg, onConfirm : msg, noOp : msg, onEdit : Int -> msg, onDelete : Int -> msg, onDeleteConfirm : Int -> msg, onDeleteCancel : msg } -> Html msg
viewItem idx server config =
    let
        isSelected =
            idx == config.selected

        isConfirmingDelete =
            config.confirmDeleteId == Just server.id

        stopClick msg =
            Ev.stopPropagationOn "click" (D.succeed ( msg, True ))

        subtitle =
            (if server.type_ == "stdio" then
                "STDIO"

             else
                "HTTP"
            )
                ++ (if server.url /= "" then
                        " · " ++ server.url

                    else if server.command /= "" then
                        " · " ++ server.command

                    else
                        ""
                   )
    in
    Html.div
        [ Attr.id ("mcp-selector-item-" ++ config.sessionId ++ "-" ++ String.fromInt server.id)
        , Attr.class ("sel-page-item"
            ++ (if isSelected then " sel-page-item-selected" else "")
          )
        , Ev.onClick (config.onSelect idx)
        , Ev.onDoubleClick config.onConfirm
        ]
        [ Html.span [ Attr.class "sel-page-item-id" ] [ Html.text (String.fromInt server.id) ]
        , Html.span [ Attr.class "sel-page-item-main" ]
            [ Html.span [ Attr.class "sel-page-item-name" ] [ Html.text server.server ]
            , Html.span [ Attr.class "sel-page-item-sub" ] [ Html.text subtitle ]
            ]
        , if isConfirmingDelete then
            Html.span [ Attr.class "sel-page-item-actions" ]
                [ Html.button
                    [ Attr.class "sel-page-action sel-page-action-danger"
                    , stopClick (config.onDeleteConfirm server.id)
                    ]
                    [ Html.text "Confirm" ]
                , Html.button
                    [ Attr.class "sel-page-action"
                    , stopClick config.onDeleteCancel
                    ]
                    [ Html.text "Cancel" ]
                ]

          else
            Html.span [ Attr.class "sel-page-item-actions" ]
                [ Html.button
                    [ Attr.class "sel-page-action"
                    , stopClick (config.onEdit server.id)
                    ]
                    [ Html.text "Edit" ]
                , Html.button
                    [ Attr.class "sel-page-action sel-page-action-danger"
                    , Attr.disabled (not config.canDelete)
                    , Attr.title (if config.canDelete then "Delete server" else "At least one server must remain")
                    , stopClick (config.onDelete server.id)
                    ]
                    [ Html.text "Delete" ]
                ]
        ]


filterServers : List T.McpInfo -> String -> List T.McpInfo
filterServers servers term =
    let
        trimmed =
            String.trim term
    in
    if String.isEmpty trimmed then
        servers
    else
        List.filter (\s -> Fuzzy.fuzzyMatch (String.toLower trimmed) (String.toLower s.server)) servers
