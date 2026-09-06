module Overlay.ModelEditor exposing (view)

{-| The model entry form.

Nothing here names a model.conf field: the controls come from
`Session.ModelConfig.fields`, which is also what decodes and encodes them.
A field can therefore not be displayed while being dropped on save, or be
saved while being invisible — the pairing that let `reasoning_field`,
`serial_tool_calls` and `reasoning_0/1/2` vanish from a user's model.conf.
`ModelConfigTest` pins the two ends together.

Drafts whose values the codec cannot express (unparsable `reasoning_N`
JSON, a non-numeric token limit) show a reason against the field and
disable Save; `App.SelectorKit.editSave` refuses on the same list.
-}

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.ModelConfig as MC
import Session.Types as T


view :
    { sessionId : String
    , draft : T.ModelDraft
    , onSave : msg
    , onField : String -> String -> msg
    , error : Maybe String
    }
    -> Html msg
view config =
    let
        problems =
            MC.draftProblems config.draft

        problemOf key =
            problems
                |> List.filter (\( field, _ ) -> field == key)
                |> List.head
                |> Maybe.map Tuple.second

        savable =
            List.isEmpty problems
    in
    Html.div [ Attr.class "me-page" ]
        [ case config.error of
            Just message ->
                Html.div [ Attr.class "sel-page-status sel-page-status-error" ] [ Html.text message ]

            Nothing ->
                Html.text ""
        , Html.div [ Attr.class "me-fields" ] (List.map (viewField problemOf config) MC.fields)
        , Html.div [ Attr.class "me-actions" ]
            [ Html.button
                [ Attr.class "btn btn-primary"
                , Ev.onClick config.onSave
                , Attr.disabled (not savable)
                , Attr.title
                    (if savable then
                        ""

                     else
                        "Fix the highlighted field first"
                    )
                ]
                [ Html.text "Save" ]
            ]
        ]


viewField :
    (String -> Maybe String)
    -> { c | sessionId : String, draft : T.ModelDraft, onField : String -> String -> msg }
    -> MC.Field
    -> Html msg
viewField problemOf config field =
    let
        id =
            inputId field.key config.sessionId

        value =
            field.get config.draft

        onInput =
            Ev.onInput (config.onField field.key)

        control =
            case field.kind of
                MC.Choice options ->
                    Html.select
                        [ Attr.class "input input-select"
                        , Attr.id id
                        , onInput
                        ]
                        (List.map (viewOption value) options)

                MC.Json ->
                    Html.textarea
                        [ Attr.class "input me-field-textarea"
                        , Attr.id id
                        , Attr.rows 2
                        , Attr.spellcheck False
                        , Attr.placeholder field.placeholder
                        , Attr.value value
                        , onInput
                        ]
                        []

                _ ->
                    Html.input
                        [ Attr.class "input"
                        , Attr.id id
                        , Attr.type_ "text"
                        , Attr.value value
                        , Attr.placeholder field.placeholder
                        , onInput
                        ]
                        []
    in
    Html.div [ Attr.class "me-field" ]
        [ Html.label [ Attr.class "me-field-label", Attr.for id ] [ Html.text field.label ]
        , control
        , if String.isEmpty field.hint then
            Html.text ""

          else
            Html.div [ Attr.class "me-hint" ] [ Html.text field.hint ]
        , case problemOf field.key of
            Just message ->
                Html.div [ Attr.class "me-field-error" ] [ Html.text message ]

            Nothing ->
                Html.text ""
        ]


viewOption : String -> ( String, String ) -> Html msg
viewOption current ( value, label ) =
    Html.option
        [ Attr.value value
        , Attr.selected (value == current)
        ]
        [ Html.text label ]


inputId : String -> String -> String
inputId key sessionId =
    "model-editor-" ++ key ++ "-" ++ sessionId
