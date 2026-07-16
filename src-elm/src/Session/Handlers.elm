module Session.Handlers exposing
    ( handleDeltaEvent
    , handleFrameEvent
    , handleSystemMsg
    )

import Dict exposing (Dict)
import Set exposing (Set)
import Json.Decode as D
import Session.Types exposing (..)
import Session.Protocol exposing (..)


-- Delta Event Handler (At/Ar)

handleDeltaEvent : SessionState -> DeltaEvent -> SessionState
handleDeltaEvent s ev =
    let
        role =
            if ev.tag == "At" then
                Assistant
            else
                Reasoning
    in
    case Dict.get ev.historyId s.historyContents of
        Just existing ->
            let
                newContent =
                    existing ++ ev.content

                newHistoryContents =
                    Dict.insert ev.historyId newContent s.historyContents

                newMsgs =
                    List.map
                        (\m ->
                            if m.historyId == Just ev.historyId && m.role == role then
                                { m | content = newContent }
                            else
                                m
                        )
                        s.messages
            in
            { s
                | historyContents = newHistoryContents
                , messages = newMsgs
                , sendPending = False
            }

        Nothing ->
            let
                newHistoryContents =
                    Dict.insert ev.historyId ev.content s.historyContents

                newMsg =
                    { id = "hist-" ++ ev.historyId
                    , role = role
                    , content = ev.content
                    , toolId = Nothing
                    , toolName = Nothing
                    , isError = False
                    , historyId = Just ev.historyId
                    , media = Nothing
                    }

                newMsgs =
                    s.messages ++ [ newMsg ]
            in
            { s
                | historyContents = newHistoryContents
                , messages = newMsgs
                , sendPending = False
            }


-- Frame Event Handler (dispatcher)

handleFrameEvent : SessionState -> FrameEvent -> SessionState
handleFrameEvent s ev =
    if isUserEchoTag ev.tag then
        handleUserEchoFrame s ev.tag ev.historyId ev.content

    else if ev.tag == "AT" || ev.tag == "AR" then
        handleCompleteFrame s ev.tag ev.historyId ev.content

    else if ev.tag == "SM" then
        case ev.json of
            Just json ->
                case D.decodeValue systemMsgDecoder json of
                    Ok env ->
                        handleSystemMsg s env

                    Err _ ->
                        s

            Nothing ->
                s

    else if ev.tag == "AF" then
        case ev.json of
            Just json -> handleToolCallFrame s json ev.historyId
            Nothing -> s

    else if ev.tag == "UF" then
        case ev.json of
            Just json -> handleToolResultFrame s json ev.historyId
            Nothing -> s

    else if ev.tag == "Af" then
        case ev.json of
            Just json -> handleToolDeltaFrame s json
            Nothing -> s

    else
        s


-- User Echo Frame

handleUserEchoFrame : SessionState -> String -> Maybe String -> Maybe String -> SessionState
handleUserEchoFrame s tag historyId content =
    let
        mediaType =
            case tag of
                "UI" -> Just Image
                "UV" -> Just Video
                "UA" -> Just Audio
                "UD" -> Just Document
                _ -> Nothing

        textContent =
            if tag == "UT" then
                Maybe.withDefault "" content
            else
                ""
    in
    case historyId of
        Just hid ->
            if Set.member hid s.processedEchoIds then
                s

            else
                let
                    newEchoIds =
                        Set.insert hid s.processedEchoIds

                    lastMsg =
                        List.head (List.reverse s.messages)
                in
                case lastMsg of
                    Just msg ->
                            if msg.role == User then
                                appendToLastUserMessage s tag textContent mediaType content historyId newEchoIds

                            else
                                let
                                    newMsg =
                                        { id = "user-" ++ hid
                                            , role = User
                                            , content = textContent
                                            , toolId = Nothing
                                            , toolName = Nothing
                                            , isError = False
                                            , historyId = Just hid
                                            , media =
                                                case ( mediaType, content ) of
                                                    ( Just mt, Just c ) -> Just [ { mediaType = mt, uri = c, name = Nothing } ]
                                                    _ -> Nothing
                                            }

                                    newMsgs =
                                        s.messages ++ [ newMsg ]
                                in
                                { s
                                    | messages = newMsgs
                                    , processedEchoIds = newEchoIds
                                    , sendPending = False
                                }

                    Nothing ->
                        let
                            newMsg =
                                    { id = "user-" ++ hid
                                        , role = User
                                        , content = textContent
                                        , toolId = Nothing
                                        , toolName = Nothing
                                        , isError = False
                                        , historyId = Just hid
                                        , media =
                                            case ( mediaType, content ) of
                                                ( Just mt, Just c ) -> Just [ { mediaType = mt, uri = c, name = Nothing } ]
                                                _ -> Nothing
                                        }

                            newMsgs =
                                s.messages ++ [ newMsg ]
                        in
                        { s
                            | messages = newMsgs
                            , processedEchoIds = newEchoIds
                            , sendPending = False
                        }

        Nothing ->
            s


appendToLastUserMessage : SessionState -> String -> String -> Maybe MediaType -> Maybe String -> Maybe String -> Set.Set String -> SessionState
appendToLastUserMessage s tag textContent mediaType content historyId newEchoIds =
    let
        newMsgs =
            case List.reverse s.messages of
                last :: rest ->
                    if tag == "UT" then
                        let
                            sep =
                                if String.isEmpty last.content then "" else "\n\n"
                        in
                        List.reverse ({ last | content = last.content ++ sep ++ textContent, historyId = Maybe.map (\h -> h) historyId } :: rest)

                    else
                        case ( mediaType, content ) of
                            ( Just mt, Just c ) ->
                                let
                                    existingMedia =
                                        Maybe.withDefault [] last.media

                                    newMedia =
                                        existingMedia ++ [ { mediaType = mt, uri = c, name = Nothing } ]
                                in
                                List.reverse ({ last | media = Just newMedia, historyId = Maybe.map (\h -> h) historyId } :: rest)

                            _ ->
                                s.messages

                _ ->
                    s.messages
    in
    { s
        | messages = newMsgs
        , processedEchoIds = newEchoIds
        , sendPending = False
    }


-- Complete Frame (AT/AR)

handleCompleteFrame : SessionState -> String -> Maybe String -> Maybe String -> SessionState
handleCompleteFrame s tag historyId content =
    let
        role =
            if tag == "AT" then Assistant else Reasoning
    in
    case content of
        Just c ->
            if String.isEmpty c then
                { s | sendPending = False }

            else
                case historyId of
                    Just hid ->
                        let
                            newHistoryContents =
                                Dict.insert hid c s.historyContents

                            idx =
                                List.filter (\m -> m.historyId == Just hid && m.role == role) s.messages
                                    |> List.length

                            newMsgs =
                                if idx > 0 then
                                    List.map
                                        (\m ->
                                            if m.historyId == Just hid && m.role == role then
                                                { m | content = c }
                                            else
                                                m
                                        )
                                        s.messages

                                else
                                    s.messages
                                        ++ [ { id = "hist-" ++ hid
                                             , role = role
                                             , content = c
                                             , toolId = Nothing
                                             , toolName = Nothing
                                             , isError = False
                                             , historyId = Just hid
                                             , media = Nothing
                                             }
                                           ]
                        in
                        { s
                            | historyContents = newHistoryContents
                            , messages = newMsgs
                            , sendPending = False
                        }

                    Nothing ->
                        { s
                            | messages = s.messages
                                ++ [ { id = "msg-" ++ String.fromInt (List.length s.messages)
                                     , role = role
                                     , content = c
                                     , toolId = Nothing
                                     , toolName = Nothing
                                     , isError = False
                                     , historyId = Nothing
                                     , media = Nothing
                                     }
                                   ]
                            , sendPending = False
                        }

        Nothing ->
            { s | sendPending = False }


-- System Message Handler

handleSystemMsg : SessionState -> SystemMsgEnvelope -> SessionState
handleSystemMsg s env =
    case env.msgType of
        "version" -> handleSystemVersion s env.data
        "task" -> handleSystemTask s env.data
        "error" -> handleSystemError s env.data
        "notify" -> handleSystemNotify s env.data
        "model_list" -> handleSystemModelList s env.data
        "model" -> handleSystemModel s env.data
        "theme" -> handleSystemTheme s env.data
        "theme_list" -> handleSystemThemeList s env.data
        "reasoning" -> handleSystemReasoning s env.data
        "video_config" -> handleSystemVideoConfig s env.data
        "tool_confirm" -> handleSystemToolConfirm s env.data
        "mcp" -> handleSystemMcp s env.data
        _ -> s


handleSystemVersion : SessionState -> D.Value -> SessionState
handleSystemVersion s data =
    case D.decodeValue (D.field "message_version" D.int) data of
        Ok v -> { s | messageVersion = Just v }
        Err _ -> s


-- Note: Elm doesn't have optional fields on records like TS.
-- We'll handle this with Maybe values in SessionState extensions.
-- For now, these handlers focus on the required fields.
-- We'll add the optional fields (reasoningLevel, activeTheme, etc.) later.

handleSystemTask : SessionState -> D.Value -> SessionState
handleSystemTask s data =
    let
        tokens =
            D.decodeValue (D.field "context_tokens" D.int) data
                |> Result.toMaybe
                |> Maybe.map (\v -> v)

        -- This is simplified; full implementation would match TS version
    in
    { s | statusMsg = "Task updated" }


handleSystemError : SessionState -> D.Value -> SessionState
handleSystemError s data =
    let
        text =
            D.decodeValue (D.field "text" D.string) data
                |> Result.withDefault "Unknown error"

        notif =
            { id = "err-" ++ String.fromInt (List.length s.notifications)
            , notifType = Error
            , text = text
            , timestamp = 0
            }
    in
    { s | notifications = s.notifications ++ [ notif ] }


handleSystemNotify : SessionState -> D.Value -> SessionState
handleSystemNotify s data =
    let
        text =
            D.decodeValue (D.field "text" D.string) data
                |> Result.withDefault ""
    in
    { s
        | notifications = s.notifications
            ++ [ { id = "notify-" ++ String.fromInt (List.length s.notifications)
                 , notifType = Notify
                 , text = text
                 , timestamp = 0
                 }
               ]
    }


handleSystemModelList : SessionState -> D.Value -> SessionState
handleSystemModelList s data =
    s -- Simplified; full implementation would parse models array


handleSystemModel : SessionState -> D.Value -> SessionState
handleSystemModel s data =
    s


handleSystemTheme : SessionState -> D.Value -> SessionState
handleSystemTheme s data =
    s


handleSystemThemeList : SessionState -> D.Value -> SessionState
handleSystemThemeList s data =
    s


handleSystemReasoning : SessionState -> D.Value -> SessionState
handleSystemReasoning s data =
    s


handleSystemVideoConfig : SessionState -> D.Value -> SessionState
handleSystemVideoConfig s data =
    s


handleSystemToolConfirm : SessionState -> D.Value -> SessionState
handleSystemToolConfirm s data =
    case D.decodeValue (D.field "id" D.string) data of
        Ok id ->
            let
                tc =
                    Dict.get id s.toolCalls

                item =
                    { id = id
                    , toolName = Maybe.map (\t -> t.name) tc
                    , toolInput =
                        tc
                            |> Maybe.andThen (\t -> t.input)
                            |> Maybe.map (\_ -> "pending")
                    }
            in
            { s | pendingConfirm = s.pendingConfirm ++ [ item ] }

        Err _ ->
            s


handleSystemMcp : SessionState -> D.Value -> SessionState
handleSystemMcp s data =
    let
        status =
            D.decodeValue (D.field "status" D.string) data
                |> Result.toMaybe
    in
    case status of
        Just "auth_confirm" ->
            let
                server =
                    D.decodeValue (D.field "server" D.string) data |> Result.toMaybe |> Maybe.withDefault ""

                url =
                    D.decodeValue (D.field "url" D.string) data |> Result.toMaybe
            in
            { s
                | pendingMcpAuth = Just { id = server, toolName = Just server, toolInput = url }
                , mcpStatus = Just "auth_confirm"
            }

        Just st ->
            { s | mcpStatus = Just st }

        Nothing ->
            s


-- Tool Call Frame (AF)

handleToolCallFrame : SessionState -> D.Value -> Maybe String -> SessionState
handleToolCallFrame s json historyId =
    let
        toolId =
            D.decodeValue (D.field "id" D.string) json |> Result.toMaybe |> Maybe.withDefault ""

        toolName =
            D.decodeValue (D.field "name" D.string) json |> Result.toMaybe

        toolInput =
            D.decodeValue (D.field "input" D.value) json |> Result.toMaybe
    in
    case toolName of
        Just name ->
            let
                newToolCalls =
                    Dict.insert toolId
                        { id = toolId
                        , name = name
                        , input = Maybe.map (\i -> Dict.singleton "raw" i) toolInput
                        , output = Nothing
                        , isError = False
                        , started = True
                        , inputReceived = toolInput /= Nothing
                        , accumulatedDelta = Nothing
                        }
                        s.toolCalls

                newMsg =
                    { id = "tool-" ++ toolId
                    , role = Tool
                    , content = "🔧 **" ++ name ++ "**"
                    , toolId = Just toolId
                    , toolName = Just name
                    , isError = False
                    , historyId = historyId
                    , media = Nothing
                    }
            in
            { s
                | toolCalls = newToolCalls
                , messages = s.messages ++ [ newMsg ]
            }

        Nothing ->
            s


-- Tool Result Frame (UF)

handleToolResultFrame : SessionState -> D.Value -> Maybe String -> SessionState
handleToolResultFrame s json historyId =
    let
        toolId =
            D.decodeValue (D.field "id" D.string) json |> Result.toMaybe |> Maybe.withDefault ""

        isError =
            D.decodeValue (D.field "is_error" D.bool) json |> Result.toMaybe |> Maybe.withDefault False

        output =
            D.decodeValue (D.field "output" D.value) json |> Result.toMaybe
    in
    let
        outStr =
            case output of
                Just _ -> "<output received>"
                Nothing -> ""

        tc =
            Dict.get toolId s.toolCalls

        toolName =
            Maybe.map .name tc |> Maybe.withDefault "Tool"

        prefix =
            if isError then
                "❌ **" ++ toolName ++ "** (error)"
            else
                "✅ **" ++ toolName ++ "**"

        newMsgs =
            List.map
                (\m ->
                    if m.toolId == Just toolId then
                        { m
                            | content = prefix ++ "\n```\n" ++ outStr ++ "\n```"
                            , isError = isError
                            , historyId = Maybe.map (\h -> h) historyId
                        }
                    else
                        m
                )
                s.messages
    in
    { s | messages = newMsgs }


-- Tool Delta Frame (Af)

handleToolDeltaFrame : SessionState -> D.Value -> SessionState
handleToolDeltaFrame s json =
    let
        toolId =
            D.decodeValue (D.field "id" D.string) json |> Result.toMaybe |> Maybe.withDefault ""

        delta =
            D.decodeValue (D.field "delta" D.string) json |> Result.toMaybe |> Maybe.withDefault ""
    in
    if String.isEmpty toolId || String.isEmpty delta then
        s

    else
        case Dict.get toolId s.toolCalls of
            Just tc ->
                let
                    accumulated =
                        Maybe.withDefault "" tc.accumulatedDelta ++ delta

                    newTc =
                        { tc | accumulatedDelta = Just accumulated }

                    newToolCalls =
                        Dict.insert toolId newTc s.toolCalls

                    newMsgs =
                        List.map
                            (\m ->
                                if m.toolId == Just toolId then
                                    { m | content = "🔧 **" ++ tc.name ++ "**\n```json\n" ++ accumulated ++ "\n```" }
                                else
                                    m
                            )
                            s.messages
                in
                { s
                    | toolCalls = newToolCalls
                    , messages = newMsgs
                }

            Nothing ->
                s
