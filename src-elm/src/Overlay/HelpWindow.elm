module Overlay.HelpWindow exposing (HelpItem, helpItems, filterHelpItems, nextSelectable, view)

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
    { items : List HelpItem
    , filter : String
    , selected : Int
    , noOp : msg
    , onFilter : String -> msg
    , onSelect : Int -> msg
    , onCmd : String -> msg
    , focusInput : msg
    , focusList : msg
    }
    -> Html msg
view config =
    let
        filtered =
            filterHelpItems config.filter config.items
    in
    Html.div [ Attr.class "help-page" ]
        [ Html.div [ Attr.class "sel-page-title" ] [ Html.text "Help" ]
        , Html.div [ Attr.class "sel-page-input-row" ]
            [ Html.input
                [ Attr.class "sel-page-input"
                , Attr.id "help-filter-input"
                , Attr.type_ "text"
                , Attr.value config.filter
                , Ev.onInput config.onFilter
                , Attr.placeholder "Filter command or key…"
                , Attr.autofocus True
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        if key == "Tab" then
                            ( config.focusList, True )
                        else if key == "Enter" && not ctrl then
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
                        else if key == "ArrowDown" then
                            let
                                newIdx =
                                    nextSelectable config.selected filtered
                            in
                            ( config.onSelect newIdx, True )
                        else if key == "ArrowUp" then
                            let
                                newIdx =
                                    prevSelectable config.selected filtered
                            in
                            ( config.onSelect newIdx, True )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                []
            ]
        , if List.isEmpty filtered then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "No matching commands or keys." ]

          else
            Html.div
                [ Attr.class "sel-page-list"
                , Attr.id "help-page-list"
                , Attr.tabindex 0
                , Ev.preventDefaultOn "keydown" <|
                    D.map4 (\key ctrl alt shift ->
                        if key == "Tab" then
                            ( config.focusInput, True )
                        else if key == "Enter" && not ctrl then
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
                        else if key == "ArrowDown" || (key == "j" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    nextSelectable config.selected filtered
                            in
                            ( config.onSelect newIdx, True )
                        else if key == "ArrowUp" || (key == "k" && not ctrl && not alt && not shift) then
                            let
                                newIdx =
                                    prevSelectable config.selected filtered
                            in
                                ( config.onSelect newIdx, True )
                        else
                            ( config.noOp, False )
                    ) (D.field "key" D.string) (D.field "ctrlKey" D.bool) (D.field "altKey" D.bool) (D.field "shiftKey" D.bool)
                ]
                (List.indexedMap (\i item -> viewItem i item config) filtered)
        ]


viewItem : Int -> HelpItem -> { a | selected : Int, onSelect : Int -> msg, onCmd : String -> msg, noOp : msg } -> Html msg
viewItem idx item config =
    let
        isSelected =
            idx == config.selected
    in
    if item.isSection then
        Html.div
            [ Attr.id ("help-item-" ++ String.fromInt idx)
            , Attr.class "help-page-section"
            ]
            [ Html.text ("── " ++ item.key) ]

    else
        Html.div
            [ Attr.id ("help-item-" ++ String.fromInt idx)
            , Attr.class ("help-page-item"
                ++ (if isSelected then " help-page-item-selected" else "")
              )
            , Ev.onMouseEnter (config.onSelect idx)
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


-- Navigate to next/previous selectable (non-section) item

nextSelectable : Int -> List HelpItem -> Int
nextSelectable current items =
    let
        len =
            List.length items
    in
    if len == 0 then
        0

    else
        let
            search =
                List.range (current + 1) (len - 1)
        in
        case List.filter (\i -> not (isSectionAt i items)) search of
            idx :: _ ->
                idx

            [] ->
                current


prevSelectable : Int -> List HelpItem -> Int
prevSelectable current items =
    let
        len =
            List.length items
    in
    if len == 0 then
        0

    else
        let
            search =
                List.range 0 (current - 1) |> List.reverse
        in
        case List.filter (\i -> not (isSectionAt i items)) search of
            idx :: _ ->
                idx

            [] ->
                current


isSectionAt : Int -> List HelpItem -> Bool
isSectionAt idx items =
    case List.head (List.drop idx items) of
        Just item ->
            item.isSection

        Nothing ->
            False


helpItems : List HelpItem
helpItems =
    [ { id = 1, key = "Commands", desc = "", isSection = True, isCommand = False }
    , { id = 2, key = ":tool_confirm <id>", desc = "Confirm pending tool", isSection = False, isCommand = True }
    , { id = 3, key = ":tool_decline <id>", desc = "Decline pending tool", isSection = False, isCommand = True }
    , { id = 4, key = ":mcp_confirm <server> <code> <redirect_uri>", desc = "Confirm OAuth authorization", isSection = False, isCommand = True }
    , { id = 5, key = ":mcp_decline <server>", desc = "Decline OAuth authorization", isSection = False, isCommand = True }
    , { id = 6, key = ":continue", desc = "Retry last prompt", isSection = False, isCommand = True }
    , { id = 7, key = ":reason <0|1|2>", desc = "Set reasoning level", isSection = False, isCommand = True }
    , { id = 8, key = ":cancel", desc = "Cancel current task", isSection = False, isCommand = True }
    , { id = 9, key = ":summarize", desc = "Summarize & compress history", isSection = False, isCommand = True }
    , { id = 10, key = ":theme_set <name>", desc = "Switch theme by name", isSection = False, isCommand = True }
    , { id = 11, key = ":model_set <id>", desc = "Switch model by ID", isSection = False, isCommand = True }
    , { id = 12, key = ":model_load", desc = "Reload model config", isSection = False, isCommand = True }
    , { id = 13, key = ":model_sync", desc = "Apply edited model config", isSection = False, isCommand = True }
    , { id = 14, key = ":save [filename]", desc = "Save session", isSection = False, isCommand = True }
    , { id = 15, key = ":fork <id> <filename>", desc = "Fork session up to content", isSection = False, isCommand = True }
    , { id = 16, key = ":video_config <fps> <0|1>", desc = "Set video FPS and resolution", isSection = False, isCommand = True }
    , { id = 17, key = ":suspend", desc = "Suspend process", isSection = False, isCommand = True }
    , { id = 18, key = ":quit", desc = "Exit application", isSection = False, isCommand = True }
    , { id = 19, key = ":help", desc = "Open help window", isSection = False, isCommand = True }
    , { id = 20, key = "Global Shortcuts", desc = "", isSection = True, isCommand = False }
    , { id = 21, key = "Tab", desc = "Toggle focus display/input", isSection = False, isCommand = False }
    , { id = 22, key = "Enter", desc = "Submit prompt or command", isSection = False, isCommand = False }
    , { id = 23, key = "Ctrl+H", desc = "Open help window", isSection = False, isCommand = False }
    , { id = 24, key = "Ctrl+G", desc = "Cancel current task", isSection = False, isCommand = False }
    , { id = 25, key = "Ctrl+C", desc = "Clear text", isSection = False, isCommand = False }
    , { id = 26, key = "Ctrl+S", desc = "Save session", isSection = False, isCommand = False }
    , { id = 27, key = "Ctrl+A", desc = "Open attachment picker", isSection = False, isCommand = False }
    , { id = 28, key = "Ctrl+L", desc = "Open model selector", isSection = False, isCommand = False }
    , { id = 29, key = "Ctrl+R", desc = "Force redraw screen", isSection = False, isCommand = False }
    , { id = 30, key = "Ctrl+P", desc = "Open theme selector", isSection = False, isCommand = False }
    , { id = 31, key = "Ctrl+Z", desc = "Suspend process", isSection = False, isCommand = False }
    , { id = 32, key = "Display Mode", desc = "", isSection = True, isCommand = False }
    , { id = 33, key = "j/k", desc = "Move window cursor", isSection = False, isCommand = False }
    , { id = 34, key = "J/K", desc = "Scroll one line", isSection = False, isCommand = False }
    , { id = 35, key = "Ctrl+D/U", desc = "Scroll half screen", isSection = False, isCommand = False }
    , { id = 36, key = "g", desc = "Go to first window", isSection = False, isCommand = False }
    , { id = 37, key = "G", desc = "Follow the last window", isSection = False, isCommand = False }
    , { id = 38, key = "H/L/M", desc = "Cursor top/btm/mid", isSection = False, isCommand = False }
    , { id = 39, key = "e", desc = "Open in editor", isSection = False, isCommand = False }
    , { id = 40, key = "f/b", desc = "Next/prev prompt", isSection = False, isCommand = False }
    , { id = 41, key = ":", desc = "Enter command mode", isSection = False, isCommand = False }
    , { id = 42, key = "Space", desc = "Toggle window fold", isSection = False, isCommand = False }
    , { id = 43, key = "Ctrl+F", desc = "Fork session from cursor", isSection = False, isCommand = False }
    ]
