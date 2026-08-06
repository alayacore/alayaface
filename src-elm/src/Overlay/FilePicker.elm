module Overlay.FilePicker exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Html.Keyed as Keyed
import Json.Decode as D
import Session.Types as T


view :
    { sessionId : String
    , entries : List T.DirEntry
    , input : String
    , filter : String
    , selected : Int
    , mode : T.FileMode
    , loading : Bool
    , title : String
    , placeholder : String
    , noOp : msg
    , onInput : String -> msg
    , onConfirm : msg
    , onPick : Int -> msg
    , onUrlConfirm : msg
    , onToggleMode : msg
    }
    -> Html msg
view config =
    let
        isUrlMode =
            config.mode == T.Url

        inputId =
            "fp-page-input-" ++ config.sessionId
    in
    Html.div [ Attr.class "fp-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text config.title ]
        , Html.div [ Attr.class "fp-page-input-row" ]
            [ Html.button
                [ Attr.class "fp-page-prefix"
                , Ev.onClick config.onToggleMode
                , Attr.title "Toggle mode"
                ]
                [ Html.text (if isUrlMode then "URL" else "File") ]
            , Html.input
                [ Attr.id inputId
                , Attr.class "fp-page-input"
                , Attr.type_ "text"
                , Attr.value config.input
                , Ev.onInput config.onInput
                , Attr.placeholder config.placeholder
                , Ev.preventDefaultOn "keydown" <|
                    D.map2 (\key ctrl ->
                        -- Backspace at root "/": prevent deletion (no parent)
                        if key == "Backspace" && config.input == "/" && not isUrlMode then
                            ( config.noOp, True )

                        -- Enter confirms (URL mode or local file/dir)
                        else if key == "Enter" && not ctrl then
                            if isUrlMode then
                                ( config.onUrlConfirm, True )
                            else
                                ( config.onConfirm, True )

                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool)
                ]
                []
            ]
        , if config.loading then
            Html.div [ Attr.class "fp-page-status" ] [ Html.text "Loading…" ]

          else if isUrlMode then
            Html.div [ Attr.class "fp-page-status" ] [ Html.text "Press Enter to attach URL" ]

          else if List.isEmpty config.entries then
            Html.div [ Attr.class "fp-page-status" ] [ Html.text "No files found" ]

          else
            let
                keyedEntries =
                    List.indexedMap (\i e -> ( e.name, viewEntry i e config )) config.entries
            in
            Keyed.node "div"
                [ Attr.class "fp-page-list"
                , Attr.id ("fp-page-list-" ++ config.sessionId)
                ]
                keyedEntries
        ]


viewEntry : Int -> T.DirEntry -> { a | sessionId : String, selected : Int, onPick : Int -> msg } -> Html msg
viewEntry idx entry config =
    Html.div
        [ Attr.id ("fp-item-" ++ config.sessionId ++ "-" ++ entry.name)
        , Attr.class ("fp-page-item" ++ (if idx == config.selected then " fp-page-item-selected" else ""))
        , Ev.onClick (config.onPick idx)
        ]
        [ Html.span [ Attr.class "fp-page-item-icon" ] [ Html.text (if entry.isDir then "📁" else "📄") ]
        , Html.span [ Attr.class "fp-page-item-name" ] [ Html.text entry.name ]
        ]
