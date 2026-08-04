module ProtocolTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Session.Protocol as P


tests : Test
tests =
    describe "Session.Protocol"
        [ describe "parseDelta"
            [ test "parses a NUL-delimited frame" <|
                \_ ->
                    Expect.equal (Just ( "abc-1", "hello" )) (P.parseDelta "\u{0000}abc-1\u{0000}hello")
            , test "Nothing for a bare value" <|
                \_ ->
                    Expect.equal Nothing (P.parseDelta "hello")
            , test "Nothing for an empty id" <|
                \_ ->
                    Expect.equal Nothing (P.parseDelta "\u{0000}\u{0000}hello")
            , test "keeps NULs inside the content" <|
                \_ ->
                    Expect.equal (Just ( "id", "a\u{0000}b" )) (P.parseDelta "\u{0000}id\u{0000}a\u{0000}b")
            ]
        , describe "wrapDelta"
            [ test "round-trips with parseDelta" <|
                \_ ->
                    Expect.equal (Just ( "h1", "payload" )) (P.parseDelta (P.wrapDelta "h1" "payload"))
            ]
        , describe "isUserEchoTag"
            [ test "user echo tags" <|
                \_ ->
                    List.map P.isUserEchoTag [ "UT", "UI", "UV", "UA", "UD" ]
                        |> Expect.equal [ True, True, True, True, True ]
            , test "non-echo tags" <|
                \_ ->
                    Expect.equal False (P.isUserEchoTag "AT")
            ]
        ]
