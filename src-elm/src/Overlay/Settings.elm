module Overlay.Settings exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev


view :
    { toolConfirm : String
    , builtinTools : String
    , loading : Bool
    , syncing : Bool
    , error : Maybe String
    , onInput : String -> msg
    , onBuiltinToolsInput : String -> msg
    , onSave : msg
    , onCancel : msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "me-page" ]
        [ Html.div [ Attr.class "me-page-header" ]
            [ Html.button [ Attr.class "me-back-btn", Ev.onClick config.onCancel ] [ Html.text "← Back" ]
            , Html.div [ Attr.class "me-page-title" ] [ Html.text "Settings" ]
            ]
        , if config.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else
            Html.div []
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
                            [ Html.text "Comma-separated tool IDs (no spaces). Empty = all tools (AlayaCore default). Passed as --builtin-tools=id1,id2 on new sessions. e.g. Safe preset omits execute_command." ]
                        ]
                    ]
                , Html.div [ Attr.class "me-actions" ]
                    [ Html.button
                        [ Attr.class "me-save-btn"
                        , Attr.disabled config.syncing
                        , Ev.onClick config.onSave
                        ]
                        [ Html.text (if config.syncing then "Saving…" else "Save") ]
                    , Html.button [ Attr.class "me-cancel-btn", Ev.onClick config.onCancel ]
                        [ Html.text "Cancel" ]
                    ]
                ]
        ]
