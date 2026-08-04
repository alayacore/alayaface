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
    , renaming : Maybe String
    , renameInput : String
    , editing : Maybe String
    , confirmDelete : Maybe String
    , error : Maybe String
    , onCopy : String -> msg
    , onSetActive : String -> msg
    , onRenameStart : String -> msg
    , onRenameInput : String -> msg
    , onRenameSave : String -> msg
    , onRenameCancel : msg
    , onToggleEdit : String -> msg
    , onEditModels : String -> msg
    , onEditMcp : String -> msg
    , onEditSettings : String -> msg
    , onDelete : String -> msg
    , onDeleteConfirm : String -> msg
    , onDeleteCancel : msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "sel-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Presets" ]
        , Html.div [ Attr.class "me-hint" ]
            [ Html.text "Each preset is a full config set (models, MCP servers, tool-confirm settings). Use one to make it the template for new sessions; Copy duplicates it; Edit opens its config — you can edit any preset without switching." ]
        , case config.error of
            Just err ->
                Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                    [ Html.text err ]

            Nothing ->
                Html.text ""
        , if config.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else if List.isEmpty config.presets then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No presets yet." ]

          else
            Html.div [ Attr.class "pm-list" ]
                (List.concatMap (viewRow config) config.presets)
        ]


viewRow :
    { a
        | renaming : Maybe String
        , renameInput : String
        , editing : Maybe String
        , busy : Bool
        , confirmDelete : Maybe String
        , onCopy : String -> msg
        , onSetActive : String -> msg
        , onRenameStart : String -> msg
        , onRenameInput : String -> msg
        , onRenameSave : String -> msg
        , onRenameCancel : msg
        , onToggleEdit : String -> msg
        , onEditModels : String -> msg
        , onEditMcp : String -> msg
        , onEditSettings : String -> msg
        , onDelete : String -> msg
        , onDeleteConfirm : String -> msg
        , onDeleteCancel : msg
    }
    -> PresetInfo
    -> List (Html msg)
viewRow config p =
    case config.confirmDelete of
        Just name ->
            if name == p.name then
                [ Html.div [ Attr.class "pm-row pm-row-confirm" ]
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
                ]

            else
                [ Html.div [ Attr.class "pm-row" ]
                    [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                    , Html.button
                        [ Attr.class "pm-btn"
                        , Attr.disabled config.busy
                        , Ev.onClick (config.onDelete p.name)
                        ]
                        [ Html.text "Delete" ]
                    ]
                ]

        Nothing ->
            case config.renaming of
                Just name ->
                    if name == p.name then
                        [ Html.div [ Attr.class "pm-row pm-row-renaming" ]
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
                        ]

                    else
                        [ Html.div [ Attr.class "pm-row" ]
                            [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                            , Html.button
                                [ Attr.class "pm-btn"
                                , Attr.disabled config.busy
                                , Ev.onClick (config.onRenameStart p.name)
                                ]
                                [ Html.text "Rename" ]
                            ]
                        ]

                Nothing ->
                    let
                        isEditing =
                            config.editing == Just p.name

                        mainRow =
                            Html.div
                                [ Attr.class ("pm-row" ++ (if p.isActive then " pm-row-active" else "")) ]
                                [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
                                , if p.isActive then
                                    Html.text ""

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
                                    , Ev.onClick (config.onCopy p.name)
                                    , Attr.title "Duplicate this preset"
                                    ]
                                    [ Html.text "Copy" ]
                                , Html.button
                                    [ Attr.class "pm-btn"
                                    , Attr.disabled config.busy
                                    , Ev.onClick (config.onToggleEdit p.name)
                                    ]
                                    [ Html.text (if isEditing then "Done" else "Edit") ]
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

                        editRow =
                            if isEditing then
                                [ Html.div [ Attr.class "pm-edit-row" ]
                                    [ Html.span [ Attr.class "pm-edit-label" ]
                                        [ Html.text ("Edit " ++ p.name ++ ":") ]
                                    , Html.button
                                        [ Attr.class "pm-btn pm-btn-primary"
                                        , Attr.disabled config.busy
                                        , Ev.onClick (config.onEditModels p.name)
                                        ]
                                        [ Html.text "Models" ]
                                    , Html.button
                                        [ Attr.class "pm-btn pm-btn-primary"
                                        , Attr.disabled config.busy
                                        , Ev.onClick (config.onEditMcp p.name)
                                        ]
                                        [ Html.text "MCP Servers" ]
                                    , Html.button
                                        [ Attr.class "pm-btn pm-btn-primary"
                                        , Attr.disabled config.busy
                                        , Ev.onClick (config.onEditSettings p.name)
                                        ]
                                        [ Html.text "Settings" ]
                                    ]
                                ]

                            else
                                []
                    in
                    mainRow :: editRow
