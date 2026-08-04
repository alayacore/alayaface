module Overlay.PresetManager exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev


type alias PresetInfo =
    { name : String
    , isActive : Bool
    }


view :
    { presets : List PresetInfo
    , loading : Bool
    , busy : Bool
    , newName : String
    , renaming : Maybe String
    , renameInput : String
    , confirmDelete : Maybe String
    , error : Maybe String
    , onInput : String -> msg
    , onCreate : msg
    , onSetActive : String -> msg
    , onRenameStart : String -> msg
    , onRenameInput : String -> msg
    , onRenameSave : String -> msg
    , onRenameCancel : msg
    , onDelete : String -> msg
    , onDeleteConfirm : String -> msg
    , onDeleteCancel : msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "sel-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Presets" ]
        , Html.div [ Attr.class "me-hint" ]
            [ Html.text "Each preset is a full config set (models, MCP servers, tool-confirm settings). New sessions and the editors below use the active preset. Running sessions keep their own copy." ]
        , case config.error of
            Just err ->
                Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                    [ Html.text err ]

            Nothing ->
                Html.text ""
        , if config.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else
            Html.div []
                [ Html.div [ Attr.class "pm-new-row" ]
                    [ Html.input
                        [ Attr.class "me-field-input"
                        , Attr.type_ "text"
                        , Attr.value config.newName
                        , Attr.placeholder "New preset name"
                        , Attr.disabled config.busy
                        , Ev.onInput config.onInput
                        ]
                        []
                    , Html.button
                        [ Attr.class "me-save-btn"
                        , Attr.disabled (config.busy || String.isEmpty (String.trim config.newName))
                        , Ev.onClick config.onCreate
                        ]
                        [ Html.text (if config.busy then "Working…" else "Create") ]
                    ]
                , if List.isEmpty config.presets then
                    Html.div [ Attr.class "sel-page-status" ] [ Html.text "No presets yet." ]

                  else
                    Html.div [ Attr.class "pm-list" ]
                        (List.map (viewRow config) config.presets)
                ]
        ]


viewRow : { a | renaming : Maybe String, renameInput : String, busy : Bool, confirmDelete : Maybe String, onSetActive : String -> msg, onRenameStart : String -> msg, onRenameInput : String -> msg, onRenameSave : String -> msg, onRenameCancel : msg, onDelete : String -> msg, onDeleteConfirm : String -> msg, onDeleteCancel : msg } -> PresetInfo -> Html msg
viewRow config p =
    case config.confirmDelete of
        Just name ->
            if name == p.name then
                Html.div [ Attr.class "pm-row pm-row-confirm" ]
                    [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                    , Html.span [ Attr.class "pm-confirm-text" ] [ Html.text "Delete this preset?" ]
                    , Html.button
                        [ Attr.class "pm-btn pm-btn-danger"
                        , Attr.disabled config.busy
                        , Ev.onClick (config.onDeleteConfirm p.name)
                        ]
                        [ Html.text "Delete" ]
                    , Html.button
                        [ Attr.class "pm-btn"
                        , Attr.disabled config.busy
                        , Ev.onClick config.onDeleteCancel
                        ]
                        [ Html.text "Cancel" ]
                    ]

            else
                Html.div [ Attr.class "pm-row" ]
                    [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                    , Html.button
                        [ Attr.class "pm-btn"
                        , Attr.disabled config.busy
                        , Ev.onClick (config.onDelete p.name)
                        ]
                        [ Html.text "Delete" ]
                    ]

        Nothing ->
            case config.renaming of
                Just name ->
                    if name == p.name then
                        Html.div [ Attr.class "pm-row pm-row-renaming" ]
                            [ Html.input
                                [ Attr.class "me-field-input"
                                , Attr.type_ "text"
                                , Attr.value config.renameInput
                                , Attr.disabled config.busy
                                , Ev.onInput config.onRenameInput
                                ]
                                []
                            , Html.button
                                [ Attr.class "pm-btn pm-btn-primary"
                                , Attr.disabled (config.busy || String.isEmpty (String.trim config.renameInput))
                                , Ev.onClick (config.onRenameSave p.name)
                                ]
                                [ Html.text "Save" ]
                            , Html.button
                                [ Attr.class "pm-btn"
                                , Attr.disabled config.busy
                                , Ev.onClick config.onRenameCancel
                                ]
                                [ Html.text "Cancel" ]
                            ]

                    else
                        Html.div [ Attr.class "pm-row" ]
                            [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                            , Html.button
                                [ Attr.class "pm-btn"
                                , Attr.disabled config.busy
                                , Ev.onClick (config.onRenameStart p.name)
                                ]
                                [ Html.text "Rename" ]
                            ]

                Nothing ->
                    Html.div
                        [ Attr.class ("pm-row" ++ (if p.isActive then " pm-row-active" else "")) ]
                        [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                        , if p.isActive then
                            Html.span [ Attr.class "pm-badge" ] [ Html.text "Active" ]

                          else
                            Html.button
                                [ Attr.class "pm-btn pm-btn-primary"
                                , Attr.disabled config.busy
                                , Ev.onClick (config.onSetActive p.name)
                                ]
                                [ Html.text "Use" ]
                        , Html.button
                            [ Attr.class "pm-btn"
                            , Attr.disabled config.busy
                            , Ev.onClick (config.onRenameStart p.name)
                            ]
                            [ Html.text "Rename" ]
                        , Html.button
                            [ Attr.class "pm-btn pm-btn-danger"
                            , Attr.disabled config.busy
                            , Ev.onClick (config.onDelete p.name)
                            ]
                            [ Html.text "Delete" ]
                        ]
