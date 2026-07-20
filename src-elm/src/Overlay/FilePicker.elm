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
    , dir : String
    , mode : T.FileMode
    , loading : Bool
    , noOp : msg
    , onInput : String -> msg
    , onSelect : Int -> msg
    , onConfirm : msg
    , onUrlConfirm : msg
    , onToggleMode : msg
    , onNavigateDir : String -> msg
    , focusInput : msg
    , focusList : msg
    }
    -> Html msg
view config =
    let
        inputIsUrl =
            isUrl (String.trim config.input)

        isUrlMode =
            config.mode == T.Url

        placeholder =
            if isUrlMode then
                "Paste a URL…"
            else
                "Type a file name or path…"

        modeLabel =
            if isUrlMode then "URL" else "Local"

        filteredLen =
            List.length config.entries
    in
    Html.div [ Attr.class "fp-page" ]
        [ Html.div [ Attr.class "fp-page-input-row" ]
            [ Html.input
                [ Attr.id "fp-page-input"
                , Attr.class "fp-page-input"
                , Attr.type_ "text"
                , Attr.value config.input
                , Ev.onInput config.onInput
                , Attr.placeholder placeholder
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        -- Ctrl+A toggles mode
                        if key == "a" && ctrl && not alt then
                            ( config.onToggleMode, True )
                        -- Enter confirms (URL mode or local file)
                        else if key == "Enter" && not ctrl then
                            if isUrlMode then
                                ( config.onUrlConfirm, True )
                            else
                                ( config.onConfirm, True )
                        -- Arrow keys navigate list
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
                        -- Tab switches to list
                        else if key == "Tab" then
                            ( config.focusList, True )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                []
            , Html.div [ Attr.class "fp-page-mode" ]
                [ Html.text modeLabel ]
            ]
        , Html.div [ Attr.class "fp-page-dir" ]
            [ if isUrlMode then
                Html.text "Paste a URL and press Enter to attach"
              else
                Html.text (shortenPath config.dir)
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
                    D.map4 (\key ctrl alt shift ->
                        let
                            entriesLen =
                                List.length config.entries
                        in
                        if key == "Tab" then
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
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                keyedEntries
        ]


viewEntry : Int -> T.DirEntry -> { a | selected : Int, onSelect : Int -> msg, onConfirm : msg, onNavigateDir : String -> msg } -> Html msg
viewEntry idx entry config =
    Html.div
        [ Attr.id ("fp-item-" ++ entry.name)
        , Attr.class ("fp-page-item" ++ (if idx == config.selected then " fp-page-item-selected" else ""))
        , Ev.onClick
            (if entry.isDir then
                config.onNavigateDir entry.name

             else
                config.onConfirm
            )
        ]
        [ Html.span [ Attr.class "fp-page-item-icon" ] [ Html.text (if entry.isDir then "📁" else "📄") ]
        , Html.span [ Attr.class "fp-page-item-name" ] [ Html.text entry.name ]
        ]


shortenPath : String -> String
shortenPath path =
    if path == "" then
        ""
    else
        let
            parts =
                String.split "/" path

            numParts =
                List.length parts
        in
        if numParts <= 4 then
            path
        else
            let
                first =
                    Maybe.withDefault "" (List.head parts)

                lastFew =
                    List.drop (numParts - 3) parts |> String.join "/"
            in
            first ++ "/…/" ++ lastFew


isUrl : String -> Bool
isUrl s =
    String.startsWith "http://" s || String.startsWith "https://" s
