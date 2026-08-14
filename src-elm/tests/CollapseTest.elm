module CollapseTest exposing (tests)

import Dict
import Expect
import Session.Types exposing (Message, Role(..), defaultCollapsed, isMsgCollapsed, toggleMsgCollapsed)
import Test exposing (Test, describe, test)


msg : String -> Role -> Message
msg id role =
    { id = id
    , role = role
    , content = "some content"
    , toolId = Nothing
    , toolName = Nothing
    , isError = False
    , historyId = Nothing
    , media = Nothing
    }


tests : Test
tests =
    describe "message collapse"
        [ describe "defaultCollapsed"
            [ test "tool messages are collapsed by default" <|
                \_ -> Expect.equal True (defaultCollapsed Tool)
            , test "reasoning messages are collapsed by default" <|
                \_ -> Expect.equal True (defaultCollapsed Reasoning)
            , test "user messages are expanded by default" <|
                \_ -> Expect.equal False (defaultCollapsed User)
            , test "assistant messages are expanded by default" <|
                \_ -> Expect.equal False (defaultCollapsed Assistant)
            , test "system is expanded by default; notify/error frames are collapsed" <|
                \_ ->
                    Expect.equal
                        [ False, True, True ]
                        [ defaultCollapsed System
                        , defaultCollapsed Notify
                        , defaultCollapsed Error
                        ]
            ]
        , describe "isMsgCollapsed"
            [ test "no explicit state falls back to the role default (tool)" <|
                \_ -> Expect.equal True (isMsgCollapsed Dict.empty (msg "t1" Tool))
            , test "no explicit state falls back to the role default (user)" <|
                \_ -> Expect.equal False (isMsgCollapsed Dict.empty (msg "u1" User))
            , test "explicit True wins over the role default" <|
                \_ ->
                    Expect.equal True
                        (isMsgCollapsed (Dict.fromList [ ( "u1", True ) ]) (msg "u1" User))
            , test "explicit False wins over the role default (user expanded a tool)" <|
                \_ ->
                    Expect.equal False
                        (isMsgCollapsed (Dict.fromList [ ( "t1", False ) ]) (msg "t1" Tool))
            , test "state is keyed per message id" <|
                \_ ->
                    let
                        dict =
                            Dict.fromList [ ( "t1", False ) ]
                    in
                    Expect.equal
                        ( False, True )
                        ( isMsgCollapsed dict (msg "t1" Tool)
                        , isMsgCollapsed dict (msg "t2" Tool)
                        )
            ]
        , describe "toggleMsgCollapsed"
            [ test "collapsing a default-expanded user message stores True" <|
                \_ ->
                    let
                        dict =
                            toggleMsgCollapsed Dict.empty (msg "u1" User)
                    in
                    Expect.equal (Just True) (Dict.get "u1" dict)
            , test "expanding a default-collapsed tool message stores False" <|
                \_ ->
                    let
                        dict =
                            toggleMsgCollapsed Dict.empty (msg "t1" Tool)
                    in
                    Expect.equal (Just False) (Dict.get "t1" dict)
            , test "toggling twice returns to the original state" <|
                \_ ->
                    let
                        m =
                            msg "t1" Tool

                        dict =
                            toggleMsgCollapsed (toggleMsgCollapsed Dict.empty m) m
                    in
                    Expect.equal True (isMsgCollapsed dict m)
            , test "toggling alternates explicit state correctly" <|
                \_ ->
                    let
                        m =
                            msg "u1" User

                        once =
                            toggleMsgCollapsed Dict.empty m

                        twice =
                            toggleMsgCollapsed once m

                        thrice =
                            toggleMsgCollapsed twice m
                    in
                    Expect.equal
                        ( True, False, True )
                        ( isMsgCollapsed once m
                        , isMsgCollapsed twice m
                        , isMsgCollapsed thrice m
                        )
            , test "toggling one message leaves other entries untouched" <|
                \_ ->
                    let
                        base =
                            Dict.fromList [ ( "u1", True ) ]

                        dict =
                            toggleMsgCollapsed base (msg "t1" Tool)
                    in
                    Expect.equal
                        ( Just True, Just False )
                        ( Dict.get "u1" dict, Dict.get "t1" dict )
            ]
        ]
