module Overlay.McpEditor exposing (view)

{-| The MCP server form.

The keys it edits are `App.McpConfig.modeledKeys` (their values are decoded and
written there); `App.McpConfig.draftProblems` decides whether Save is allowed,
and the same list is re-checked by `SelectorKit.editSave` so the disabled
button cannot be bypassed.

The layout is hand-written rather than generated from a field list because the
form is conditional: `url`/auth belong to an HTTP server, `command`/`args`/`env`
to a stdio one. That is the one place this editor differs from
`Overlay.ModelEditor`, whose fields are unconditional.
-}

import App.McpConfig as MCP
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.Types as T


view :
    { sessionId : String
    , draft : T.McpDraft
    , isNew : Bool
    , onSave : msg
    , onField : String -> String -> msg
    , error : Maybe String
    }
    -> Html msg
view config =
    let
        problems =
            MCP.draftProblems config.draft

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
        , Html.div [ Attr.class "me-fields" ]
            [ selectField problemOf "type" "Type" [ "http", "stdio" ] config.draft.type_ config
            , textField problemOf "server" "Server Name" config.draft.server config
            , if config.draft.type_ == "http" then
                textField problemOf "url" "URL" config.draft.url config

              else
                Html.text ""
            , if config.draft.type_ == "stdio" then
                Html.div []
                    [ textField problemOf "command" "Command" config.draft.command config
                    , textAreaField problemOf "args" "Args (JSON array)" config.draft.args config
                    , textAreaField problemOf "env" "Env (JSON object)" config.draft.env config
                    ]

              else
                Html.text ""
            , if config.draft.type_ == "http" then
                Html.div []
                    [ selectField problemOf "auth-type" "Auth Type" [ "", "none", "static", "authorization_code" ] config.draft.authType config
                    , if config.draft.authType == "authorization_code" then
                        Html.div []
                            [ textField problemOf "auth-client-id" "Auth Client ID" config.draft.authClientId config
                            , textField problemOf "auth-client-secret" "Auth Client Secret" config.draft.authClientSecret config
                            ]

                      else if config.draft.authType == "static" then
                        textField problemOf "auth-token" "Auth Token" config.draft.authToken config

                      else
                        Html.text ""
                    -- Also shown when a value is already present under another
                    -- auth type: a hidden field that blocks Save (its JSON is
                    -- validated) would be unfixable.
                    , if config.draft.authType == "authorization_code" || not (String.isEmpty (String.trim config.draft.authScopes)) then
                        textAreaField problemOf "auth-scopes" "Auth Scopes (JSON array)" config.draft.authScopes config

                      else
                        Html.text ""
                    ]

              else
                Html.text ""
            , selectField problemOf "proto-version" "Proto Version" (protoVersionOptions config.draft.protoVersion) config.draft.protoVersion config
            ]
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


textField :
    (String -> Maybe String)
    -> String
    -> String
    -> String
    -> { a | sessionId : String, onField : String -> String -> msg }
    -> Html msg
textField problemOf key label value config =
    fieldWrapper problemOf key label config
        (Html.input
            [ Attr.class "input"
            , Attr.id (inputId key config.sessionId)
            , Attr.type_ "text"
            , Attr.value value
            , Ev.onInput (config.onField key)
            ]
            []
        )


textAreaField :
    (String -> Maybe String)
    -> String
    -> String
    -> String
    -> { a | sessionId : String, onField : String -> String -> msg }
    -> Html msg
textAreaField problemOf key label value config =
    fieldWrapper problemOf key label config
        (Html.textarea
            [ Attr.class "input me-field-textarea"
            , Attr.id (inputId key config.sessionId)
            , Attr.rows 2
            , Attr.spellcheck False
            , Attr.value value
            , Ev.onInput (config.onField key)
            ]
            []
        )


selectField :
    (String -> Maybe String)
    -> String
    -> String
    -> List String
    -> String
    -> { a | sessionId : String, onField : String -> String -> msg }
    -> Html msg
selectField problemOf key label options value config =
    fieldWrapper problemOf key label config
        (Html.select
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
                        [ Html.text (if opt == "" then "(none)" else opt) ]
                )
                options
            )
        )


fieldWrapper :
    (String -> Maybe String)
    -> String
    -> String
    -> { a | sessionId : String }
    -> Html msg
    -> Html msg
fieldWrapper problemOf key label config control =
    Html.div [ Attr.class "me-field" ]
        [ Html.label [ Attr.class "me-field-label", Attr.for (inputId key config.sessionId) ] [ Html.text label ]
        , control
        , case problemOf key of
            Just message ->
                Html.div [ Attr.class "me-field-error" ] [ Html.text message ]

            Nothing ->
                Html.text ""
        ]


inputId : String -> String -> String
inputId key sessionId =
    "mcp-editor-" ++ key ++ "-" ++ sessionId


protoVersionOptions : String -> List String
protoVersionOptions current =
    let
        known =
            T.mcpProtoVersions
    in
    if current == "" || List.member current known then
        known
    else
        -- Keep unknown (e.g. future) versions selectable without data loss
        known ++ [ current ]
