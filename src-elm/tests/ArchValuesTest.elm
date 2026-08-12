module ArchValuesTest exposing (tests)

import Arch.Values as V
import Dict
import Expect
import Json.Decode as D
import Json.Encode as E
import Session.Types as T
import Test exposing (Test, describe, test)


msg : Int -> T.Message
msg n =
    { id = "m-" ++ String.fromInt n
    , role = if modBy 2 n == 0 then T.User else T.Assistant
    , content = "content " ++ String.fromInt n
    , toolId = Nothing
    , toolName = Nothing
    , isError = False
    , historyId = Just ("h-" ++ String.fromInt n)
    , media = Nothing
    }


withMedia : T.Message -> T.Message
withMedia m =
    { m
        | media =
            Just
                [ { mediaType = T.Image
                  , uri = "file:///tmp/x.png"
                  , name = Just "x.png"
                  }
                ]
    }


tests : Test
tests =
    describe "Arch.Values (C persistent structure)"
        [ describe "chunkMessages"
            [ test "empty list → no blocks" <|
                \_ ->
                    V.chunkMessages []
                        |> Expect.equal []
            , test "exactly blockSize → one block" <|
                \_ ->
                    List.range 1 V.blockSize |> List.map msg
                        |> V.chunkMessages
                        |> List.map (List.length << .messages)
                        |> Expect.equal [ V.blockSize ]
            , test "blockSize + 1 → two blocks (50 + 1)" <|
                \_ ->
                    List.range 1 (V.blockSize + 1) |> List.map msg
                        |> V.chunkMessages
                        |> List.map (List.length << .messages)
                        |> Expect.equal [ V.blockSize, 1 ]
            , test "preserves order across chunks" <|
                \_ ->
                    let
                        msgs =
                            List.range 1 120 |> List.map msg

                        ids =
                            V.chunkMessages msgs
                                |> List.concatMap .messages
                                |> List.map .id
                    in
                    Expect.equal ids (List.map .id msgs)
            ]
        , describe "message roundtrip"
            [ test "plain message" <|
                \_ ->
                    D.decodeString V.decodeMessage (E.encode 2 (V.encodeMessage (msg 3)))
                        |> Expect.equal (Ok (msg 3))
            , test "message with media survives" <|
                \_ ->
                    D.decodeString V.decodeMessage (E.encode 2 (V.encodeMessage (withMedia (msg 4))))
                        |> Expect.equal (Ok (withMedia (msg 4)))
            ]
        , describe "object roundtrips"
            [ test "block" <|
                \_ ->
                    let
                        b =
                            V.Block (List.range 1 5 |> List.map msg)
                    in
                    D.decodeString V.decodeBlock (V.blockContent b)
                        |> Expect.equal (Ok b)
            , test "run summary" <|
                \_ ->
                    let
                        r =
                            V.RunSummary "r1" "completed" 100 (Just 200) "## t1\nout"
                    in
                    D.decodeString V.decodeRunSummary (V.runContent r)
                        |> Expect.equal (Ok r)
            , test "version with plan views + parent" <|
                \_ ->
                    let
                        v =
                            { blocks = [ "b0", "b1" ]
                            , planViews = Dict.fromList [ ( "p1", Just "run-1" ), ( "p2", Nothing ) ]
                            , parent = Just "v0"
                            }
                    in
                    D.decodeString V.decodeVersion (V.versionContent v)
                        |> Expect.equal (Ok v)
            , test "session refs" <|
                \_ ->
                    let
                        s =
                            V.SessionRefs "s1" "v2" [ "v0", "v1", "v2" ] Nothing
                    in
                    D.decodeString V.decodeSessionRefs (V.refsContent s)
                        |> Expect.equal (Ok s)
            , test "session refs round-trips a work copy (C2b)" <|
                \_ ->
                    let
                        s =
                            V.SessionRefs "s1" "v2" [ "v0", "v1" ] (Just "wc-9")
                    in
                    D.decodeString V.decodeSessionRefs (V.refsContent s)
                        |> Expect.equal (Ok s)
            , test "session refs without a workCopy field decode as Nothing (lenient, pre-C2b)" <|
                \_ ->
                    -- 旧文件无 workCopy 字段：根目录即工作副本。
                    D.decodeString V.decodeSessionRefs
                        """{"id":"s1","head":"v2","versions":["v0"]}"""
                        |> Expect.equal (Ok (V.SessionRefs "s1" "v2" [ "v0" ] Nothing))
            ]
        , describe "content determinism"
            [ test "same value encodes identically (hash stability)" <|
                \_ ->
                    let
                        v =
                            { blocks = [ "b0" ]
                            , planViews = Dict.empty
                            , parent = Nothing
                            }
                    in
                    Expect.equal (V.versionContent v) (V.versionContent v)
            ]
        ]
