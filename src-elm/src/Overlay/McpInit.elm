module Overlay.McpInit exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.Types as T


view :
    { mcpStatus : Maybe String
    , mcpServers : List String
    , pendingMcpAuth : Maybe T.PendingConfirm
    , onClose : msg
    , onCancelAll : msg
    , onAuthConfirm : msg
    , onAuthDeny : String -> msg
    , onFillUrl : String -> msg
    }
    -> Html msg
view config =
    let
        statusText =
            case config.mcpStatus of
                Just "connecting" ->
                    if List.isEmpty config.mcpServers then
                        "Initializing MCP servers…"
                    else
                        "Connecting to MCP servers:"

                Just "auth_running" ->
                    "Waiting for OAuth authorization…"

                Just "failed" ->
                    "MCP initialization failed."

                _ ->
                    "Initializing MCP servers…"

        authServerName =
            case config.pendingMcpAuth of
                Just a ->
                    Maybe.withDefault "" a.toolName

                Nothing ->
                    ""

        authUrl =
            case config.pendingMcpAuth of
                Just a ->
                    Maybe.withDefault "" a.toolInput

                Nothing ->
                    ""
    in
    Html.div [ Attr.class "mcp-init-page" ]
        [ Html.div [ Attr.class "confirm-page-title" ]
            [ Html.text "Initializing MCP Servers" ]
        , Html.div [ Attr.class "mcp-init-status" ]
            [ Html.text statusText ]
        , if not (List.isEmpty config.mcpServers) then
            Html.div [ Attr.class "mcp-init-list" ]
                (List.map
                    (\s ->
                        let
                            isAuthServer =
                                s == authServerName && authUrl /= ""
                        in
                        Html.div [ Attr.class "mcp-init-server" ]
                            [ Html.span [ Attr.class "mcp-init-dot" ]
                                [ Html.text (if isAuthServer then "🔑" else "⟳") ]
                            , Html.span [ Attr.class "mcp-init-name" ] [ Html.text s ]
                            , if isAuthServer then
                                Html.span [ Attr.class "mcp-init-actions" ]
                                    [ Html.button
                                        [ Attr.class "mcp-init-btn mcp-init-btn-url"
                                        , Ev.onClick (config.onFillUrl authUrl)
                                        , Attr.title "Copy authorization URL"
                                        ]
                                        [ Html.text "📋 URL" ]
                                    , Html.button
                                        [ Attr.class "mcp-init-btn mcp-init-btn-auth"
                                        , Ev.onClick config.onAuthConfirm
                                        , Attr.title "Open browser to authorize"
                                        ]
                                        [ Html.text "✓ Authorize" ]
                                    , Html.button
                                        [ Attr.class "mcp-init-btn mcp-init-btn-deny"
                                        , Ev.onClick (config.onAuthDeny s)
                                        , Attr.title "Skip this server"
                                        ]
                                        [ Html.text "✕ Deny" ]
                                    ]

                              else
                                Html.text ""
                            ]
                    )
                    config.mcpServers
                )

          else
            Html.text ""
        , Html.div [ Attr.class "mcp-init-footer" ]
            [ Html.button
                [ Attr.class "mcp-init-btn mcp-init-btn-close"
                , Ev.onClick config.onClose
                , Attr.title "Close overlay"
                ]
                [ Html.text "Cancel Initialization" ]
            ]
        ]
