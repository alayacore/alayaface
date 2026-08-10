module FsRoutingTest exposing (suite)

{-| Regression tests for the tagged fs_list_dir / fs_read_file_text
routing (B3): the plan-meta scan and the normal UI flows share the same
untagged ports, so responses are routed by reqId. Previously a global
flag (planMetaLoading / planMetaReading) decided the route and a user
listing/read racing the scan was swallowed by the scan branch (stuck
file picker, lost plan open) — and the picker listing could be parsed
as plan dirs, corrupting the scan itself.
-}

import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import App.Update
import App.Types as AT
import Dict
import TestHelpers exposing (initModelWithSession)


listDirResult : String -> Bool -> List ( String, Bool ) -> String -> E.Value
listDirResult reqId ok entries error =
    E.object
        [ ( "reqId", E.string reqId )
        , ( "ok", E.bool ok )
        , ( "entries"
          , E.list
                (\( n, d ) -> E.object [ ( "name", E.string n ), ( "isDir", E.bool d ) ])
                entries
          )
        , ( "error", E.string error )
        ]


readResult : String -> Bool -> String -> String -> E.Value
readResult reqId ok content error =
    E.object
        [ ( "reqId", E.string reqId )
        , ( "ok", E.bool ok )
        , ( "content", E.string content )
        , ( "error", E.string error )
        ]


pickerEntries : AT.Model -> List String
pickerEntries model =
    case Dict.get "s1" model.sessions of
        Just s ->
            List.map .name s.filePicker.entries

        Nothing ->
            []


pickerLoading : AT.Model -> Bool
pickerLoading model =
    case Dict.get "s1" model.sessions of
        Just s ->
            s.filePicker.loading

        Nothing ->
            False


pickerError : AT.Model -> Maybe String
pickerError model =
    case Dict.get "s1" model.sessions of
        Just s ->
            s.filePicker.error

        Nothing ->
            Nothing


-- A scan mid-flight: sessions/ listed, one plans/ dir queued, one
-- listing in flight with reqId "fs-1" (the counter already advanced
-- past 1, so the next allocation is "fs-2").
scanInFlight : AT.Model
scanInFlight =
    { initModelWithSession
        | planMetaLoading = True
        , planMetaScanReqId = Just "fs-1"
        , planMetaDirListing = Just "/home/u/.alayaface/sessions/s1/plans"
        , planMetaDirQueue = [ "/home/u/.alayaface/sessions/s2/plans" ]
        , fsReqCounter = 1
    }


suite : Test
suite =
    describe "fs port reqId routing"
        [ test "scan listing is routed to the scan by reqId match" <|
            \_ ->
                let
                    raw =
                        listDirResult "fs-1" True [ ( "plan-a-1", True ) ] ""

                    ( updated, _ ) =
                        App.Update.update (AT.FsListDirResult raw) scanInFlight
                in
                -- The scan consumed the listing and queued the next dir
                -- (its in-flight reqId is now the freshly allocated one).
                Expect.equal
                    ( updated.planMetaDirListing, updated.planMetaScanReqId, updated.planMetaLoading )
                    ( Just "/home/u/.alayaface/sessions/s2/plans", Just "fs-2", True )
        , test "a picker listing racing the scan is NOT swallowed by it" <|
            \_ ->
                let
                    -- A picker listing (different reqId) arrives while
                    -- the scan's listing is in flight.
                    raw =
                        listDirResult "fs-99" True [ ( "Documents", False ), ( "work", True ) ] ""

                    ( updated, _ ) =
                        App.Update.update (AT.FsListDirResult raw) scanInFlight
                in
                -- The picker got its entries AND the scan state is
                -- untouched (no corruption).
                Expect.all
                    [ \m -> Expect.equal (pickerEntries m) [ "Documents", "work" ]
                    , \m -> Expect.equal ( m.planMetaDirListing, m.planMetaScanReqId )
                            ( Just "/home/u/.alayaface/sessions/s1/plans", Just "fs-1" )
                    ]
                    updated
        , test "failed picker listing surfaces the error instead of hanging" <|
            \_ ->
                let
                    model =
                        initModelWithSession

                    raw =
                        listDirResult "fs-1" False [] "backend exploded"

                    ( updated, _ ) =
                        App.Update.update (AT.FsListDirResult raw) model
                in
                Expect.equal ( pickerLoading updated, pickerError updated )
                    ( False, Just "backend exploded" )
        , test "meta read is routed to the meta chain by reqId match" <|
            \_ ->
                let
                    model =
                        { initModelWithSession
                            | planMetaReadReqId = Just "fs-3"
                            , planMetaReading = Just "/home/u/.alayaface/sessions/s1/plans/plan-a/plan-a.meta.json"
                        }

                    metaJson =
                        "{\"origin\":{\"sessionId\":\"s1\",\"planIndex\":1},\"feedbacks\":[],\"depth\":1,\"created_at\":123,\"name\":\"Demo\",\"last_status\":\"not_started\"}"

                    raw =
                        readResult "fs-3" True metaJson ""

                    ( updated, _ ) =
                        App.Update.update (AT.FsReadResult raw) model
                in
                Expect.equal
                    ( Dict.keys updated.planMetas, updated.planMetaReadReqId )
                    ( [ "plan-a" ], Nothing )
        , test "a plan open during the meta scan is not swallowed by it" <|
            \_ ->
                -- The exact B3 scenario: the scan's meta read is in
                -- flight AND the user opens a plan file; the read result
                -- must reach the plan-open flow, not the meta chain.
                let
                    model =
                        { initModelWithSession
                            | planMetaReadReqId = Just "fs-3"
                            , planMetaReading = Just "/home/u/.alayaface/sessions/s1/plans/plan-a/plan-a.meta.json"
                            , planReadTarget =
                                Just
                                    { reqId = "fs-9"
                                    , planId = "plan-b"
                                    , path = "/home/u/.alayaface/sessions/s1/plans/plan-b/plan-b.json"
                                    , isResume = False
                                    , continueRun = False
                                    }
                        }

                    planJson =
                        "{\"type\":\"alayaface-plan\",\"schema_version\":1,\"name\":\"Demo\",\"goal\":\"\",\"concurrency\":2,\"default_max_attempts\":2,\"tasks\":[{\"id\":\"t1\",\"title\":\"T1\",\"prompt\":\"Do x\",\"depends_on\":[],\"max_attempts\":2}]}"

                    raw =
                        readResult "fs-9" True planJson ""

                    ( updated, _ ) =
                        App.Update.update (AT.FsReadResult raw) model
                in
                -- The plan window opened (keyed by target.planId) while
                -- the scan's meta read is still tracked (its result will
                -- arrive later with reqId fs-3).
                Expect.all
                    [ \m -> Expect.equal (Dict.member "plan-b" m.planWindows) True
                    , \m -> Expect.equal m.planMetaReadReqId (Just "fs-3")
                    ]
                    updated
        , test "a stale read result (no matching target) is ignored" <|
            \_ ->
                let
                    model =
                        { initModelWithSession
                            | planReadTarget =
                                Just
                                    { reqId = "fs-7"
                                    , planId = "plan-c"
                                    , path = "/x/plan-c.json"
                                    , isResume = False
                                    , continueRun = False
                                    }
                        }

                    raw =
                        readResult "fs-8" True "{}" ""

                    ( updated, _ ) =
                        App.Update.update (AT.FsReadResult raw) model
                in
                -- Nothing consumed the target; a later fs-7 response will.
                Expect.equal updated.planReadTarget model.planReadTarget
        , test "failed home dir surfaces the error and releases the picker" <|
            \_ ->
                let
                    raw =
                        E.object
                            [ ( "ok", E.bool False )
                            , ( "home", E.string "" )
                            , ( "error", E.string "Cannot determine home directory" )
                            ]

                    ( updated, _ ) =
                        App.Update.update (AT.FsHomeDirResult raw) initModelWithSession
                in
                Expect.all
                    [ \m -> Expect.equal m.homeDir ""
                    , \m -> Expect.equal (pickerLoading m) False
                    , \m -> Expect.equal (pickerError m) (Just "Cannot determine home directory")
                    , \m -> Expect.equal m.sessionManagerError (Just "Cannot determine home directory")
                    ]
                    updated
        ]
