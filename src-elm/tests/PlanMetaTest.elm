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
                        { origin = Just { sessionId = "s-1", planIndex = 2, messageId = Nothing }
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
                            [ \m -> Expect.equal (Just { sessionId = "s-1", planIndex = 2, messageId = Nothing }) m.origin
                            , \m -> Expect.equal 1 (List.length m.feedbacks)
                            , \m -> Expect.equal 50 m.createdAt
                            ]
                            m2

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , test "legacy origin (messageId, no planIndex) decodes with planIndex -1" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "origin": { "sessionId": "s-1", "messageId": "hist-1" }, "created_at": 1 }""" of
                    Ok m ->
                        -- planIndex -1 never matches a real message, but
                        -- sessionId survives so feedback routing still works.
                        Expect.equal
                            (Just { sessionId = "s-1", planIndex = -1, messageId = Just "hist-1" })
                            m.origin

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , test "lenient: missing origin and feedbacks decode to defaults" <|
            \_ ->
                case D.decodeString M.decodeMeta """{ "created_at": 7 }""" of
                    Ok m ->
                        Expect.all
                            [ \mm -> Expect.equal Nothing mm.origin
                            , \mm -> Expect.equal [] mm.feedbacks
                            , \mm -> Expect.equal 7 mm.createdAt
                            ]
                            m

                    Err e ->
                        Expect.fail ("decode failed: " ++ D.errorToString e)
        , test "metaPathFor joins the plans dir" <|
            \_ ->
                Expect.equal "/home/u/.alayaface/plans/demo-1.meta.json"
                    (M.metaPathFor "/home/u/.alayaface/plans" "demo-1")
        ]
