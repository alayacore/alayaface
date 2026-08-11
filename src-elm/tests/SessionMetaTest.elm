module SessionMetaTest exposing (suite)

{-| Direct unit tests for Session/Meta (P39/Phase B): the session
lineage codec (sessions/<id>/session.meta.json — conversation id +
parent instance pointer) and the instance→conversation resolver.
-}

import Expect
import Test exposing (Test, describe, test)
import Dict
import Json.Decode as D
import Json.Encode as E
import Session.Meta as SM


suite : Test
suite =
    describe "Session/Meta (lineage)"
        [ describe "encode/decode"
            [ test "round-trips a root (no parent)" <|
                \_ ->
                    let
                        m =
                            SM.empty "root-1"
                    in
                    Expect.equal (D.decodeString SM.decode (E.encode 2 (SM.encode m)))
                        (Ok m)
            , test "round-trips a fork (parent pointer)" <|
                \_ ->
                    let
                        m =
                            { conversationId = "root-1", parentInstanceId = Just "root-1" }
                    in
                    Expect.equal (D.decodeString SM.decode (E.encode 2 (SM.encode m)))
                        (Ok m)
            , test "decodes a file with no parent field (pre-lineage roots)" <|
                \_ ->
                    Expect.equal
                        (D.decodeString SM.decode """{"conversation_id":"root-1"}""")
                        (Ok (SM.empty "root-1"))
            , test "null parent decodes to Nothing" <|
                \_ ->
                    Expect.equal
                        (D.decodeString SM.decode """{"conversation_id":"root-1","parent_instance_id":null}""")
                        (Ok (SM.empty "root-1"))
            , test "missing conversation_id fails the decode" <|
                \_ ->
                    case D.decodeString SM.decode """{"parent_instance_id":"x"}""" of
                        Err _ ->
                            Expect.pass

                        Ok _ ->
                            Expect.fail "expected decode failure"
            ]
        , describe "metaPathFor"
            [ test "is the session dir + session.meta.json" <|
                \_ ->
                    Expect.equal (SM.metaPathFor "sess-1") "sess-1/session.meta.json"
            ]
        , describe "resolveConversation"
            [ test "maps an instance to its conversation id" <|
                \_ ->
                    let
                        registry =
                            Dict.fromList
                                [ ( "root-1", SM.empty "root-1" )
                                , ( "fork-2", { conversationId = "root-1", parentInstanceId = Just "root-1" } )
                                ]
                    in
                    Expect.all
                        [ \_ -> Expect.equal (SM.resolveConversation registry "fork-2") "root-1"
                        , \_ -> Expect.equal (SM.resolveConversation registry "root-1") "root-1"
                        ]
                        ()
            , test "unknown instances resolve to themselves (root fallback)" <|
                \_ ->
                    Expect.equal (SM.resolveConversation Dict.empty "new-sess") "new-sess"
            ]
        , describe "headInstanceFor"
            [ test "the instance that is nobody's parent is the head" <|
                \_ ->
                    let
                        registry =
                            Dict.fromList
                                [ ( "root-1", SM.empty "root-1" )
                                , ( "fork-2", { conversationId = "root-1", parentInstanceId = Just "root-1" } )
                                , ( "fork-3", { conversationId = "root-1", parentInstanceId = Just "fork-2" } )
                                , ( "other", SM.empty "other" )
                                ]
                    in
                    -- fork-3 is never a parent → head of conv root-1.
                    Expect.equal (SM.headInstanceFor registry "root-1") (Just "fork-3")
            , test "a root with no forks is its own head" <|
                \_ ->
                    let
                        registry =
                            Dict.fromList [ ( "root-1", SM.empty "root-1" ) ]
                    in
                    Expect.equal (SM.headInstanceFor registry "root-1") (Just "root-1")
            , test "unknown conversation → Nothing (caller falls back to the conversation id)" <|
                \_ ->
                    Expect.equal (SM.headInstanceFor Dict.empty "ghost") Nothing
            , test "other conversations' forks never shadow the head" <|
                \_ ->
                    let
                        registry =
                            Dict.fromList
                                [ ( "root-1", SM.empty "root-1" )
                                , ( "root-2", SM.empty "root-2" )
                                , ( "fork-2a", { conversationId = "root-2", parentInstanceId = Just "root-2" } )
                                ]
                    in
                    Expect.equal (SM.headInstanceFor registry "root-1") (Just "root-1")
            ]
        ]
