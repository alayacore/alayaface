module Overlay.PresetManager exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D


type alias PresetInfo =
    { name : String
    , isSeed : Bool
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
    , dragFrom : Maybe Int
    , dragOver : Maybe Int
    , onCopy : String -> msg
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
    , onDragStart : Int -> msg
    , onDragOver : Int -> msg
    , onDragEnd : msg
    , onDrop : Int -> msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "sel-page" ]
        [ Html.div [ Attr.class "me-hint" ]
            [ Html.text "Each preset is a full config set (models, MCP servers, tool settings and its own system prompt). New sessions pick a preset from the global menu; Copy duplicates it; Edit opens its config — you can edit any preset without switching. Built-in presets (Simple/Complex) cannot be renamed or deleted — copy one to customize. Drag a row by its ⠿ handle to reorder the list." ]
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
                (List.indexedMap (\idx p -> viewRow config idx p) config.presets
                    |> List.concat
                )
        ]


{-| The preset name plus a small "built-in" tag for the seed presets
(Simple/Complex), which cannot be renamed or deleted. The tag lives in
its own flex child so it is never clipped by the name's ellipsis.
-}
nameLabel : PresetInfo -> Html msg
nameLabel p =
    Html.span [ Attr.class "pm-name-wrap" ]
        [ Html.span [ Attr.class "pm-name" ] [ Html.text p.name ]
        , if p.isSeed then
            Html.span [ Attr.class "pm-builtin-tag" ] [ Html.text "built-in" ]

          else
            Html.text ""
        ]


{-| The drag handle ("⠿") — the only draggable part of a row, so
clicking Copy/Edit/Rename/Delete is never swallowed by a drag gesture.
-}
dragHandle : Int -> PresetInfo -> (Int -> msg) -> msg -> Html msg
dragHandle idx p onDragStart onDragEnd =
    Html.span
        [ Attr.class "pm-drag-handle"
        , Attr.draggable "true"
        , Attr.attribute "data-preset" p.name
        , Attr.title "Drag to reorder"
        , Ev.on "dragstart" (D.succeed (onDragStart idx))
        , Ev.on "dragend" (D.succeed onDragEnd)
        ]
        [ Html.text "⠿" ]


{-| Drop zone of a row: dragover must preventDefault or the browser
won't fire drop. The row is the drop target (not the handle) so a drop
anywhere on the row works; events bubble from the handle.
-}
dropAttrs : Int -> (Int -> msg) -> (Int -> msg) -> List (Html.Attribute msg)
dropAttrs idx onDragOver onDrop =
    [ Ev.preventDefaultOn "dragover" (D.succeed ( onDragOver idx, True ))
    , Ev.on "drop" (D.succeed (onDrop idx))
    ]


viewRow :
    { a
        | renaming : Maybe String
        , renameInput : String
        , editing : Maybe String
        , busy : Bool
        , confirmDelete : Maybe String
        , dragFrom : Maybe Int
        , dragOver : Maybe Int
        , onCopy : String -> msg
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
        , onDragStart : Int -> msg
        , onDragOver : Int -> msg
        , onDragEnd : msg
        , onDrop : Int -> msg
    }
    -> Int
    -> PresetInfo
    -> List (Html msg)
viewRow config idx p =
    let
        rowClass base =
            base
                ++ (if config.dragFrom == Just idx then
                        " pm-row-drag-from"

                    else if config.dragOver == Just idx then
                        " pm-row-drag-over"

                    else
                        "")
    in
    case config.confirmDelete of
        Just name ->
            if name == p.name then
                [ Html.div [ Attr.class "pm-row pm-row-confirm" ]
                    [ nameLabel p
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
                [ Html.div (Attr.class (rowClass "pm-row") :: dropAttrs idx config.onDragOver config.onDrop)
                    [ dragHandle idx p config.onDragStart config.onDragEnd
                    , nameLabel p
                    , if p.isSeed then
                        Html.text ""

                      else
                        Html.button
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
                        [ Html.div (Attr.class (rowClass "pm-row") :: dropAttrs idx config.onDragOver config.onDrop)
                            [ dragHandle idx p config.onDragStart config.onDragEnd
                            , nameLabel p
                            , if p.isSeed then
                                Html.text ""

                              else
                                Html.button
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
                            Html.div (Attr.class (rowClass "pm-row") :: dropAttrs idx config.onDragOver config.onDrop)
                                [ dragHandle idx p config.onDragStart config.onDragEnd
                                , nameLabel p
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
                                , if p.isSeed then
                                    Html.text ""

                                  else
                                    Html.button
                                        [ Attr.class "pm-btn"
                                        , Attr.disabled config.busy
                                        , Ev.onClick (config.onRenameStart p.name)
                                        ]
                                        [ Html.text "Rename" ]
                                , if p.isSeed then
                                    Html.text ""

                                  else
                                    Html.button
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
