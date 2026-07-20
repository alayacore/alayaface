module Overlay.ModelSelector exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D
import Session.Types as T


view :
    { models : List T.ModelInfo
    , input : String
    , selected : Int
    , activeModelId : Maybe Int
    , activeModelName : String
    , noOp : msg
    , onSelect : Int -> msg
    , onConfirm : msg
    , onClose : msg
    , onInput : String -> msg
    , focusInput : msg
    , focusList : msg
    }
    -> Html msg
view config =
    let
        filtered =
            filterModels config.models config.input
    in
    Html.div [ Attr.class "sel-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Model Selector" ]
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.id "model-selector-input"
                , Attr.type_ "text"
                , Attr.value config.input
                , Ev.onInput config.onInput
                , Attr.placeholder "Search models…"
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        if key == "Tab" then
                            ( config.focusList, True )
                        else if key == "Enter" && not ctrl then
                            ( config.onConfirm, True )
                        else if key == "ArrowDown" then
                            let
                                newIdx =
                                    min (config.selected + 1) (max 0 (List.length filtered - 1))
                            in
                            ( config.onSelect newIdx, True )
                        else if key == "ArrowUp" then
                            let
                                newIdx =
                                    max 0 (config.selected - 1)
                            in
                            ( config.onSelect newIdx, True )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                []
            ]
        , if config.activeModelName /= "" then
            Html.div [ Attr.class "sel-page-current" ]
                [ Html.span [ Attr.class "sel-page-current-label" ] [ Html.text "Current: " ]
                , Html.span [ Attr.class "sel-page-current-name" ] [ Html.text config.activeModelName ]
                ]

          else
            Html.text ""
        , if List.isEmpty config.models then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No models configured." ]

          else if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No models match your search." ]

          else
            Html.div
                [ Attr.class "sel-page-list"
                , Attr.id "model-selector-list"
                , Attr.tabindex 0
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        let
                            filteredLen =
                                List.length filtered
                        in
                        if key == "Tab" then
                            ( config.focusInput, True )
                        else if key == "Enter" && not ctrl then
                            ( config.onConfirm, True )
                        else if key == "ArrowDown" || (key == "j" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    min (config.selected + 1) (max 0 (filteredLen - 1))
                            in
                            ( config.onSelect newIdx, True )
                        else if key == "ArrowUp" || (key == "k" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    max 0 (config.selected - 1)
                            in
                            ( config.onSelect newIdx, True )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                (List.indexedMap (\i m -> viewItem i m config) filtered)
        ]


viewItem : Int -> T.ModelInfo -> { a | selected : Int, activeModelId : Maybe Int, onSelect : Int -> msg, onConfirm : msg, noOp : msg } -> Html msg
viewItem idx model config =
    let
        isSelected =
            idx == config.selected

        isActive =
            config.activeModelId == Just model.id
    in
    Html.div
        [ Attr.id ("model-selector-item-" ++ String.fromInt model.id)
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
        List.filter (\m -> fuzzyMatch (String.toLower trimmed) (String.toLower m.name)) models


fuzzyMatch : String -> String -> Bool
fuzzyMatch search target =
    if String.isEmpty search then
        True
    else if String.length search > String.length target then
        False
    else
        let
            searchChars =
                String.toList search

            targetChars =
                String.toList target
        in
        fuzzyMatchHelp searchChars targetChars


fuzzyMatchHelp : List Char -> List Char -> Bool
fuzzyMatchHelp search target =
    case search of
        [] ->
            True

        s :: restSearch ->
            case target of
                [] ->
                    False

                t :: restTarget ->
                    if s == t then
                        fuzzyMatchHelp restSearch restTarget
                    else
                        fuzzyMatchHelp search restTarget
