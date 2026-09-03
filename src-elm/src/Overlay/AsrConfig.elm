module Overlay.AsrConfig exposing (ProfileRow, defaultModel, protocolDisplayName, view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev


{-| Voice-input ASR config overlay (~/.alayaface/asr.conf): a LIST of
ASR endpoint profiles with one active profile, plus the add/edit FORM
(the original single-endpoint page). Three wire protocols per profile:
"transcriptions" (OpenAI-compatible multipart upload, default),
"chat_completions" (OpenAI standard chat completions JSON body +
api-key header) and "step_audio" (StepFun StepAudio realtime ASR). The
user enters the FULL endpoint address (including the method path); the
backend uses it verbatim.
-}


type alias ProfileRow =
    { id : String
    , name : String
    , protocol : String
    , url : String
    , isActive : Bool
    }


view :
    { inForm : Bool
    , profiles : List ProfileRow
    , loading : Bool
    , syncing : Bool
    , confirmDelete : Maybe String
    , error : Maybe String
      -- Form fields
    , isNew : Bool
    , name : String
    , protocol : String
    , url : String
    , apiKey : String
    , model : String
    , language : String
      -- List callbacks
    , onAdd : msg
    , onEdit : String -> msg
    , onSetActive : String -> msg
    , onDelete : String -> msg
    , onDeleteConfirm : msg
    , onDeleteCancel : msg
      -- Form callbacks
    , onName : String -> msg
    , onProtocol : String -> msg
    , onUrl : String -> msg
    , onApiKey : String -> msg
    , onModel : String -> msg
    , onLanguage : String -> msg
    , onSave : msg
    , onBack : msg
    }
    -> Html msg
view cfg =
    if cfg.inForm then
        formView cfg

    else
        listView cfg


{-| Human-readable protocol name, shared by the profile list rows and
the edit-form dropdown (one source of truth). Unknown values (e.g. a
hand-edited asr.conf) are shown verbatim instead of being silently
mislabeled as "transcriptions".
-}
protocolDisplayName : String -> String
protocolDisplayName protocol =
    case protocol of
        "chat_completions" ->
            "OpenAI /chat/completions (JSON + api-key)"

        "step_audio" ->
            "StepAudio (StepFun, raw PCM + SSE)"

        "transcriptions" ->
            "OpenAI /audio/transcriptions (multipart upload)"

        other ->
            other ++ " (unknown protocol)"


{-| The model id the backend applies when the model field is left empty,
per wire protocol (mirrors Go's `DefaultAsrModel` / Rust's
`default_asr_model`). The edit form swaps this in when the protocol
changes, so picking StepAudio does not keep sending a whisper model id to
StepFun — the backend default alone cannot fix that, because the form
prefills "whisper-1" (non-empty) and normalization keeps explicit values.
-}
defaultModel : String -> String
defaultModel protocol =
    case protocol of
        "step_audio" ->
            "stepaudio-2.5-asr"

        _ ->
            "whisper-1"


-- ─── List view (entry point from the system menu) ──────────────────

listView cfg =
    Html.div [ Attr.class "me-page" ]
        [ if cfg.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else
            Html.div [ Attr.class "me-body" ]
                [ case cfg.error of
                    Just err ->
                        Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                            [ Html.text ("ASR config error: " ++ err) ]

                    Nothing ->
                        Html.text ""
                , Html.div [ Attr.class "me-hint asr-list-hint" ]
                    [ Html.text "Voice input uses the ACTIVE endpoint. Add as many ASR endpoints as you like (local whisper, OpenAI-compatible, …) and switch between them — Edit opens the endpoint form." ]
                , if List.isEmpty cfg.profiles then
                    Html.div [ Attr.class "sel-page-status" ]
                        [ Html.text "No ASR endpoints yet — add one to enable voice input." ]

                  else
                    Html.div [ Attr.class "asr-list" ]
                        (List.map (profileRow cfg) cfg.profiles)
                , Html.div [ Attr.class "me-actions" ]
                    [ Html.button
                        [ Attr.class "btn btn-primary"
                        , Attr.disabled cfg.syncing
                        , Ev.onClick cfg.onAdd
                        ]
                        [ Html.text "Add endpoint" ]
                    ]
                ]
        ]


profileRow : { c | onEdit : String -> msg, onSetActive : String -> msg, onDelete : String -> msg, onDeleteConfirm : msg, onDeleteCancel : msg, confirmDelete : Maybe String, syncing : Bool } -> ProfileRow -> Html msg
profileRow cfg p =
    let
        armed =
            cfg.confirmDelete == Just p.id
    in
    Html.div [ Attr.class "asr-row" ]
        [ Html.div [ Attr.class "asr-row-main" ]
            [ Html.div [ Attr.class "asr-row-name" ]
                [ Html.text p.name
                , if p.isActive then
                    Html.span [ Attr.class "asr-row-active" ] [ Html.text "active" ]

                  else
                    Html.text ""
                ]
            , Html.div [ Attr.class "asr-row-meta" ]
                [ Html.text (protocolDisplayName p.protocol ++ " · " ++ p.url) ]
            ]
        , Html.div [ Attr.class "asr-row-actions" ]
            [ if p.isActive then
                Html.text ""

              else
                Html.button
                    [ Attr.class "btn btn-success-outline btn-sm"
                    , Attr.disabled cfg.syncing
                    , Attr.title "Use this endpoint for voice input"
                    , Ev.onClick (cfg.onSetActive p.id)
                    ]
                    [ Html.text "Use" ]
            , Html.button
                [ Attr.class "btn btn-sm"
                , Attr.disabled cfg.syncing
                , Ev.onClick (cfg.onEdit p.id)
                ]
                [ Html.text "Edit" ]
            , if armed then
                Html.span [ Attr.class "asr-row-confirm" ]
                    [ Html.button
                        [ Attr.class "btn btn-danger btn-sm"
                        , Attr.disabled cfg.syncing
                        , Ev.onClick cfg.onDeleteConfirm
                        ]
                        [ Html.text "Confirm delete" ]
                    , Html.button
                        [ Attr.class "btn btn-sm"
                        , Attr.disabled cfg.syncing
                        , Ev.onClick cfg.onDeleteCancel
                        ]
                        [ Html.text "Cancel" ]
                    ]

              else
                Html.button
                    [ Attr.class "btn btn-danger-outline btn-sm"
                    , Attr.disabled cfg.syncing
                    , Ev.onClick (cfg.onDelete p.id)
                    ]
                    [ Html.text "Delete" ]
            ]
        ]


-- ─── Form view (add / edit) ────────────────────────────────────────

formView cfg =
    Html.div [ Attr.class "me-page" ]
        [ Html.div [ Attr.class "me-body" ]
            [ case cfg.error of
                Just err ->
                    Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                        [ Html.text ("Failed to save ASR endpoint: " ++ err) ]

                Nothing ->
                    Html.text ""
            , Html.div [ Attr.class "me-fields" ]
                [ Html.div [ Attr.class "me-field" ]
                    [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Name" ]
                    , Html.input
                        [ Attr.class "input"
                        , Attr.id "asr-config-name"
                        , Attr.type_ "text"
                        , Attr.value cfg.name
                        , Attr.placeholder "Local whisper, OpenAI, …"
                        , Ev.onInput cfg.onName
                        ]
                        []
                    , Html.div [ Attr.class "me-hint" ]
                        [ Html.text "Shown in the ASR list so you can tell endpoints apart. Defaults to the URL when empty." ]
                    ]
                , Html.div [ Attr.class "me-field" ]
                    [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Protocol" ]
                    , Html.select
                        [ Attr.class "input input-select"
                        , Attr.id "asr-config-protocol"
                        , Ev.onInput cfg.onProtocol
                        ]
                        [ Html.option [ Attr.value "transcriptions", Attr.selected (cfg.protocol == "transcriptions") ]
                            [ Html.text (protocolDisplayName "transcriptions") ]
                        , Html.option [ Attr.value "chat_completions", Attr.selected (cfg.protocol == "chat_completions") ]
                            [ Html.text (protocolDisplayName "chat_completions") ]
                        , Html.option [ Attr.value "step_audio", Attr.selected (cfg.protocol == "step_audio") ]
                            [ Html.text (protocolDisplayName "step_audio") ]
                        ]
                    , Html.div [ Attr.class "me-hint" ]
                        [ Html.text "\"transcriptions\": OpenAI-compatible multipart upload (most local whisper servers). \"chat_completions\": OpenAI standard chat completions — JSON body with input_audio base64 and api-key header. \"step_audio\": StepFun realtime ASR — JSON with raw PCM audio, Accept: text/event-stream, Authorization: Bearer." ]
                    ]
                , Html.div [ Attr.class "me-field" ]
                    [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Endpoint URL" ]
                    , Html.input
                        [ Attr.class "input"
                        , Attr.id "asr-config-url"
                        , Attr.type_ "text"
                        , Attr.value cfg.url
                        , Attr.placeholder "http://127.0.0.1:8080/v1/audio/transcriptions  or  https://api.openai.com/v1/chat/completions"
                        , Ev.onInput cfg.onUrl
                        ]
                        []
                    , Html.div [ Attr.class "me-hint" ]
                        [ Html.text "Full endpoint address (including the method path) — used exactly as entered, nothing is appended." ]
                    ]
                , Html.div [ Attr.class "me-field" ]
                    [ Html.label [ Attr.class "me-field-label" ] [ Html.text "API key" ]
                    , Html.input
                        [ Attr.class "input"
                        , Attr.id "asr-config-api-key"
                        , Attr.type_ "password"
                        , Attr.value cfg.apiKey
                        , Attr.placeholder "sk-… (empty = no auth header; local endpoints usually don't need one)"
                        , Ev.onInput cfg.onApiKey
                        ]
                        []
                    , Html.div [ Attr.class "me-hint" ]
                        [ Html.text "transcriptions → Authorization: Bearer; chat_completions → api-key header; step_audio → Authorization: Bearer. Leave empty for local servers that don't require it." ]
                    ]
                , Html.div [ Attr.class "me-field" ]
                    [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Model" ]
                    , Html.input
                        [ Attr.class "input"
                        , Attr.id "asr-config-model"
                        , Attr.type_ "text"
                        , Attr.value cfg.model
                        , Attr.placeholder "whisper-1"
                        , Ev.onInput cfg.onModel
                        ]
                        []
                    , Html.div [ Attr.class "me-hint" ]
                        [ Html.text "Passed through to the endpoint as the model id. The endpoint decides how to use it (many local servers ignore it)." ]
                    ]
                , Html.div [ Attr.class "me-field" ]
                    [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Language" ]
                    , Html.input
                        [ Attr.class "input"
                        , Attr.id "asr-config-language"
                        , Attr.type_ "text"
                        , Attr.value cfg.language
                        , Attr.placeholder "auto (zh, en, ja, …)"
                        , Ev.onInput cfg.onLanguage
                        ]
                        []
                    , Html.div [ Attr.class "me-hint" ]
                        [ Html.text "Whisper language code. \"auto\" (default) omits the field / autodetects." ]
                    ]
                ]
            , Html.div [ Attr.class "me-actions" ]
                [ Html.button
                    [ Attr.class "btn btn-primary"
                    , Attr.disabled cfg.syncing
                    , Ev.onClick cfg.onSave
                    ]
                    [ Html.text (if cfg.syncing then "Saving…" else "Save") ]
                ]
            ]
        ]
