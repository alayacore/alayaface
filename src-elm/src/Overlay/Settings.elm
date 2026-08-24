module Overlay.Settings exposing (systemPromptRows, view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev


reasoningLevelName : Int -> String
reasoningLevelName lvl =
    case lvl of
        0 -> "Off"
        1 -> "Balanced"
        2 -> "Deep"
        _ -> String.fromInt lvl


{-| The System prompt textarea's row count follows its content
(auto-grow), capped at maxSystemPromptRows: a short prompt stays small
and a long one (e.g. the seeded plan-mode contract) scrolls instead of
taking over the page — the field has a MAXIMUM height, not a fixed one.
The +1 row leaves room for wrapped long lines (a long line wraps
visually but still counts as one line).
-}
systemPromptRows : String -> Int
systemPromptRows text =
    clamp 4 maxSystemPromptRows (List.length (String.lines text) + 1)


{-| Upper bound (rows) for the System prompt textarea: beyond this the
field scrolls internally.
-}
maxSystemPromptRows : Int
maxSystemPromptRows =
    20


view :
    { toolConfirm : String
    , builtinTools : String
    , systemPrompt : String
    , reasoningLevel : Int
    , loading : Bool
    , syncing : Bool
    , error : Maybe String
    , onInput : String -> msg
    , onBuiltinToolsInput : String -> msg
    , onSystemPromptInput : String -> msg
    , onReasoningLevelInput : Int -> msg
    , onSave : msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "me-page" ]
        [ if config.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else
            Html.div [ Attr.class "me-body" ]
                [ case config.error of
                    Just err ->
                        Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                            [ Html.text ("Failed to load settings: " ++ err) ]

                    Nothing ->
                        Html.text ""
                , Html.div [ Attr.class "me-fields" ]
                    [ Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Pre-approved tools" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "settings-tool-confirm"
                            , Attr.type_ "text"
                            , Attr.value config.toolConfirm
                            , Attr.placeholder "execute_command,search_files"
                            , Ev.onInput config.onInput
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Comma-separated tool IDs (no spaces). Empty = disabled. Passed to AlayaCore as --tool-confirm=id1,id2 on new sessions." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Built-in tools" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "settings-builtin-tools"
                            , Attr.type_ "text"
                            , Attr.value config.builtinTools
                            , Attr.placeholder "read_file,write_file,edit_file,execute_command,search_content"
                            , Ev.onInput config.onBuiltinToolsInput
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Comma-separated tool IDs (no spaces). Empty = all tools (AlayaCore default). Passed as --builtin-tools=id1,id2 on new sessions." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Reasoning level" ]
                        , Html.select
                            [ Attr.class "me-field-input me-field-select"
                            , Attr.id "settings-reasoning-level"
                            , Attr.disabled config.syncing
                            , Ev.onInput (\v -> config.onReasoningLevelInput (Maybe.withDefault 1 (String.toInt v)))
                            ]
                            (List.map
                                (\lvl ->
                                    Html.option
                                        [ Attr.value (String.fromInt lvl)
                                        , Attr.selected (config.reasoningLevel == lvl)
                                        ]
                                        [ Html.text (reasoningLevelName lvl) ]
                                )
                                [ 0, 1, 2 ]
                            )
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Initial reasoning level for new sessions of this preset. Passed to AlayaCore as --reasoning-level=0|1|2 (Off / Balanced / Deep). Can be changed per-session from the input bar." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "System prompt" ]
                        , Html.textarea
                            [ Attr.class "me-field-input me-field-textarea"
                            , Attr.id "settings-system-prompt"
                            , Attr.rows (systemPromptRows config.systemPrompt)
                            , Attr.value config.systemPrompt
                            , Attr.placeholder "System prompt passed to AlayaCore as --system on every new session of this preset."
                            , Ev.onInput config.onSystemPromptInput
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Passed to AlayaCore as --system on new sessions of this preset. Every session can create plans, so keep the plan-mode contract here (or in a copy of a seed preset)." ]
                        ]
                    ]
                , Html.div [ Attr.class "me-actions" ]
                    [ Html.button
                        [ Attr.class "btn btn-primary"
                        , Attr.disabled config.syncing
                        , Ev.onClick config.onSave
                        ]
                        [ Html.text (if config.syncing then "Saving…" else "Save") ]
                    ]
                ]
        ]
