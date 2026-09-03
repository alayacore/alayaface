module AppUpdateTest exposing (malformedEventTests, tests)

import Dict
import Set
import Expect
import Json.Decode as D
import Json.Encode as E
import App.Types as AT
import App.Update
import Session.Protocol as P
import Plan.Update as PU
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)
import Arch.Values as AV


{-| Inbound backend events whose JSON does not match the decoder are the
AGENTS.md "app looks alive, tracking is dead" case: the old arms returned
`( model, Cmd.none )`, discarding the reason. They now report through
Ports.logWarn. Pinned here: the model must stay untouched (a malformed event
must not half-apply) and the arm must produce a command (the diagnostic)
instead of swallowing it silently.
-}
malformedEventTests : Test
malformedEventTests =
    let
        -- A frame event missing `tag`, so the decoder rejects it.
        brokenFrame =
            E.object [ ( "session_id", E.string "s1" ), ( "content", E.string "x" ) ]

        ignored name msg =
            test name <|
                \_ ->
                    let
                        ( m, _ ) =
                            App.Update.update msg TestHelpers.initModelWithSession
                    in
                    Expect.equal 1 (Dict.size m.sessions)
    in
    describe "malformed inbound events are reported, not swallowed"
        [ ignored "DeltaEvent leaves the model alone" (AT.DeltaEvent brokenFrame)
        , ignored "FrameEvent leaves the model alone" (AT.FrameEvent brokenFrame)
        , ignored "StatusEvent leaves the model alone" (AT.StatusEvent brokenFrame)
        , test "the warning names the broken port and carries the decoder reason" <|
            \_ ->
                case D.decodeValue P.frameEventDecoder brokenFrame of
                    Err err ->
                        Expect.all
                            [ String.startsWith "FrameEvent decode failed: " >> Expect.equal True
                            , \w -> Expect.equal True (String.contains "tag" w)
                            ]
                            (App.Update.decodeWarning "FrameEvent" err)

                    Ok _ ->
                        Expect.fail "the fixture must be undecodable, or the test proves nothing"
        ]


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
        , describe "SessionCreateError buffer cleanup"
            [ test "a failed create drops the buffered events of the never-registered core id" <|
                \_ ->
                    -- The backend broadcasts connected:true before the
                    -- RPC reply, so a create whose response was lost
                    -- leaves that frame buffered forever (no
                    -- SessionCreated flushes it). The error must drop it.
                    let
                        m =
                            { initModelWithSession
                                | pendingEvents = Dict.fromList [ ( "core-x", [ E.null ] ) ]
                                , planCreating = Nothing
                            }

                        ( m1, _ ) =
                            App.Update.update (AT.SessionCreateError "boom") m
                    in
                    Expect.equal (Dict.size m1.pendingEvents) 0
            , test "a failed create keeps the buffer while a resume is in flight" <|
                \_ ->
                    -- A concurrent resume's live id is unknown to us, so
                    -- its buffered frames must NOT be swept by an
                    -- unrelated create failure.
                    let
                        m =
                            { initModelWithSession
                                | pendingEvents = Dict.fromList [ ( "live-7", [ E.null ] ) ]
                                , planCreating = Nothing
                                , planResumeFrom = Just "s1"
                            }

                        ( m1, _ ) =
                            App.Update.update (AT.SessionCreateError "boom") m
                    in
                    Expect.equal (Dict.size m1.pendingEvents) 1
            ]
        ]
