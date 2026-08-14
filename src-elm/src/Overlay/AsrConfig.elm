module Overlay.AsrConfig exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev


{-| Voice-input ASR config overlay (~/.alayaface/asr.conf).

Two wire protocols: "transcriptions" (OpenAI-compatible multipart
upload, default — local and remote differ only by URL) and
"chat_completions" (MiMo-style JSON body + api-key header). The user
enters the FULL endpoint address (including the method path) and it is
used verbatim; the backend never appends anything. The model id is
passed through verbatim; the endpoint decides how to use it. Language
"auto" means the field is omitted (transcriptions) / autodetect
(chat_completions).
-}
view :
    { protocol : String
    , url : String
    , apiKey : String
    , model : String
    , language : String
    , loading : Bool
    , syncing : Bool
    , error : Maybe String
    , onProtocol : String -> msg
    , onUrl : String -> msg
    , onApiKey : String -> msg
    , onModel : String -> msg
    , onLanguage : String -> msg
    , onSave : msg
    , onCancel : msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "me-page" ]
        [ Html.div [ Attr.class "me-page-header" ]
            [ Html.button [ Attr.class "me-back-btn", Ev.onClick config.onCancel ] [ Html.text "← Back" ]
            , Html.div [ Attr.class "me-page-title" ] [ Html.text "ASR config" ]
            ]
        , if config.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else
            Html.div [ Attr.class "me-body" ]
                [ case config.error of
                    Just err ->
                        Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                            [ Html.text ("Failed to save ASR config: " ++ err) ]

                    Nothing ->
                        Html.text ""
                , Html.div [ Attr.class "me-fields" ]
                    [ Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Protocol" ]
                        , Html.select
                            [ Attr.class "me-field-input me-field-select"
                            , Attr.id "asr-config-protocol"
                            , Ev.onInput config.onProtocol
                            ]
                            [ Html.option [ Attr.value "transcriptions", Attr.selected (config.protocol == "transcriptions") ]
                                [ Html.text "OpenAI /audio/transcriptions (multipart upload)" ]
                            , Html.option [ Attr.value "chat_completions", Attr.selected (config.protocol == "chat_completions") ]
                                [ Html.text "Chat completions (MiMo-style, JSON + api-key)" ]
                            ]
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "\"transcriptions\": OpenAI-compatible multipart upload (most local whisper servers). \"chat_completions\": JSON body with input_audio base64 and api-key header (e.g. MiMo)." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Endpoint URL" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "asr-config-url"
                            , Attr.type_ "text"
                            , Attr.value config.url
                            , Attr.placeholder "http://127.0.0.1:8080/v1/audio/transcriptions  or  https://api.xiaomimimo.com/v1/chat/completions"
                            , Ev.onInput config.onUrl
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Full endpoint address (including the method path) — used exactly as entered, nothing is appended. Local and remote ASR use the same protocol; only the address differs." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "API key" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "asr-config-api-key"
                            , Attr.type_ "password"
                            , Attr.value config.apiKey
                            , Attr.placeholder "sk-… (empty = no Authorization header; local endpoints usually don't need one)"
                            , Ev.onInput config.onApiKey
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Sent as Authorization: Bearer <key>. Leave empty for local servers that don't require it." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Model" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "asr-config-model"
                            , Attr.type_ "text"
                            , Attr.value config.model
                            , Attr.placeholder "whisper-1"
                            , Ev.onInput config.onModel
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Passed through to the endpoint as the `model` form field. The endpoint decides how to use it (many local servers ignore it)." ]
                        ]
                    , Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Language" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "asr-config-language"
                            , Attr.type_ "text"
                            , Attr.value config.language
                            , Attr.placeholder "auto (zh, en, ja, …)"
                            , Ev.onInput config.onLanguage
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Whisper language code. \"auto\" (default) omits the field so the endpoint autodetects." ]
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
