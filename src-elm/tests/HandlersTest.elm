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


toolCall : String -> String -> D.Value
toolCall id name =
    E.object
        [ ( "id", E.string id )
        , ( "name", E.string name )
        , ( "input", E.object [] )
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
        ]
