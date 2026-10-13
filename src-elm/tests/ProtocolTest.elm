module ProtocolTest exposing (tests)

import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)
import Session.Protocol as P


tests : Test
tests =
    describe "Session.Protocol"
        [ describe "isUserEchoTag"
            [ test "the UX plane is the user echo (v14)" <|
                \_ ->
                    Expect.equal True (P.isUserEchoTag "UX")
            , test "non-echo tags" <|
                \_ ->
                    Expect.equal False (P.isUserEchoTag "AX")
            ]
        , describe "historyKeyOf"
            [ test "the content kind is part of the key" <|
                \_ ->
                    Expect.equal "text:h1" (P.historyKeyOf "text" "h1")
            , test "text and reasoning under one id are distinct blocks" <|
                \_ ->
                    Expect.notEqual (P.historyKeyOf "text" "h1") (P.historyKeyOf "reasoning" "h1")
            ]
        , describe "deltaEventDecoder"
            [ test "decodes a delta event" <|
                \_ ->
                    let
                        json =
                            E.object
                                [ ( "session_id", E.string "s1" )
                                , ( "history_id", E.string "h1" )
                                , ( "content", E.string "hi" )
                                , ( "tag", E.string "Ax" )
                                , ( "content_type", E.string "text" )
                                ]
                    in
                    D.decodeValue P.deltaEventDecoder json
                        |> Expect.equal
                            (Ok (P.DeltaEvent "s1" "h1" "hi" "Ax" "text"))
            ]
        , describe "frameEventDecoder"
            [ test "decodes a content frame's content_type" <|
                \_ ->
                    let
                        json =
                            E.object
                                [ ( "session_id", E.string "s1" )
                                , ( "tag", E.string "AX" )
                                , ( "raw_value", E.string "{}" )
                                , ( "history_id", E.string "h1" )
                                , ( "content", E.string "hi" )
                                , ( "json", E.null )
                                , ( "content_type", E.string "reasoning" )
                                ]
                    in
                    D.decodeValue P.frameEventDecoder json
                        |> Result.map .contentType
                        |> Expect.equal (Ok (Just "reasoning"))
            ]
        ]
