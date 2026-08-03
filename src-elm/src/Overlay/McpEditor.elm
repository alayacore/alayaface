module Overlay.McpEditor exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.Types as T


view :
    { sessionId : String
    , draft : T.McpDraft
    , isNew : Bool
    , onBack : msg
    , onSave : msg
    , onField : String -> String -> msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "me-page" ]
        [ Html.div [ Attr.class "me-page-header" ]
            [ Html.button [ Attr.class "me-back-btn", Ev.onClick config.onBack ] [ Html.text "← Back" ]
            , Html.div [ Attr.class "me-page-title" ]
                [ Html.text (if config.isNew then "Add MCP Server" else "Edit MCP Server") ]
            ]
        , Html.div [ Attr.class "me-fields" ]
            [ selectField "type" "Type" [ "http", "stdio" ] config.draft.type_ config
            , textField "server" "Server Name" config.draft.server config
            , if config.draft.type_ == "http" then
                textField "url" "URL" config.draft.url config

              else
                Html.text ""
            , if config.draft.type_ == "stdio" then
                Html.div []
                    [ textField "command" "Command" config.draft.command config
                    , textAreaField "args" "Args (JSON array)" config.draft.args config
                    , textAreaField "env" "Env (JSON object)" config.draft.env config
                    ]

              else
                Html.text ""
            , if config.draft.type_ == "http" then
                Html.div []
                    [ selectField "auth-type" "Auth Type" [ "", "none", "static", "authorization_code" ] config.draft.authType config
                    , if config.draft.authType == "authorization_code" then
                        Html.div []
                            [ textField "auth-client-id" "Auth Client ID" config.draft.authClientId config
                            , textField "auth-client-secret" "Auth Client Secret" config.draft.authClientSecret config
                            ]

                      else if config.draft.authType == "static" then
                        textField "auth-token" "Auth Token" config.draft.authToken config

                      else
                        Html.text ""
                    ]

              else
                Html.text ""
            , selectField "proto-version" "Proto Version" (protoVersionOptions config.draft.protoVersion) config.draft.protoVersion config
            ]
        , Html.div [ Attr.class "me-actions" ]
            [ Html.button [ Attr.class "me-save-btn", Ev.onClick config.onSave ] [ Html.text "Save" ]
            , Html.button [ Attr.class "me-cancel-btn", Ev.onClick config.onBack ] [ Html.text "Cancel" ]
            ]
        ]


textField : String -> String -> String -> { a | sessionId : String, onField : String -> String -> msg } -> Html msg
textField key label value config =
    Html.div [ Attr.class "me-field" ]
        [ Html.label [ Attr.class "me-field-label", Attr.for (inputId key config.sessionId) ] [ Html.text label ]
        , Html.input
            [ Attr.class "me-field-input"
            , Attr.id (inputId key config.sessionId)
            , Attr.type_ "text"
            , Attr.value value
            , Ev.onInput (config.onField key)
            ]
            []
        ]


textAreaField : String -> String -> String -> { a | sessionId : String, onField : String -> String -> msg } -> Html msg
textAreaField key label value config =
    Html.div [ Attr.class "me-field" ]
        [ Html.label [ Attr.class "me-field-label", Attr.for (inputId key config.sessionId) ] [ Html.text label ]
        , Html.textarea
            [ Attr.class "me-field-input me-field-textarea"
            , Attr.id (inputId key config.sessionId)
            , Attr.rows 2
            , Attr.spellcheck False
            , Attr.value value
            , Ev.onInput (config.onField key)
            ]
            []
        ]


selectField : String -> String -> List String -> String -> { a | sessionId : String, onField : String -> String -> msg } -> Html msg
selectField key label options value config =
    Html.div [ Attr.class "me-field" ]
        [ Html.label [ Attr.class "me-field-label", Attr.for (inputId key config.sessionId) ] [ Html.text label ]
        , Html.select
            [ Attr.class "me-field-input"
            , Attr.id (inputId key config.sessionId)
            , Ev.onInput (config.onField key)
            ]
            (List.map
                (\opt ->
                    Html.option
                        [ Attr.value opt
                        , Attr.selected (opt == value)
                        ]
                        [ Html.text (if opt == "" then "(none)" else opt) ]
                )
                options
            )
        ]


inputId : String -> String -> String
inputId key sessionId =
    "mcp-editor-" ++ key ++ "-" ++ sessionId


protoVersionOptions : String -> List String
protoVersionOptions current =
    let
        known =
            [ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28" ]
    in
    if current == "" || List.member current known then
        known
    else
        -- Keep unknown (e.g. future) versions selectable without data loss
        known ++ [ current ]
