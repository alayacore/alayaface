module ArchFreezeTest exposing (tests)

import Arch.Freeze as F
import Arch.Values as AV
import Dict
import Expect
import Session.Types as T
import Test exposing (Test, describe, test)


msg : Int -> T.Message
msg n =
    { id = "m-" ++ String.fromInt n
    , role = T.User
    , content = "c" ++ String.fromInt n
    , toolId = Nothing
    , toolName = Nothing
    , isError = False
    , historyId = Just ("h-" ++ String.fromInt n)
    , media = Nothing
    }


run : String -> AV.RunSummary
run pid =
    AV.RunSummary ("r-" ++ pid) "completed" 1 (Just 2) ("## " ++ pid)


tests : Test
tests =
    describe "Arch.Freeze (C version freeze state machine)"
        [ test "begin chunks messages and pre-allocates reqIds (blocks 0..n-1, runs n..)" <|
            \_ ->
                let
                    st =
                        F.begin "s1" (List.range 1 55 |> List.map msg)
                            [ ( "p1", run "p1" ) ]
                            [ "p2" ]
                            (Just "v0")
                            Nothing

                    puts =
                        F.initialPuts st
                in
                Expect.all
                    [ \_ -> Expect.equal (List.length puts) 3
                    , \_ -> Expect.equal (List.map Tuple.first puts) [ 0, 1, 2 ]
                    , \_ -> Expect.equal (F.versionReq st) 3
                    ]
                    ()
        , test "onPutResult collects block + run hashes; buildVersion assembles complete planViews" <|
            \_ ->
                let
                    st0 =
                        F.begin "s1" [ msg 1 ]
                            [ ( "p1", run "p1" ) ]
                            [ "p2" ]
                            Nothing
                            Nothing

                    -- block (reqId 0) + run (reqId 1) ready
                    st1 =
                        F.onPutResult 0 (Just "block-hash") st0

                    st2 =
                        F.onPutResult 1 (Just "run-hash") st1

                    version =
                        F.buildVersion st2
                in
                case version of
                    Just v ->
                        Expect.all
                            [ \vv -> Expect.equal vv.blocks [ "block-hash" ]
                            , \vv -> Expect.equal (Dict.get "p1" vv.planViews) (Just (Just "run-hash"))
                            , \vv -> Expect.equal (Dict.get "p2" vv.planViews) (Just Nothing)
                            , \vv -> Expect.equal vv.parent Nothing
                            ]
                            v

                    Nothing ->
                        Expect.fail "buildVersion must succeed once blocks+run are ready"
        , test "buildVersion stays Nothing until every block and run is in" <|
            \_ ->
                let
                    st =
                        F.begin "s1" (List.range 1 51 |> List.map msg)
                            [ ( "p1", run "p1" ) ]
                            []
                            Nothing
                            Nothing
                in
                Expect.equal (F.buildVersion st) Nothing
        , test "version put completes the freeze and exposes runSummaries" <|
            \_ ->
                let
                    st0 =
                        F.begin "s1" [ msg 1 ]
                            [ ( "p1", run "p1" ) ]
                            []
                            Nothing
                            Nothing

                    st1 =
                        F.onPutResult 0 (Just "b0") st0

                    st2 =
                        F.onPutResult 1 (Just "run-1") st1

                    st3 =
                        F.onPutResult (F.versionReq st2) (Just "v-1") st2

                    summaries =
                        F.runSummaries st2
                in
                Expect.all
                    [ \_ -> Expect.equal (F.isComplete st3) True
                    , \_ -> Expect.equal (F.isComplete st2) False
                    , \_ -> Expect.equal (Dict.get "run-1" summaries) (Just (run "p1"))
                    ]
                    ()
        , test "unexecuted plans appear as Nothing in planViews" <|
            \_ ->
                let
                    st0 =
                        F.begin "s1" [ msg 1 ] [] [ "a", "b" ] Nothing Nothing

                    st1 =
                        F.onPutResult 0 (Just "b0") st0
                in
                case F.buildVersion st1 of
                    Just v ->
                        Expect.all
                            [ \vv -> Expect.equal (Dict.get "a" vv.planViews) (Just Nothing)
                            , \vv -> Expect.equal (Dict.get "b" vv.planViews) (Just Nothing)
                            ]
                            v

                    Nothing ->
                        Expect.fail "blocks ready + no runs must build"
        ]
