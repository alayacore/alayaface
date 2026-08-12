module AppUpdateTest exposing (tests)

import Dict
import Expect
import Plan.Update as PU
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


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
                    -- 多次 fork：workCopies[s1] = s3（最新工作副本）。
                    -- s1 自身的帧（coreId = s1）→ s1；s3 的帧 → s1；
                    -- 中间工作副本 s2 不再被引用（已被删除）。
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
            ]
        ]
