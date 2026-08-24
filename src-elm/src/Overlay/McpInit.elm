module Overlay.McpInit exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.Types as T


-- MCP init overlay. Servers that need OAuth get their own row-level
-- [📋 URL] [✓ Authorize] [✕ Deny] buttons so multiple pending auth
-- requests never overwrite each other. A server whose flow was started
-- by the UI shows "Authorizing…" instead of buttons (prevents starting
-- a second callback server for the same server).

view :
    { mcpStatus : Maybe String
    , mcpServers : List String
    , pendingAuths : List T.McpAuth
    , authRunning : Maybe String
    , onClose : msg
    , onCancelAll : msg
    , onAuthConfirm : String -> msg
    , onAuthDeny : String -> msg
    , onFillUrl : String -> String -> msg
    }
    -> Html msg
view config =
    let
        statusText =
            case config.authRunning of
                Just s ->
                    "Waiting for OAuth authorization for " ++ s ++ "…"

                Nothing ->
                    case config.mcpStatus of
                        Just "connecting" ->
                            if List.isEmpty config.mcpServers then
                                "Initializing MCP servers…"

                            else
                                "Connecting to MCP servers:"

                        Just "failed" ->
                            "MCP initialization failed."

                        _ ->
                            "Initializing MCP servers…"

        authFor : String -> Maybe T.McpAuth
        authFor s =
            List.filter (\a -> a.server == s) config.pendingAuths
                |> List.head
    in
    Html.div [ Attr.class "mcp-init-page" ]
        [ Html.div [ Attr.class "mcp-init-status" ]
            [ Html.text statusText ]
        , if not (List.isEmpty config.mcpServers) then
            Html.div [ Attr.class "mcp-init-list" ]
                (List.map
                    (\s ->
                        let
                            auth =
                                authFor s

                            isRunning =
                                config.authRunning == Just s
                        in
                        Html.div [ Attr.class "mcp-init-server" ]
                            [ Html.span [ Attr.class "mcp-init-dot" ]
                                [ Html.text
                                    (if isRunning then
                                        "⏳"

                                     else if auth /= Nothing then
                                        "🔑"

                                     else
                                        "⟳"
                                    )
                                ]
                            , Html.span [ Attr.class "mcp-init-name" ] [ Html.text s ]
                            , if isRunning then
                                Html.span [ Attr.class "mcp-init-actions" ]
                                    [ Html.span [ Attr.class "mcp-init-running" ]
                                        [ Html.text "Authorizing…" ]
                                    ]

                              else
                                case auth of
                                    Just a ->
                                        Html.span [ Attr.class "mcp-init-actions" ]
                                            [ Html.button
                                                [ Attr.class "mcp-init-btn mcp-init-btn-url"
                                                , Ev.onClick (config.onFillUrl a.server a.url)
                                                , Attr.title "Copy authorization URL"
                                                ]
                                                [ Html.text "📋 URL" ]
                                            , Html.button
                                                [ Attr.class "mcp-init-btn mcp-init-btn-auth"
                                                , Ev.onClick (config.onAuthConfirm a.server)
                                                , Attr.title "Open browser to authorize"
                                                ]
                                                [ Html.text "✓ Authorize" ]
                                            , Html.button
                                                [ Attr.class "mcp-init-btn mcp-init-btn-deny"
                                                , Ev.onClick (config.onAuthDeny a.server)
                                                , Attr.title "Skip this server"
                                                ]
                                                [ Html.text "✕ Deny" ]
                                            ]

                                    Nothing ->
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
