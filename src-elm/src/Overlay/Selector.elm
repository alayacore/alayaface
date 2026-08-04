module Overlay.Selector exposing
    ( viewPage
    , viewList
    )

{-| Shared view for the three list-based configuration selectors
(per-session model selector, global default-model editor, MCP server
editor). Replaces the duplicated ModelSelector/McpSelector views and
the per-editor sync prompt pages.

The list is parameterized over the item type; the caller supplies
rendering callbacks. The page shell handles the editor/sync/loading
pages so every selector gets identical behavior.
-}

import Fuzzy
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D
import Session.Selector exposing (Page(..))


-- Page shell (list / edit / sync prompt / syncing / failed / loading)

viewPage :
    { title : String
    , page : Page
    , dirty : Bool
    , syncError : Maybe String
    , listView : Html msg
    , editorView : Html msg
    , onSync : msg
    , onDiscard : msg
    , onCancelSync : msg
    }
    -> Html msg
viewPage cfg =
    case cfg.page of
        ModelSelEdit ->
            cfg.editorView

        ModelSelConfirmSync ->
            syncPrompt cfg.title cfg.dirty
                { onConfirm = cfg.onSync
                , onDiscard = cfg.onDiscard
                , onCancel = cfg.onCancelSync
                }

        ModelSelSyncing ->
            statusPage cfg.title cfg.dirty "Syncing…"

        ModelSelSyncFailed ->
            syncFailed cfg.title cfg.dirty
                (Maybe.withDefault "Unknown error" cfg.syncError)
                { onRetry = cfg.onSync
                , onBack = cfg.onCancelSync
                , onDiscard = cfg.onDiscard
                }

        ModelSelLoading ->
            statusPage cfg.title False "Loading…"

        ModelSelList ->
            cfg.listView


-- Searchable list page

viewList :
    { title : String
    , inputId : String
    , itemIdPrefix : String
    , placeholder : String
    , emptyText : String
    , noMatchText : String
    , items : List item
    , input : String
    , selected : Int
    , confirmDeleteId : Maybe Int
    , canDelete : Bool
    , currentLabel : String
    , currentValue : String
    , addTitle : String
    , itemId : item -> Int
    , itemTitle : item -> String
    , itemSubtitle : item -> String
    , isActive : item -> Bool
    , editTitle : item -> String
    , deleteTitle : item -> String
    , onSelect : Int -> msg
    , onConfirm : msg
    , noOp : msg
    , onInput : String -> msg
    , onEdit : Int -> msg
    , onDelete : Int -> msg
    , onDeleteConfirm : Int -> msg
    , onDeleteCancel : msg
    , onAdd : msg
    }
    -> Html msg
viewList cfg =
    let
        filtered =
            filterItems cfg.itemTitle cfg.items cfg.input
    in
    Html.div [ Attr.class "sel-page" ]
        [ pageTitle cfg.title False
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.id cfg.inputId
                , Attr.type_ "text"
                , Attr.value cfg.input
                , Ev.onInput cfg.onInput
                , Attr.placeholder cfg.placeholder
                , Ev.preventDefaultOn "keydown" <|
                    D.map2
                        (\key ctrl ->
                            if key == "Enter" && not ctrl then
                                ( cfg.onConfirm, True )

                            else
                                ( cfg.noOp, False )
                        )
                        (D.field "key" D.string)
                        (D.field "ctrlKey" D.bool)
                ]
                []
            ]
        , Html.div [ Attr.class "sel-page-current" ]
            [ Html.span [ Attr.class "sel-page-current-label" ] [ Html.text cfg.currentLabel ]
            , Html.span [ Attr.class "sel-page-current-name" ]
                [ Html.text cfg.currentValue ]
            , Html.button
                [ Attr.class "sel-page-add-btn"
                , Ev.stopPropagationOn "click" (D.succeed ( cfg.onAdd, True ))
                , Attr.title cfg.addTitle
                ]
                [ Html.text "+ Add" ]
            ]
        , if List.isEmpty cfg.items then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text cfg.emptyText ]

          else if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text cfg.noMatchText ]

          else
            Html.div
                [ Attr.class "sel-page-list"
                , Attr.id (cfg.itemIdPrefix ++ "-list")
                ]
                (List.indexedMap (\i m -> viewItem i m cfg) filtered)
        ]


viewItem : Int -> item -> { a | itemId : item -> Int, itemTitle : item -> String, itemSubtitle : item -> String, isActive : item -> Bool, editTitle : item -> String, deleteTitle : item -> String, selected : Int, confirmDeleteId : Maybe Int, canDelete : Bool, itemIdPrefix : String, onSelect : Int -> msg, onConfirm : msg, onEdit : Int -> msg, onDelete : Int -> msg, onDeleteConfirm : Int -> msg, onDeleteCancel : msg } -> Html msg
viewItem idx item cfg =
    let
        isSelected =
            idx == cfg.selected

        isActive =
            cfg.isActive item

        isConfirmingDelete =
            cfg.confirmDeleteId == Just (cfg.itemId item)

        idStr =
            String.fromInt (cfg.itemId item)

        stopClick msg =
            Ev.stopPropagationOn "click" (D.succeed ( msg, True ))
    in
    Html.div
        [ Attr.id (cfg.itemIdPrefix ++ "-" ++ idStr)
        , Attr.class ("sel-page-item"
            ++ (if isSelected then " sel-page-item-selected" else "")
            ++ (if isActive then " sel-page-item-active" else "")
          )
        , Ev.onClick (cfg.onSelect idx)
        , Ev.onDoubleClick cfg.onConfirm
        ]
        [ Html.span [ Attr.class "sel-page-item-id" ] [ Html.text idStr ]
        , Html.span [ Attr.class "sel-page-item-main" ]
            [ Html.span [ Attr.class "sel-page-item-name" ] [ Html.text (cfg.itemTitle item) ]
            , Html.span [ Attr.class "sel-page-item-sub" ] [ Html.text (cfg.itemSubtitle item) ]
            ]
        , Html.span [ Attr.class "sel-page-item-check" ]
            [ if isActive then Html.text "●" else Html.text "" ]
        , if isConfirmingDelete then
            Html.span [ Attr.class "sel-page-item-actions" ]
                [ Html.button
                    [ Attr.class "sel-page-action sel-page-action-danger"
                    , stopClick (cfg.onDeleteConfirm (cfg.itemId item))
                    ]
                    [ Html.text "Confirm" ]
                , Html.button
                    [ Attr.class "sel-page-action"
                    , stopClick cfg.onDeleteCancel
                    ]
                    [ Html.text "Cancel" ]
                ]

          else
            Html.span [ Attr.class "sel-page-item-actions" ]
                [ Html.button
                    [ Attr.class "sel-page-action"
                    , Attr.disabled isActive
                    , Attr.title (cfg.editTitle item)
                    , stopClick (cfg.onEdit (cfg.itemId item))
                    ]
                    [ Html.text "Edit" ]
                , Html.button
                    [ Attr.class "sel-page-action sel-page-action-danger"
                    , Attr.disabled (isActive || not cfg.canDelete)
                    , Attr.title (cfg.deleteTitle item)
                    , stopClick (cfg.onDelete (cfg.itemId item))
                    ]
                    [ Html.text "Delete" ]
                ]
        ]


-- Internal helpers

filterItems : (item -> String) -> List item -> String -> List item
filterItems search items term =
    let
        trimmed =
            String.trim term

        needle =
            String.toLower trimmed
    in
    if String.isEmpty trimmed then
        items

    else
        List.filter (\m -> Fuzzy.fuzzyMatch needle (String.toLower (search m))) items


pageTitle : String -> Bool -> Html msg
pageTitle title dirty =
    Html.div
        [ Attr.class "sel-page-title"
        , Attr.title (if dirty then "Unsaved changes" else "")
        ]
        [ Html.text (title ++ (if dirty then " *" else "")) ]


statusPage : String -> Bool -> String -> Html msg
statusPage title dirty status =
    Html.div [ Attr.class "sel-page" ]
        [ pageTitle title dirty
        , Html.div [ Attr.class "sel-page-status" ] [ Html.text status ]
        ]


syncPrompt : String -> Bool -> { onConfirm : msg, onDiscard : msg, onCancel : msg } -> Html msg
syncPrompt title dirty callbacks =
    Html.div [ Attr.class "sel-page" ]
        [ pageTitle title dirty
        , Html.div [ Attr.class "sel-page-status" ]
            [ Html.text "You have unsaved changes. Sync them now?" ]
        , Html.div [ Attr.class "sel-page-actions" ]
            [ Html.button
                [ Attr.class "me-save-btn"
                , Ev.onClick callbacks.onConfirm
                ]
                [ Html.text "Sync & Close" ]
            , Html.button
                [ Attr.class "me-cancel-btn"
                , Ev.onClick callbacks.onDiscard
                ]
                [ Html.text "Discard & Close" ]
            , Html.button
                [ Attr.class "me-cancel-btn"
                , Ev.onClick callbacks.onCancel
                ]
                [ Html.text "Cancel" ]
            ]
        ]


syncFailed : String -> Bool -> String -> { onRetry : msg, onBack : msg, onDiscard : msg } -> Html msg
syncFailed title dirty error callbacks =
    Html.div [ Attr.class "sel-page" ]
        [ pageTitle title dirty
        , Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
            [ Html.text ("Sync failed: " ++ error) ]
        , Html.div [ Attr.class "sel-page-actions" ]
            [ Html.button
                [ Attr.class "me-save-btn"
                , Ev.onClick callbacks.onRetry
                ]
                [ Html.text "Retry" ]
            , Html.button
                [ Attr.class "me-cancel-btn"
                , Ev.onClick callbacks.onBack
                ]
                [ Html.text "Back" ]
            , Html.button
                [ Attr.class "me-cancel-btn"
                , Ev.onClick callbacks.onDiscard
                ]
                [ Html.text "Discard & Close" ]
            ]
        ]
