module Overlay.HelpWindow exposing (HelpItem, filterHelpItems, view)

import Fuzzy
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D


type alias HelpItem =
    { id : Int
    , key : String
    , desc : String
    , isSection : Bool
    , isCommand : Bool
    }


view :
    { sessionId : String
    , items : List HelpItem
    , filter : String
    , selected : Int
    , noOp : msg
    , onFilter : String -> msg
    , onCmd : String -> msg
    }
    -> Html msg
view config =
    let
        filtered =
            filterHelpItems config.filter config.items

        inputId =
            "help-filter-input-" ++ config.sessionId
    in
    Html.div [ Attr.class "help-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Help" ]
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.id inputId
                , Attr.type_ "text"
                , Attr.value config.filter
                , Ev.onInput config.onFilter
                , Attr.placeholder "Filter command or key…"
                , Ev.preventDefaultOn "keydown" <|
                    D.map2 (\key ctrl ->
                        if key == "Enter" && not ctrl then
                            let
                                selectedItem =
                                    List.head (List.drop config.selected filtered)
                            in
                            case selectedItem of
                                Just item ->
                                    if item.isCommand then
                                        ( config.onCmd item.key, True )
                                    else
                                        ( config.noOp, False )

                                Nothing ->
                                    ( config.noOp, False )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool)
                ]
                []
            ]
        , if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No matching commands or keys." ]

          else
            Html.div
                [ Attr.class "sel-page-list"
                , Attr.id ("help-page-list-" ++ config.sessionId)
                ]
                (List.indexedMap (\i item -> viewItem i item config) filtered)
        ]


viewItem : Int -> HelpItem -> { a | sessionId : String, selected : Int, onCmd : String -> msg, noOp : msg } -> Html msg
viewItem idx item config =
    let
        isSelected =
            idx == config.selected
    in
    if item.isSection then
        Html.div
            [ Attr.id ("help-item-" ++ config.sessionId ++ "-" ++ String.fromInt idx)
            , Attr.class "help-page-section"
            ]
            [ Html.text ("── " ++ item.key) ]

    else
        Html.div
            [ Attr.id ("help-item-" ++ config.sessionId ++ "-" ++ String.fromInt idx)
            , Attr.class ("help-page-item"
                ++ (if isSelected then " help-page-item-selected" else "")
              )
            , Ev.onClick
                (if item.isCommand then
                    config.onCmd item.key
                 else
                    config.noOp
                )
            ]
            [ Html.span [ Attr.class "help-page-item-key" ] [ Html.text item.key ]
            , Html.span [ Attr.class "help-page-item-desc" ] [ Html.text item.desc ]
            ]


filterHelpItems : String -> List HelpItem -> List HelpItem
filterHelpItems term items =
    let
        trimmed =
            String.trim term
    in
    if String.isEmpty trimmed then
        items
    else
        let
            lower =
                String.toLower trimmed
        in
        List.filter
            (\item ->
                if item.isSection then
                    True
                else
                    Fuzzy.fuzzyMatch lower (String.toLower (item.key ++ " " ++ item.desc))
            )
            items



