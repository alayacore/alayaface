module Session.Handlers exposing
    ( handleDeltaEvent
    , handleFrameEvent
    , modelInfoDecoder
    )

import Dict exposing (Dict)
import Set exposing (Set)
import Json.Decode as D
import Session.Types exposing (..)
import Session.Protocol exposing (..)


-- Model Info Decoder

modelInfoDecoder : D.Decoder ModelInfo
modelInfoDecoder =
    D.map8 ModelInfo
        (D.field "id" D.int)
        (D.field "name" D.string)
        (D.field "protocol_type" D.string)
        (D.field "base_url" D.string)
        (D.field "api_key" D.string)
        (D.field "model_name" D.string)
        (D.oneOf [ D.field "context_limit" D.int, D.succeed 0 ])
        (D.oneOf [ D.field "max_tokens" D.int, D.succeed 0 ])


-- Delta Event Handler (At/Ar)

handleDeltaEvent : SessionState -> DeltaEvent -> SessionState
handleDeltaEvent s ev =
    let
        role =
            if ev.tag == "At" then
                Assistant
            else
                Reasoning

        -- Accumulation is keyed by (tag, historyId): the wire protocol
        -- gives every content block a unique history id, but a defensive
        -- split by tag keeps At and Ar from sharing an accumulator slot
        -- even if an adapter reuses an id across roles.
        historyKey =
            ev.tag ++ ":" ++ ev.historyId
    in
    case Dict.get historyKey s.historyContents of
        Just existing ->
            let
                newContent =
                    existing ++ ev.content

                newHistoryContents =
                    Dict.insert historyKey newContent s.historyContents

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
                    Dict.insert historyKey ev.content s.historyContents

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

    else if ev.tag == "CO" then
        case ev.json of
            Just json -> handleCommandResultFrame s json
            Nothing -> s

    else if ev.tag == "Af" then
        case ev.json of
            Just json -> handleToolDeltaFrame s json
            Nothing -> s

    else if ev.tag == "Uf" then
        case ev.json of
            Just json -> handleToolPreviewFrame s json
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
                            { s
                                | messages = s.messages ++ [ userEchoMessage hid textContent mediaType content ]
                                , processedEchoIds = newEchoIds
                                , sendPending = False
                            }

                    Nothing ->
                        { s
                            | messages = s.messages ++ [ userEchoMessage hid textContent mediaType content ]
                            , processedEchoIds = newEchoIds
                            , sendPending = False
                        }

        Nothing ->
            s


-- Build a new user message from a user-echo frame.
userEchoMessage : String -> String -> Maybe MediaType -> Maybe String -> Message
userEchoMessage hid textContent mediaType content =
    { id = "user-" ++ hid
    , role = User
    , content = textContent
    , toolId = Nothing
    , toolName = Nothing
    , isError = False
    , historyId = Just hid
    , media =
        case ( mediaType, content ) of
            ( Just mt, Just c ) ->
                Just [ { mediaType = mt, uri = c, name = Nothing } ]

            _ ->
                Nothing
    }


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
                        List.reverse ({ last | content = last.content ++ sep ++ textContent, historyId = historyId } :: rest)

                    else
                        case ( mediaType, content ) of
                            ( Just mt, Just c ) ->
                                let
                                    existingMedia =
                                        Maybe.withDefault [] last.media

                                    newMedia =
                                        existingMedia ++ [ { mediaType = mt, uri = c, name = Nothing } ]
                                in
                                List.reverse ({ last | media = Just newMedia, historyId = historyId } :: rest)

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
                                Dict.insert (tag ++ ":" ++ hid) c s.historyContents

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
        "task" -> handleSystemTask s env.data
        "error" -> handleSystemError s env.data
        "notify" -> handleSystemNotify s env.data
        "model_list" -> handleSystemModelList s env.data
        "model" -> handleSystemModel s env.data
        "tool_confirm" -> handleSystemToolConfirm s env.data
        "mcp" -> handleSystemMcp s env.data
        _ -> s


handleSystemTask : SessionState -> D.Value -> SessionState
handleSystemTask s data =
    let
        inProgress =
            D.decodeValue (D.field "in_progress" D.bool) data
                |> Result.toMaybe
                |> Maybe.withDefault False

        step =
            D.decodeValue (D.field "current_step" D.int) data
                |> Result.toMaybe

        maxSteps =
            D.decodeValue (D.field "max_steps" D.int) data
                |> Result.toMaybe

        taskError =
            D.decodeValue (D.field "task_error" D.bool) data
                |> Result.toMaybe
                |> Maybe.withDefault False

        tokens =
            D.decodeValue (D.field "context_tokens" D.int) data
                |> Result.toMaybe
                |> Maybe.map (\v -> v)

        context =
            D.decodeValue (D.field "context" D.int) data
                |> Result.toMaybe

        contextTokens =
            case tokens of
                Just t ->
                    t

                Nothing ->
                    Maybe.withDefault s.contextTokens context

        done =
            not inProgress

        statusMsg =
            if taskError then
                "Task failed"
            else if done then
                "Task complete"
            else
                case ( step, maxSteps ) of
                    ( Just st, Just ms ) ->
                        "Step " ++ String.fromInt st ++ "/" ++ String.fromInt ms ++ "…"

                    _ ->
                        "Task in progress…"
    in
    { s
        | taskRunning = not done && not taskError
        , taskCurrentStep = Maybe.withDefault s.taskCurrentStep step
        , taskMaxSteps = Maybe.withDefault s.taskMaxSteps maxSteps
        , contextTokens = contextTokens
        , statusMsg = statusMsg
        , sendPending = if done || taskError then False else s.sendPending
    }


handleSystemError : SessionState -> D.Value -> SessionState
handleSystemError s data =
    let
        text =
            D.decodeValue (D.field "text" D.string) data
                |> Result.withDefault "Unknown error"

        msg =
            { id = "err-" ++ String.fromInt (List.length s.messages)
            , role = Error
            , content = text
            , toolId = Nothing
            , toolName = Nothing
            , isError = True
            , historyId = Nothing
            , media = Nothing
            }
    in
    { s | messages = s.messages ++ [ msg ] }


handleSystemNotify : SessionState -> D.Value -> SessionState
handleSystemNotify s data =
    let
        text =
            D.decodeValue (D.field "text" D.string) data
                |> Result.withDefault ""

        msg =
            { id = "notify-" ++ String.fromInt (List.length s.messages)
            , role = Notify
            , content = text
            , toolId = Nothing
            , toolName = Nothing
            , isError = False
            , historyId = Nothing
            , media = Nothing
            }
    in
    { s | messages = s.messages ++ [ msg ] }


handleSystemModelList : SessionState -> D.Value -> SessionState
handleSystemModelList s data =
    let
        modelsResult =
            D.decodeValue (D.field "models" (D.list modelInfoDecoder)) data
    in
    case modelsResult of
        Ok models ->
            { s | models = models }

        Err _ ->
            s


handleSystemModel : SessionState -> D.Value -> SessionState
handleSystemModel s data =
    let
        idResult =
            D.decodeValue (D.field "active_id" D.int) data

        nameResult =
            D.decodeValue (D.field "active_name" D.string) data

        contextResult =
            D.decodeValue (D.field "context_limit" D.int) data
    in
    case ( idResult, nameResult ) of
        ( Ok mid, Ok mname ) ->
            { s
                | activeModelId = Just mid
                , activeModelName = mname
                , contextLimit = Result.withDefault s.contextLimit contextResult
            }

        _ ->
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
            D.decodeValue (D.field "status" D.string) data |> Result.toMaybe

        server =
            D.decodeValue (D.field "server" D.string) data |> Result.toMaybe |> Maybe.withDefault ""

        url =
            D.decodeValue (D.field "url" D.string) data |> Result.toMaybe
    in
    case status of
        Just "connecting" ->
            -- Add server to list if not already present
            let
                newServers =
                    if List.member server s.mcpServers then
                        s.mcpServers
                    else
                        s.mcpServers ++ [ server ]
            in
            { s | mcpStatus = Just "connecting", mcpServers = newServers }

        Just "connected" ->
            -- Remove server from list and any pending auth for it
            { s
                | mcpStatus = Just "connecting"
                , mcpServers = List.filter (\n -> n /= server) s.mcpServers
                , pendingMcpAuths = List.filter (\a -> a.server /= server) s.pendingMcpAuths
                , mcpAuthRunning =
                    if s.mcpAuthRunning == Just server then
                        Nothing

                    else
                        s.mcpAuthRunning
            }

        Just "failed" ->
            -- Remove from list; if list empty, mcp init is done
            let
                remaining =
                    List.filter (\n -> n /= server) s.mcpServers
            in
            { s
                | mcpStatus = Just (if List.isEmpty remaining then "failed" else "connecting")
                , mcpServers = remaining
                , pendingMcpAuths = List.filter (\a -> a.server /= server) s.pendingMcpAuths
                , mcpAuthRunning =
                    if s.mcpAuthRunning == Just server then
                        Nothing

                    else
                        s.mcpAuthRunning
            }

        Just "auth_required" ->
            -- One entry per server: replace any existing entry for this
            -- server (refreshes the URL) so repeated requests don't stack.
            let
                newAuth =
                    { server = server
                    , url = Maybe.withDefault "" url
                    }

                cleaned =
                    List.filter (\a -> a.server /= server) s.pendingMcpAuths
            in
            { s
                | pendingMcpAuths = cleaned ++ [ newAuth ]
                , mcpAuthRunning =
                    if s.mcpAuthRunning == Just server then
                        Nothing

                    else
                        s.mcpAuthRunning
                , mcpStatus = Just "auth_required"
            }

        Just "auth_running" ->
            { s | mcpStatus = Just "auth_running" }

        Just "done" ->
            { s
                | mcpStatus = Nothing
                , mcpServers = []
                , pendingMcpAuths = []
                , mcpAuthRunning = Nothing
            }

        Just st ->
            { s | mcpStatus = Just st }

        Nothing ->
            s


-- Command Result Frame (CO)

-- CO carries only the call ID; the reader injects the command `name`
-- (resolved from the CI we sent) into the JSON so we can render results
-- without tracking call IDs on the frontend. Success results with useful
-- info (save/fork/mcp) become Notify-style messages; errors become
-- Error-style messages. Silent commands (cancel, reason, model_set, ...)
-- render nothing — the state change itself is the confirmation.
handleCommandResultFrame : SessionState -> D.Value -> SessionState
handleCommandResultFrame s json =
    let
        isError =
            D.decodeValue (D.field "is_error" D.bool) json
                |> Result.toMaybe
                |> Maybe.withDefault False

        output =
            D.decodeValue (D.field "output" D.value) json |> Result.toMaybe

        name =
            D.decodeValue (D.field "name" D.string) json
                |> Result.toMaybe
                |> Maybe.withDefault ""
    in
    if isError then
        let
            code =
                output
                    |> Maybe.andThen (\o -> D.decodeValue (D.field "code" D.string) o |> Result.toMaybe)
                    |> Maybe.withDefault ""

            message =
                output
                    |> Maybe.andThen (\o -> D.decodeValue (D.field "message" D.string) o |> Result.toMaybe)
                    |> Maybe.withDefault "Command failed"

            text =
                if code == "" then
                    message
                else
                    code ++ ": " ++ message
        in
        appendSystemMessage s Error text

    else
        case renderCommandResult name output of
            Just text ->
                appendSystemMessage s Notify text

            Nothing ->
                s


renderCommandResult : String -> Maybe D.Value -> Maybe String
renderCommandResult name output =
    let
        str key =
            output
                |> Maybe.andThen (\o -> D.decodeValue (D.field key D.string) o |> Result.toMaybe)
                |> Maybe.withDefault ""

        int key =
            output
                |> Maybe.andThen (\o -> D.decodeValue (D.field key D.int) o |> Result.toMaybe)
                |> Maybe.withDefault 0
    in
    case name of
        "save" ->
            Just ("Session saved to " ++ str "path")

        "fork" ->
            Just ("Session forked to " ++ str "path" ++ " (up to content ID " ++ String.fromInt (int "history_id") ++ ")")

        "mcp_confirm" ->
            Just ("MCP auth code received for \"" ++ str "server" ++ "\".")

        "mcp_decline" ->
            Just ("MCP authorization for \"" ++ str "server" ++ "\" declined.")

        _ ->
            Nothing


appendSystemMessage : SessionState -> Role -> String -> SessionState
appendSystemMessage s role text =
    let
        newMsg =
            { id = "sys-" ++ String.fromInt (List.length s.messages)
            , role = role
            , content = text
            , toolId = Nothing
            , toolName = Nothing
            , isError = False
            , historyId = Nothing
            , media = Nothing
            }
    in
    { s | messages = s.messages ++ [ newMsg ] }


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
                    , content = ""
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

-- The authoritative tool result. Output is a JSON array of content
-- blocks (text, image, ...); text blocks are joined for display and
-- truncated to keep the transcript readable. On error, output is a
-- uniform {"code","message"} object.
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
            if isError then
                case output of
                    Just o ->
                        let
                            code =
                                D.decodeValue (D.field "code" D.string) o
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""

                            message =
                                D.decodeValue (D.field "message" D.string) o
                                    |> Result.toMaybe
                                    |> Maybe.withDefault ""
                        in
                        if message == "" then
                            "<output received>"

                        else if code == "" then
                            message

                        else
                            code ++ ": " ++ message

                    Nothing ->
                        "<output received>"

            else
                case output of
                    Just o ->
                        let
                            text =
                                toolOutputText o
                        in
                        if String.isEmpty text then
                            "<output received>"

                        else
                            truncateToolOutput text

                    Nothing ->
                        "<output received>"

        tc =
            Dict.get toolId s.toolCalls

        -- The window header already shows the tool name and status icon,
        -- so the body carries only the raw output text — no markdown
        -- fences, no emoji prefix.
        newMsgs =
            List.map
                (\m ->
                    if m.toolId == Just toolId then
                        { m
                            | content = outStr
                            , isError = isError
                            , historyId = historyId
                        }
                    else
                        m
                )
                s.messages

        -- Authoritative UF overwrites any live Uf preview (snapshot) and
        -- ends input streaming (Af), so the header status flips to done.
        -- inputReceived is reset too, otherwise the ⏳ "running" state in
        -- toolStatus would stick after completion for tools that had input.
        newToolCalls =
            case Dict.get toolId s.toolCalls of
                Just existingTc ->
                    Dict.insert toolId
                        { existingTc | output = Nothing, accumulatedDelta = Nothing, inputReceived = False }
                        s.toolCalls

                Nothing ->
                    s.toolCalls
    in
    { s | messages = newMsgs, toolCalls = newToolCalls }


-- Extract readable text from a tool output value (array of content
-- blocks, e.g. [{"type":"text","text":"..."}, ...]).
toolOutputText : D.Value -> String
toolOutputText value =
    case D.decodeValue (D.list outputBlockText) value of
        Ok texts ->
            texts
                |> List.filter (not << String.isEmpty)
                |> String.join "\n"

        Err _ ->
            ""


outputBlockText : D.Decoder String
outputBlockText =
    D.oneOf
        [ D.field "text" D.string
        , D.succeed ""
        ]


-- Keep tool output bounded so long results do not flood the transcript.
truncateToolOutput : String -> String
truncateToolOutput text =
    if String.length text > 8000 then
        String.left 8000 text ++ "\n… (truncated)"

    else
        text


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
                                    { m | content = accumulated }
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


-- Tool Result Preview Frame (Uf)

-- Uf is an ephemeral, display-only tool result preview **snapshot**:
-- each frame replaces the previous one (never concatenated), and the
-- authoritative UF overwrites it. Unknown tool IDs are ignored — AF
-- always precedes Uf in practice (a tool must start before it streams).
handleToolPreviewFrame : SessionState -> D.Value -> SessionState
handleToolPreviewFrame s json =
    let
        toolId =
            D.decodeValue (D.field "id" D.string) json |> Result.toMaybe |> Maybe.withDefault ""

        text =
            D.decodeValue (D.field "text" D.string) json |> Result.toMaybe |> Maybe.withDefault ""
    in
    if String.isEmpty toolId then
        s

    else
        case Dict.get toolId s.toolCalls of
            Just tc ->
                let
                    newTc =
                        { tc | output = Just text }

                    newToolCalls =
                        Dict.insert toolId newTc s.toolCalls

                    newMsgs =
                        List.map
                            (\m ->
                                if m.toolId == Just toolId then
                                    { m | content = text }
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
