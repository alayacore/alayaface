module HandlersTest exposing (tests)

import Expect
import Dict
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)
import Session.Handlers as H
import Session.Protocol exposing (FrameEvent)
import Session.Types exposing (SessionState, emptySession)


contains : String -> String -> Expect.Expectation
contains needle hay =
    Expect.equal True (String.contains needle hay)


notContains : String -> String -> Expect.Expectation
notContains needle hay =
    Expect.equal False (String.contains needle hay)


applyFrame : FrameEvent -> SessionState -> SessionState
applyFrame ev s =
    H.handleFrameEvent s ev


frame : String -> D.Value -> FrameEvent
frame tag json =
    { sessionId = "s1"
    , tag = tag
    , rawValue = ""
    , historyId = Nothing
    , content = Nothing
    , json = Just json
    , userContentType = Nothing
    }


-- A text-content frame as alayacore emits on resume history replay
-- (content + history id).
textFrame : String -> Maybe String -> String -> FrameEvent
textFrame tag hid text =
    { sessionId = "s1"
    , tag = tag
    , rawValue = ""
    , historyId = hid
    , content = Just text
    , json = Nothing
    , userContentType = Nothing
    }


toolCall : String -> String -> D.Value
toolCall id name =
    E.object
        [ ( "id", E.string id )
        , ( "name", E.string name )
        , ( "input", E.object [] )
        ]


-- Start AF frame as alayacore emits it live: id + name only (input is
-- delivered later in a separate complete frame).
toolCallStart : String -> String -> D.Value
toolCallStart id name =
    E.object
        [ ( "id", E.string id )
        , ( "name", E.string name )
        ]


-- Complete AF frame: id + input only (name is omitted by the wire
-- protocol; some adapters send it as an explicit empty string).
toolCallInput : String -> D.Value -> D.Value
toolCallInput id input =
    E.object
        [ ( "id", E.string id )
        , ( "input", input )
        ]


toolCallInputWithEmptyName : String -> D.Value -> D.Value
toolCallInputWithEmptyName id input =
    E.object
        [ ( "id", E.string id )
        , ( "name", E.string "" )
        , ( "input", input )
        ]


toolResult : String -> D.Value -> D.Value
toolResult id output =
    E.object
        [ ( "id", E.string id )
        , ( "output", output )
        ]


toolPreview : String -> String -> D.Value
toolPreview id text =
    E.object
        [ ( "id", E.string id )
        , ( "text", E.string text )
        ]


msgContent : SessionState -> String
msgContent s =
    case List.reverse s.messages |> List.head of
        Just m ->
            m.content

        Nothing ->
            ""


msgHistoryId : SessionState -> Maybe String
msgHistoryId s =
    case List.reverse s.messages |> List.head of
        Just m ->
            m.historyId

        Nothing ->
            Nothing


-- A session with one tool call started (AF).
withToolCall : SessionState
withToolCall =
    emptySession "s1"
        |> applyFrame (frame "AF" (toolCall "t1" "execute_command"))


tests : Test
tests =
    describe "Session.Handlers tool frames"
        [ describe "AF (tool call)"
            [ test "creates a message with empty body (header only)" <|
                \_ ->
                    Expect.equal "" (msgContent withToolCall)
            , test "start frame creates the call with no input yet" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCallStart "t1" "edit_file"))
                    in
                    case Dict.get "t1" s.toolCalls of
                        Just tc ->
                            Expect.equal (tc.name, tc.input) ( "edit_file", Nothing )

                        Nothing ->
                            Expect.fail "tool call missing after AF start"
            , test "complete frame fills the input into the existing call" <|
                \_ ->
                    let
                        input =
                            E.object
                                [ ( "path", E.string "src/Main.elm" )
                                , ( "old_string", E.string "old" )
                                , ( "new_string", E.string "new" )
                                ]

                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCallStart "t1" "edit_file"))
                                |> applyFrame (frame "AF" (toolCallInput "t1" input))
                    in
                    case Dict.get "t1" s.toolCalls of
                        Just c ->
                            case c.input of
                                Just d ->
                                    case Dict.get "raw" d of
                                        Just raw ->
                                            Expect.equal (D.decodeValue (D.field "path" D.string) raw) (Ok "src/Main.elm")

                                        Nothing ->
                                            Expect.fail "raw input missing"

                                Nothing ->
                                    Expect.fail "input missing after AF complete"

                        Nothing ->
                            Expect.fail "tool call missing after AF complete"
            , test "complete frame does not create a duplicate message" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCallStart "t1" "edit_file"))
                                |> applyFrame (frame "AF" (toolCallInput "t1" (E.object [])))
                    in
                    Expect.equal 1 (List.length (List.filter (\m -> m.toolId == Just "t1") s.messages))
            , test "complete frame with explicit empty name also fills the input" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCallStart "t1" "edit_file"))
                                |> applyFrame (frame "AF" (toolCallInputWithEmptyName "t1" (E.object [])))
                    in
                    case Dict.get "t1" s.toolCalls of
                        Just tc ->
                            Expect.equal True (tc.input /= Nothing)

                        Nothing ->
                            Expect.fail "tool call missing"
            , test "complete frame before the start frame is ignored" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCallInput "t1" (E.object [])))
                    in
                    Expect.equal Dict.empty s.toolCalls
            , test "full replayed frame (name + input) creates the call with input" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCall "t1" "write_file"))
                    in
                    case Dict.get "t1" s.toolCalls of
                        Just tc ->
                            Expect.equal True (tc.input /= Nothing)

                        Nothing ->
                            Expect.fail "tool call missing after replayed AF"
            , test "complete frame clears streamed input text from the message body" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (frame "AF" (toolCallStart "t1" "edit_file"))
                                |> applyFrame (frame "Af" (E.object [ ( "id", E.string "t1" ), ( "delta", E.string "{\"path\":" ) ]))
                                |> applyFrame (frame "AF" (toolCallInput "t1" (E.object [])))
                    in
                    Expect.equal "" (msgContent s)
            ]
        , describe "UF (authoritative result)"
            [ test "renders text output blocks joined by newline (no prefix)" <|
                \_ ->
                    let
                        s =
                            withToolCall
                                |> applyFrame
                                    (frame "UF"
                                        (toolResult "t1"
                                            (E.list identity
                                                [ E.object [ ( "type", E.string "text" ), ( "text", E.string "hello" ) ]
                                                , E.object [ ( "type", E.string "text" ), ( "text", E.string "world" ) ]
                                                ]
                                            )
                                        )
                                    )
                    in
                    Expect.equal "hello\nworld" (msgContent s)
            , test "falls back to placeholder when output has no text" <|
                \_ ->
                    let
                        s =
                            withToolCall
                                |> applyFrame (frame "UF" (toolResult "t1" (E.list identity [])))
                    in
                    contains "<output received>" (msgContent s)
            , test "renders error code and message (no prefix)" <|
                \_ ->
                    let
                        s =
                            withToolCall
                                |> applyFrame
                                    (frame "UF"
                                        (E.object
                                            [ ( "id", E.string "t1" )
                                            , ( "is_error", E.bool True )
                                            , ( "output"
                                              , E.object
                                                    [ ( "code", E.string "E2" )
                                                    , ( "message", E.string "boom" )
                                                    ]
                                              )
                                            ]
                                        )
                                    )
                    in
                    Expect.equal "E2: boom" (msgContent s)
            , test "truncates long output" <|
                \_ ->
                    let
                        longText =
                            String.repeat 9000 "x"

                        s =
                            withToolCall
                                |> applyFrame
                                    (frame "UF"
                                        (toolResult "t1"
                                            (E.list identity
                                                [ E.object [ ( "type", E.string "text" ), ( "text", E.string longText ) ]
                                                ]
                                            )
                                        )
                                    )
                    in
                    contains "truncated" (msgContent s)
            , test "ends input streaming so the header status flips to done" <|
                \_ ->
                    let
                        delta v =
                            frame "Af"
                                (E.object
                                    [ ( "id", E.string "t1" )
                                    , ( "delta", E.string v )
                                    ]
                                )

                        s =
                            withToolCall
                                |> applyFrame (delta "{\"cmd\":\"ls\"}")
                                |> applyFrame (frame "UF" (toolResult "t1" (E.list identity [])))

                        tc =
                            Dict.get "t1" s.toolCalls
                    in
                    case tc of
                        Just t ->
                            Expect.equal
                                ( Nothing, Nothing )
                                ( t.output, t.accumulatedDelta )

                        Nothing ->
                            Expect.fail "tool call missing after UF"
            ]
        , describe "Uf (ephemeral preview)"
            [ test "is a snapshot: each frame replaces the previous" <|
                \_ ->
                    let
                        s =
                            withToolCall
                                |> applyFrame (frame "Uf" (toolPreview "t1" "one"))
                                |> applyFrame (frame "Uf" (toolPreview "t1" "two"))
                    in
                    msgContent s
                        |> Expect.all
                            [ contains "two"
                            , notContains "one"
                            ]
            , test "ignored for unknown tool ids" <|
                \_ ->
                    withToolCall
                        |> applyFrame (frame "Uf" (toolPreview "ghost" "nope"))
                        |> msgContent
                        |> notContains "nope"
            , test "authoritative UF overwrites the preview" <|
                \_ ->
                    let
                        s =
                            withToolCall
                                |> applyFrame (frame "Uf" (toolPreview "t1" "live preview"))
                                |> applyFrame
                                    (frame "UF"
                                        (toolResult "t1"
                                            (E.list identity
                                                [ E.object [ ( "type", E.string "text" ), ( "text", E.string "final" ) ]
                                                ]
                                            )
                                        )
                                    )
                    in
                    msgContent s
                        |> Expect.all
                            [ contains "final"
                            , notContains "live preview"
                            ]
            ]
        , describe "Af (argument delta)"
            [ test "accumulates partial JSON chunks" <|
                \_ ->
                    let
                        delta v =
                            frame "Af"
                                (E.object
                                    [ ( "id", E.string "t1" )
                                    , ( "delta", E.string v )
                                    ]
                                )

                        s =
                            withToolCall
                                |> applyFrame (delta "{\"cmd\":\"ls\"")
                                |> applyFrame (delta ",\"flag\":true}")
                    in
                    contains "{\"cmd\":\"ls\",\"flag\":true}" (msgContent s)
            ]
        , describe "resume replay rendering"
            [ test "replayed history renders completely (user, assistant, tool call/result)" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame (textFrame "UT" (Just "1") "Collect data from sales.db")
                                |> applyFrame (textFrame "AT" (Just "2") "I will read the file now.")
                                |> applyFrame (frame "AF" (toolCall "t1" "read_file"))
                                |> applyFrame
                                    (frame "UF"
                                        (toolResult "t1"
                                            (E.list identity
                                                [ E.object
                                                    [ ( "type", E.string "text" )
                                                    , ( "text", E.string "found 42 rows" )
                                                    ]
                                                ]
                                            )
                                        )
                                    )
                                |> applyFrame (textFrame "AT" (Just "5") "Done. 42 rows collected.")
                    in
                    Expect.all
                        [ \st -> Expect.equal 4 (List.length st.messages)
                        , \st -> Expect.equal True (List.any (\m -> m.content == "Collect data from sales.db") st.messages)
                        , \st -> Expect.equal True (List.any (\m -> m.content == "I will read the file now.") st.messages)
                        , \st -> Expect.equal True (List.any (\m -> m.toolName == Just "read_file") st.messages)
                        , \st -> Expect.equal True (List.any (\m -> m.content == "found 42 rows") st.messages)
                        , \st -> Expect.equal True (List.any (\m -> m.content == "Done. 42 rows collected.") st.messages)
                        ]
                        s
            ]
        , describe "plan-result continuation insertion (R3 feedback echo)"
            [ test "appends the [Plan Result] user echo and reply without touching earlier messages" <|
                \_ ->
                    let
                        planJson =
                            "```json\n{\"type\":\"alayaface-plan\",\"schema_version\":1,\"name\":\"P\",\"tasks\":[]}\n```"

                        s =
                            emptySession "s1"
                                |> applyFrame (textFrame "UT" (Just "1") "make a plan")
                                |> applyFrame (textFrame "AT" (Just "2") planJson)
                                -- plan runs, completes: feedback prompt is
                                -- echoed as a NEW user message (hid 3) and
                                -- the model's continuation as AT (hid 4).
                                |> applyFrame (textFrame "UT" (Just "3") "[Plan Result] The plan has completed. Results:\n\n## t1\nok\n\n[Plan: p1]")
                                |> applyFrame (textFrame "AT" (Just "4") "The plan finished; here is the outcome.")
                    in
                    Expect.all
                        [ \st -> Expect.equal 4 (List.length st.messages)
                        , \st ->
                            Expect.equal
                                [ "make a plan", planJson, "[Plan Result] The plan has completed. Results:\n\n## t1\nok\n\n[Plan: p1]", "The plan finished; here is the outcome." ]
                                (List.map .content st.messages)
                        , \st -> Expect.equal False (List.any (\m -> m.isError) st.messages)
                        ]
                        s
            , test "earlier user/assistant messages survive when the plan reply streams deltas" <|
                \_ ->
                    let
                        planJson =
                            "```json\n{\"type\":\"alayaface-plan\",\"schema_version\":1,\"name\":\"P\",\"tasks\":[]}\n```"

                        -- Real alayacore in delta mode: At carries chunks
                        -- via the DeltaEvent port (accumulated per
                        -- history id), AT is an empty terminator.
                        delta v =
                            { sessionId = "s1"
                            , historyId = "4"
                            , content = v
                            , tag = "At"
                            }

                        s0 =
                            emptySession "s1"
                                |> applyFrame (textFrame "UT" (Just "1") "make a plan")
                                |> applyFrame (textFrame "AT" (Just "2") planJson)
                                |> applyFrame (textFrame "UT" (Just "3") "[Plan Result] done")

                        s =
                            H.handleDeltaEvent (H.handleDeltaEvent s0 (delta "The plan ")) (delta "finished.")
                    in
                    Expect.all
                        [ \st -> Expect.equal 4 (List.length st.messages)
                        , \st -> Expect.equal "The plan finished." (msgContent st)
                        , \st -> Expect.equal True (List.any (\m -> m.content == planJson) st.messages)
                        , \st -> Expect.equal True (List.any (\m -> m.content == "make a plan") st.messages)
                        ]
                        s
            , test "same role+historyId replaces content in place (idempotent replay), never appends" <|
                \_ ->
                    let
                        -- This is the ONLY code path that can overwrite an
                        -- earlier message: handleCompleteFrame /
                        -- handleDeltaEvent key on (role, historyId). Under
                        -- normal operation alayacore never reuses a history
                        -- id in the same process, so this only fires on
                        -- replay (same content, harmless) or after a
                        -- restart whose restored counter is stale (new
                        -- reply reusing an old id → earlier message
                        -- overwritten).
                        s =
                            emptySession "s1"
                                |> applyFrame (textFrame "UT" (Just "1") "hello")
                                |> applyFrame (textFrame "AT" (Just "2") "first answer")
                                |> applyFrame (textFrame "AT" (Just "2") "second answer")
                    in
                    Expect.all
                        [ \st -> Expect.equal 2 (List.length st.messages)
                        , \st ->
                            Expect.equal
                                [ "hello", "second answer" ]
                                (List.map .content st.messages)
                        ]
                        s
            , test "merges the feedback echo into a still-last user message (known edge: prompt sent while plan ran)" <|
                \_ ->
                    let
                        planJson =
                            "```json\n{\"type\":\"alayaface-plan\",\"schema_version\":1,\"name\":\"P\",\"tasks\":[]}\n```"

                        -- The user typed a follow-up while the plan was
                        -- running and the model had not replied yet, so the
                        -- last message is User when the feedback echo lands:
                        -- the echo is merged into that message (multi-part
                        -- echo behavior), NOT appended as its own message.
                        s =
                            emptySession "s1"
                                |> applyFrame (textFrame "UT" (Just "1") "make a plan")
                                |> applyFrame (textFrame "AT" (Just "2") planJson)
                                |> applyFrame (textFrame "UT" (Just "3") "meanwhile, check X")
                                |> applyFrame (textFrame "UT" (Just "4") "[Plan Result] done")
                    in
                    Expect.all
                        [ \st -> Expect.equal 3 (List.length st.messages)
                        , \st ->
                            Expect.equal
                                [ "make a plan", planJson, "meanwhile, check X\n\n[Plan Result] done" ]
                                (List.map .content st.messages)
                        , \st -> Expect.equal (Just "4") (msgHistoryId st)
                        ]
                        s
            ]
        , describe "system task/model frames (token usage + speed)"
            [ test "task frame context updates the session token count" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame
                                    (frame "SM"
                                        (E.object
                                            [ ( "type", E.string "task" )
                                            , ( "data"
                                              , E.object
                                                    [ ( "in_progress", E.bool False )
                                                    , ( "context", E.int 4096 )
                                                    ]
                                              )
                                            ]
                                        )
                                    )
                    in
                    Expect.equal 4096 s.contextTokens
            , test "task frame falls back to the legacy context_tokens field" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame
                                    (frame "SM"
                                        (E.object
                                            [ ( "type", E.string "task" )
                                            , ( "data"
                                              , E.object
                                                    [ ( "in_progress", E.bool False )
                                                    , ( "context_tokens", E.int 2048 )
                                                    ]
                                              )
                                            ]
                                        )
                                    )
                    in
                    Expect.equal 2048 s.contextTokens
            , test "task frame step_tps/ttft_ms update the speed readout" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame
                                    (frame "SM"
                                        (E.object
                                            [ ( "type", E.string "task" )
                                            , ( "data"
                                              , E.object
                                                    [ ( "in_progress", E.bool True )
                                                    , ( "current_step", E.int 2 )
                                                    , ( "max_steps", E.int 10 )
                                                    , ( "context", E.int 8600 )
                                                    , ( "step_tps", E.float 12.5 )
                                                    , ( "ttft_ms", E.int 1200 )
                                                    ]
                                              )
                                            ]
                                        )
                                    )
                    in
                    Expect.all
                        [ \st -> Expect.within (Expect.Absolute 0.0001) 12.5 st.taskStepTps
                        , \st -> Expect.equal 1200 st.taskTtftMs
                        , \st -> Expect.equal 8600 st.contextTokens
                        , \st -> Expect.equal True st.taskRunning
                        , \st -> Expect.equal 2 st.taskCurrentStep
                        , \st -> Expect.equal 10 st.taskMaxSteps
                        ]
                        s
            , test "task frame without speed fields leaves the readout empty" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame
                                    (frame "SM"
                                        (E.object
                                            [ ( "type", E.string "task" )
                                            , ( "data"
                                              , E.object
                                                    [ ( "in_progress", E.bool False )
                                                    , ( "context", E.int 100 )
                                                    ]
                                              )
                                            ]
                                        )
                                    )
                    in
                    Expect.all
                        [ \st -> Expect.equal 0 st.taskStepTps
                        , \st -> Expect.equal 0 st.taskTtftMs
                        , \st -> Expect.equal False st.taskRunning
                        ]
                        s
            , test "model frame context_limit updates the session limit" <|
                \_ ->
                    let
                        s =
                            emptySession "s1"
                                |> applyFrame
                                    (frame "SM"
                                        (E.object
                                            [ ( "type", E.string "model" )
                                            , ( "data"
                                              , E.object
                                                    [ ( "active_id", E.int 1 )
                                                    , ( "active_name", E.string "fake-model-1" )
                                                    , ( "context_limit", E.int 8192 )
                                                    ]
                                              )
                                            ]
                                        )
                                    )
                    in
                    Expect.equal 8192 s.contextLimit
            ]
        ]
