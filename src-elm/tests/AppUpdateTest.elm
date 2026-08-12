module AppUpdateTest exposing (tests)

import Dict
import Set
import Expect
import Plan.Update as PU
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)
import Arch.Values as AV


tests : Test
tests =
    describe "App/Update (C2b session ownership)"
        [ describe "work-copy routing helpers"
            [ test "workCopyId resolves Session.id → core id; falls back to itself" <|
                \_ ->
                    let
                        m =
                            { initModelWithSession | sessionWorkCopies = Dict.fromList [ ( "s1", "s2" ) ] }
                    in
                    Expect.all
                        [ \mm -> Expect.equal (PU.workCopyId mm "s1") "s2"
                        , \mm -> Expect.equal (PU.workCopyId mm "other") "other"
                        ]
                        m
            , test "sessionIdOfWorkCopy resolves core id → Session.id; falls back to itself" <|
                \_ ->
                    let
                        m =
                            { initModelWithSession | sessionWorkCopies = Dict.fromList [ ( "s1", "s2" ) ] }
                    in
                    Expect.all
                        [ \mm -> Expect.equal (PU.sessionIdOfWorkCopy mm "s2") "s1"
                        , \mm -> Expect.equal (PU.sessionIdOfWorkCopy mm "s1") "s1"
                        ]
                        m
            , test "a session with several forks maps its own core id back to itself" <|
                \_ ->
                    -- Multiple forks: workCopies[s1] = s3 (latest work copy).
                    -- s1's own frames (coreId = s1) → s1; s3's frames → s1;
                    -- the intermediate work copy s2 is no longer referenced
                    -- (it was deleted).
                    let
                        m =
                            { initModelWithSession | sessionWorkCopies = Dict.fromList [ ( "s1", "s3" ) ] }
                    in
                    Expect.all
                        [ \mm -> Expect.equal (PU.sessionIdOfWorkCopy mm "s1") "s1"
                        , \mm -> Expect.equal (PU.sessionIdOfWorkCopy mm "s3") "s1"
                        , \mm -> Expect.equal (PU.workCopyId mm "s1") "s3"
                        ]
                        m
            , describe "persistableWorkCopy (refs.workCopy)"
                [ test "root session (no mapping) → Nothing" <|
                    \_ ->
                        PU.persistableWorkCopy initModelWithSession "s1"
                            |> Expect.equal Nothing
                , test "forked session → the fork dir id" <|
                    \_ ->
                        let
                            m =
                                { initModelWithSession | sessionWorkCopies = Dict.fromList [ ( "s1", "wc-9" ) ] }
                        in
                        PU.persistableWorkCopy m "s1"
                            |> Expect.equal (Just "wc-9")
                , test "resumed session → keeps the existing refs.workCopy (live id is ephemeral, not a dir)" <|
                    \_ ->
                        let
                            m =
                                { initModelWithSession
                                    | sessionWorkCopies = Dict.fromList [ ( "s1", "live-7" ) ]
                                    , sessionResumedLives = Set.fromList [ "live-7" ]
                                    , sessionRefs =
                                        Dict.insert "s1"
                                            (AV.SessionRefs "s1" "v0" [ "v0" ] (Just "wc-9"))
                                            Dict.empty
                                }
                        in
                        PU.persistableWorkCopy m "s1"
                            |> Expect.equal (Just "wc-9")
                , test "resumed session without existing refs → Nothing (root was the work copy)" <|
                    \_ ->
                        let
                            m =
                                { initModelWithSession
                                    | sessionWorkCopies = Dict.fromList [ ( "s1", "live-7" ) ]
                                    , sessionResumedLives = Set.fromList [ "live-7" ]
                                }
                        in
                        PU.persistableWorkCopy m "s1"
                            |> Expect.equal Nothing
                ]
            ]
        ]
