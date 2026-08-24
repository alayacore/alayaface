module Overlay.ModelEditor exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.Types as T


view :
    { sessionId : String
    , draft : T.ModelDraft
    , isNew : Bool
    , onSave : msg
    , onField : String -> String -> msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "me-page" ]
        [ Html.div [ Attr.class "me-fields" ]
            [ textField "name" "Name" config.draft.name config
            , selectField "protocol_type" "Protocol Type" [ "openai", "anthropic" ] config.draft.protocolType config
            , textField "base_url" "Base URL" config.draft.baseUrl config
            , textField "api_key" "API Key" config.draft.apiKey config
            , textField "model_name" "Model Name" config.draft.modelName config
            , textField "context_limit" "Context Limit" config.draft.contextLimit config
            , textField "max_tokens" "Max Tokens" config.draft.maxTokens config
            ]
        , Html.div [ Attr.class "me-actions" ]
            [ Html.button [ Attr.class "btn btn-primary", Ev.onClick config.onSave ] [ Html.text "Save" ]
            ]
        ]


textField : String -> String -> String -> { a | sessionId : String, onField : String -> String -> msg } -> Html msg
textField key label value config =
    Html.div [ Attr.class "me-field" ]
        [ Html.label [ Attr.class "me-field-label", Attr.for (inputId key config.sessionId) ] [ Html.text label ]
        , Html.input
            [ Attr.class "input"
            , Attr.id (inputId key config.sessionId)
            , Attr.type_ "text"
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
            [ Attr.class "input"
            , Attr.id (inputId key config.sessionId)
            , Ev.onInput (config.onField key)
            ]
            (List.map
                (\opt ->
                    Html.option
                        [ Attr.value opt
                        , Attr.selected (opt == value)
                        ]
                        [ Html.text opt ]
                )
                options
            )
        ]


inputId : String -> String -> String
inputId key sessionId =
    "model-editor-" ++ key ++ "-" ++ sessionId
