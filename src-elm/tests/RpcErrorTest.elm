module RpcErrorTest exposing (suite)

import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import App.Update
import App.Types as AT
import Dict
import TestHelpers exposing (initModelWithSession)


suite : Test
suite =
    describe "RpcError handling"
        [ test "send_prompt failure clears sendPending and shows the error" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "kind", E.string "send_prompt" )
                            , ( "sessionId", E.string "s1" )
                            , ( "message", E.string "Session is disconnected" )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.RpcError raw) model
                in
                case Dict.get "s1" updated.sessions of
                    Just s ->
                        Expect.equal ( s.sendPending, s.statusMsg )
                            ( False, "send_prompt failed: Session is disconnected" )

                    Nothing ->
                        Expect.fail "session s1 missing"
        , test "unknown session ignores the error" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        E.object
                            [ ( "kind", E.string "send_prompt" )
                            , ( "sessionId", E.string "nope" )
                            , ( "message", E.string "x" )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.RpcError raw) model
                in
                Expect.equal (Dict.size updated.sessions) 1
        ]
