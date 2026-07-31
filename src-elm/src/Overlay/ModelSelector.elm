module Overlay.ModelSelector exposing (view)

import Fuzzy
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D
import Session.Types as T


view :
    { sessionId : String
    , models : List T.ModelInfo
    , input : String
    , selected : Int
    , activeModelId : Maybe Int
    , activeModelName : String
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
            filterModels config.models config.input

        inputId =
            "model-selector-input-" ++ config.sessionId
    in
    Html.div [ Attr.class "sel-page" ]
        [ Html.div
            [ Attr.class "sel-page-title"
            , Attr.title (if config.dirty then "Unsaved changes" else "")
            ]
            [ Html.text ("Model Selector" ++ (if config.dirty then " *" else "")) ]
        , case config.error of
            Just err ->
                Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                    [ Html.text ("Failed to load models: " ++ err) ]

            Nothing ->
                Html.text ""
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.id inputId
                , Attr.type_ "text"
                , Attr.value config.input
                , Ev.onInput config.onInput
                , Attr.placeholder "Search models…"
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
            [ Html.span [ Attr.class "sel-page-current-label" ] [ Html.text "Current: " ]
            , Html.span [ Attr.class "sel-page-current-name" ]
                [ Html.text (if config.activeModelName == "" then "none" else config.activeModelName) ]
            , Html.button
                [ Attr.class "sel-page-add-btn"
                , Ev.stopPropagationOn "click" (D.succeed ( config.onAdd, True ))
                , Attr.title "Add model"
                ]
                [ Html.text "+ Add" ]
            ]
        , if List.isEmpty config.models then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No models configured." ]

          else if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No models match your search." ]

          else
            Html.div
                [ Attr.class "sel-page-list"
                , Attr.id ("model-selector-list-" ++ config.sessionId)
                ]
                (List.indexedMap (\i m -> viewItem i m config) filtered)
        ]


viewItem : Int -> T.ModelInfo -> { a | sessionId : String, selected : Int, activeModelId : Maybe Int, confirmDeleteId : Maybe Int, canDelete : Bool, onSelect : Int -> msg, onConfirm : msg, noOp : msg, onEdit : Int -> msg, onDelete : Int -> msg, onDeleteConfirm : Int -> msg, onDeleteCancel : msg } -> Html msg
viewItem idx model config =
    let
        isSelected =
            idx == config.selected

        isActive =
            config.activeModelId == Just model.id

        isConfirmingDelete =
            config.confirmDeleteId == Just model.id

        stopClick msg =
            Ev.stopPropagationOn "click" (D.succeed ( msg, True ))
    in
    Html.div
        [ Attr.id ("model-selector-item-" ++ config.sessionId ++ "-" ++ String.fromInt model.id)
        , Attr.class ("sel-page-item"
            ++ (if isSelected then " sel-page-item-selected" else "")
            ++ (if isActive then " sel-page-item-active" else "")
          )
        , Ev.onClick (config.onSelect idx)
        , Ev.onDoubleClick config.onConfirm
        ]
        [ Html.span [ Attr.class "sel-page-item-id" ] [ Html.text (String.fromInt model.id) ]
        , Html.span [ Attr.class "sel-page-item-name" ] [ Html.text model.name ]
        , Html.span [ Attr.class "sel-page-item-check" ]
            [ if isActive then Html.text "●" else Html.text "" ]
        , if isConfirmingDelete then
            Html.span [ Attr.class "sel-page-item-actions" ]
                [ Html.button
                    [ Attr.class "sel-page-action sel-page-action-danger"
                    , stopClick (config.onDeleteConfirm model.id)
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
                    , Attr.disabled isActive
                    , Attr.title (if isActive then "Active model cannot be edited" else "Edit model")
                    , stopClick (config.onEdit model.id)
                    ]
                    [ Html.text "Edit" ]
                , Html.button
                    [ Attr.class "sel-page-action sel-page-action-danger"
                    , Attr.disabled (isActive || not config.canDelete)
                    , Attr.title
                        (if isActive then
                            "Active model cannot be deleted"

                         else if not config.canDelete then
                            "At least one model must remain"

                         else
                            "Delete model"
                        )
                    , stopClick (config.onDelete model.id)
                    ]
                    [ Html.text "Delete" ]
                ]
        ]


filterModels : List T.ModelInfo -> String -> List T.ModelInfo
filterModels models term =
    let
        trimmed =
            String.trim term
    in
    if String.isEmpty trimmed then
        models
    else
        List.filter (\m -> Fuzzy.fuzzyMatch (String.toLower trimmed) (String.toLower m.name)) models
