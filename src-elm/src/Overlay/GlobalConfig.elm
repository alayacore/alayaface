module Overlay.GlobalConfig exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev


{-| Global config overlay (~/.alayaface/global.conf): cross-preset
settings. Currently a single field — the Plan Mode recursion limit
(default 8). Plan node sessions whose plan's depth exceeds it get no
plan system prompt, so the model stops delegating sub-plans.
-}
view :
    { input : String
    , loading : Bool
    , syncing : Bool
    , error : Maybe String
    , onInput : String -> msg
    , onSave : msg
    , onCancel : msg
    }
    -> Html msg
view config =
    Html.div [ Attr.class "me-page" ]
        [ Html.div [ Attr.class "me-page-header" ]
            [ Html.button [ Attr.class "me-back-btn", Ev.onClick config.onCancel ] [ Html.text "← Back" ]
            , Html.div [ Attr.class "me-page-title" ] [ Html.text "Global config" ]
            ]
        , if config.loading then
            Html.div [ Attr.class "sel-page-status" ] [ Html.text "Loading…" ]

          else
            Html.div [ Attr.class "me-body" ]
                [ case config.error of
                    Just err ->
                        Html.div [ Attr.class "sel-page-status sel-page-status-error" ]
                            [ Html.text ("Failed to load global config: " ++ err) ]

                    Nothing ->
                        Html.text ""
                , Html.div [ Attr.class "me-fields" ]
                    [ Html.div [ Attr.class "me-field" ]
                        [ Html.label [ Attr.class "me-field-label" ] [ Html.text "Plan recursion limit" ]
                        , Html.input
                            [ Attr.class "me-field-input"
                            , Attr.id "global-config-recursion-limit"
                            , Attr.type_ "number"
                            , Attr.min "1"
                            , Attr.value config.input
                            , Attr.placeholder "8"
                            , Ev.onInput config.onInput
                            ]
                            []
                        , Html.div [ Attr.class "me-hint" ]
                            [ Html.text "Maximum Plan Mode recursion depth (top-level plan = depth 1, each sub-plan +1). Node sessions of a plan deeper than this get no plan system prompt, so the model stops creating sub-plans. Applies to every preset." ]
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
