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
            [ test "user echo tags" <|
                \_ ->
                    List.map P.isUserEchoTag [ "UT", "UI", "UV", "UA", "UD" ]
                        |> Expect.equal [ True, True, True, True, True ]
            , test "non-echo tags" <|
                \_ ->
                    Expect.equal False (P.isUserEchoTag "AT")
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
                                , ( "tag", E.string "At" )
                                ]
                    in
                    D.decodeValue P.deltaEventDecoder json
                        |> Expect.equal
                            (Ok (P.DeltaEvent "s1" "h1" "hi" "At"))
            ]
        ]
