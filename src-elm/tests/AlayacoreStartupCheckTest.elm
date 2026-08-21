module AlayacoreStartupCheckTest exposing (tests)

{-| Pins the startup check handler: the probe runs once on init() and
the home screen reads model.alayacoreCheck to decide whether to show
the "AlayaCore not found" banner. The handler must store the FULL
{ ok, path, error } payload (not just a boolean) so the view can show
the resolved path on success and the user-facing error on failure.
-}

import Expect
import Json.Encode as E
import App.Types as AT
import App.Update
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


tests : Test
tests =
    describe "App/Update.AlayacoreCheckResult"
        [ test "ok=true stores the resolved path" <|
            \_ ->
                let
                    payload =
                        E.object
                            [ ( "ok", E.bool True )
                            , ( "path", E.string "/usr/local/bin/alayacore" )
                            , ( "error", E.string "" )
                            ]

                    ( m1, _ ) =
                        App.Update.update (AT.AlayacoreCheckResult payload) initModelWithSession
                in
                case m1.alayacoreCheck of
                    Just { ok, path, error } ->
                        Expect.all
                            [ \_ -> Expect.equal ok True
                            , \_ -> Expect.equal path "/usr/local/bin/alayacore"
                            , \_ -> Expect.equal error ""
                            ]
                            ()

                    Nothing ->
                        Expect.fail "alayacoreCheck was not stored"
        , test "ok=false stores the user-facing error message" <|
            \_ ->
                let
                    payload =
                        E.object
                            [ ( "ok", E.bool False )
                            , ( "path", E.string "" )
                            , ( "error", E.string "AlayaCore binary not found at '/missing/alayacore'. Set the ALAYACORE_BIN environment variable or install alayacore on PATH." )
                            ]

                    ( m1, _ ) =
                        App.Update.update (AT.AlayacoreCheckResult payload) initModelWithSession
                in
                case m1.alayacoreCheck of
                    Just { ok, path, error } ->
                        Expect.all
                            [ \_ -> Expect.equal ok False
                            , \_ -> Expect.equal path ""
                            , \_ -> Expect.equal error "AlayaCore binary not found at '/missing/alayacore'. Set the ALAYACORE_BIN environment variable or install alayacore on PATH."
                            ]
                            ()

                    Nothing ->
                        Expect.fail "alayacoreCheck was not stored"
        , test "a malformed payload leaves the model unchanged" <|
            \_ ->
                -- The backend always serializes the field set, but a
                -- future schema change should not crash the app — drop
                -- the bad payload and keep showing no banner.
                let
                    ( m1, _ ) =
                        App.Update.update (AT.AlayacoreCheckResult E.null) initModelWithSession
                in
                Expect.equal m1.alayacoreCheck initModelWithSession.alayacoreCheck
        ]
