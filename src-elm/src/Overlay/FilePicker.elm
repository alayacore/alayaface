module Overlay.FilePicker exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Html.Keyed as Keyed
import Json.Decode as D
import Session.Types as T


view :
    { entries : List T.DirEntry
    , input : String
    , filter : String
    , selected : Int
    , mode : T.FileMode
    , loading : Bool
    , noOp : msg
    , onInput : String -> msg
    , onSelect : Int -> msg
    , onConfirm : msg
    , onUrlConfirm : msg
    , onToggleMode : msg
    , focusInput : msg
    , focusList : msg
    }
    -> Html msg
view config =
    let
        isUrlMode =
            config.mode == T.Url

        placeholder =
            if isUrlMode then
                "Paste a URL…"
            else
                "Type a path or filter files…"

        modeLabel =
            if isUrlMode then "URL" else "Local"

        filteredLen =
            List.length config.entries
    in
    Html.div [ Attr.class "fp-page" ]
        [ Html.div [ Attr.class "fp-page-input-row" ]
            [ Html.span [ Attr.class "fp-page-prefix" ]
                [ Html.text (if isUrlMode then "U" else "F") ]
            , Html.input
                [ Attr.id "fp-page-input"
                , Attr.class "fp-page-input"
                , Attr.type_ "text"
                , Attr.value config.input
                , Ev.onInput config.onInput
                , Attr.placeholder placeholder
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map5 (\key ctrl alt shift code ->
                        -- Ctrl+A toggles mode
                        if key == "a" && ctrl && not alt then
                            ( config.onToggleMode, True )

                        -- Backspace at root "/": prevent deletion (no parent)
                        else if key == "Backspace" && config.input == "/" && not isUrlMode then
                            ( config.noOp, True )

                        -- Enter confirms (URL mode or local file/dir)
                        else if key == "Enter" && not ctrl then
                            if isUrlMode then
                                ( config.onUrlConfirm, True )
                            else
                                ( config.onConfirm, True )

                        -- Arrow keys navigate list (local mode only)
                        else if key == "ArrowDown" && not ctrl && not alt && not shift && not isUrlMode then
                            let
                                newIdx =
                                    min (config.selected + 1) (max 0 (filteredLen - 1))
                            in
                            ( config.onSelect newIdx, True )

                        else if key == "ArrowUp" && not ctrl && not alt && not shift && not isUrlMode then
                            let
                                newIdx =
                                    max 0 (config.selected - 1)
                            in
                            ( config.onSelect newIdx, True )

                        -- Tab switches focus to list
                        else if key == "Tab" && not shift then
                            ( config.focusList, True )

                        -- Shift+Tab returns focus to input
                        else if key == "Tab" && shift then
                            ( config.focusInput, True )

                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool) (D.field "code" D.string)
                ]
                []
            , Html.div [ Attr.class "fp-page-mode" ]
                [ Html.text modeLabel ]
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
                , Attr.id "fp-page-list"
                , Attr.tabindex 0
                , Ev.preventDefaultOn "keydown" <|
                    D.map5 (\key ctrl alt shift code ->
                        let
                            entriesLen =
                                List.length config.entries
                        in
                        if key == "Tab" && shift then
                            ( config.focusInput, True )
                        else if key == "Tab" && not shift then
                            ( config.focusInput, True )
                        else if key == "Enter" && not ctrl then
                            ( config.onConfirm, True )
                        else if key == "ArrowDown" || (key == "j" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    min (config.selected + 1) (max 0 (entriesLen - 1))
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
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool) (D.field "code" D.string)
                ]
                keyedEntries
        ]


viewEntry : Int -> T.DirEntry -> { a | selected : Int, onConfirm : msg } -> Html msg
viewEntry idx entry config =
    Html.div
        [ Attr.id ("fp-item-" ++ entry.name)
        , Attr.class ("fp-page-item" ++ (if idx == config.selected then " fp-page-item-selected" else ""))
        , Ev.onClick
            (config.onConfirm)
        ]
        [ Html.span [ Attr.class "fp-page-item-icon" ] [ Html.text (if entry.isDir then "📁" else "📄") ]
        , Html.span [ Attr.class "fp-page-item-name" ] [ Html.text entry.name ]
        ]
