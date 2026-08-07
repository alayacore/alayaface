module PlanMetaTest exposing (tests)

import Expect
import Json.Decode as D
import Json.Encode as E
import Plan.Meta as M
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Plan.Meta"
        [ test "encode then decode roundtrips" <|
            \_ ->
                let
                    meta =
                        { origin = { sessionId = "s-1", planIndex = 2 }
                        , feedbacks = [ { at = 100, status = "completed", text = "done", planId = "p-1" } ]
                        , createdAt = 50
                        }

                    encoded =
                        E.encode 2 (M.encodeMeta meta)

                    decoded =
                        D.decodeString M.decodeMeta encoded
                in
                case decoded of
                    Ok m2 ->
                        Expect.all
                            [ \m -> Expect.equal { sessionId = "s-1", planIndex = 2 } m.origin
                            , \m -> Expect.equal 1 (List.length m.feedbacks)
                            , \m -> Expect.equal 50 m.createdAt
                            ]
                            m2

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , test "strict: missing origin is rejected (every plan has one)" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "created_at": 7 }""" of
                    Ok _ ->
                        Expect.fail "meta without origin must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing planIndex is rejected" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1" }, "created_at": 7 }""" of
                    Ok _ ->
                        Expect.fail "origin without planIndex must be rejected"

                    Err _ ->
                        Expect.pass
        , test "strict: missing created_at is rejected" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "planIndex": 1 }, "feedbacks": [] }""" of
                    Ok _ ->
                        Expect.fail "meta without created_at must be rejected"

                    Err _ ->
                        Expect.pass
        ]
