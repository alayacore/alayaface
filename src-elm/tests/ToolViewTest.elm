module ToolViewTest exposing (tests)

import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)
import Session.ToolView as TV exposing (DiffLine(..))


tests : Test
tests =
    describe "Session.ToolView"
        [ describe "diffBlocks (edit_file block replacement)"
            [ test "identical text is all context lines" <|
                \_ ->
                    TV.diffBlocks "a\nb\nc" "a\nb\nc"
                        |> Expect.equal [ Context "a", Context "b", Context "c" ]
            , test "single-line change keeps common prefix and suffix as context" <|
                \_ ->
                    TV.diffBlocks "alpha\nOLD\nomega" "alpha\nNEW\nomega"
                        |> Expect.equal
                            [ Context "alpha"
                            , Deleted "OLD"
                            , Added "NEW"
                            , Context "omega"
                            ]
            , test "complete rewrite is deletions followed by additions" <|
                \_ ->
                    TV.diffBlocks "one\ntwo" "three\nfour"
                        |> Expect.equal [ Deleted "one", Deleted "two", Added "three", Added "four" ]
            , test "pure insertion has no deletion lines" <|
                \_ ->
                    TV.diffBlocks "" "hello\nworld"
                        |> Expect.equal [ Added "hello", Added "world" ]
            , test "pure deletion has no addition lines" <|
                \_ ->
                    TV.diffBlocks "hello\nworld" ""
                        |> Expect.equal [ Deleted "hello", Deleted "world" ]
            , test "inserted middle line is one addition between context" <|
                \_ ->
                    TV.diffBlocks "a\nb\nc" "a\nb\nb\nc"
                        |> Expect.equal [ Context "a", Context "b", Added "b", Context "c" ]
            , test "empty strings produce an empty diff" <|
                \_ ->
                    TV.diffBlocks "" ""
                        |> Expect.equal []
            ]
        , describe "editFileDecoder"
            [ test "decodes path, old_string and new_string" <|
                \_ ->
                    E.object
                        [ ( "path", E.string "src/Main.elm" )
                        , ( "old_string", E.string "old text" )
                        , ( "new_string", E.string "new text" )
                        ]
                        |> D.decodeValue TV.editFileDecoder
                        |> Result.map .oldString
                        |> Expect.equal (Ok "old text")
            , test "fails when a required field is missing" <|
                \_ ->
                    E.object [ ( "path", E.string "x" ) ]
                        |> D.decodeValue TV.editFileDecoder
                        |> Expect.err
            ]
        ]
