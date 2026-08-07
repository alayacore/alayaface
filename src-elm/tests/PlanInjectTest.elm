module PlanInjectTest exposing (tests)

import Dict exposing (Dict)
import Expect
import Plan.Inject exposing (injectOutputs)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Plan.Inject"
        [ test "replaces a single reference" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "t1", "100 units" ) ]) "sold {{t1.output}} today"
                    |> Expect.equal "sold 100 units today"
        , test "replaces multiple references" <|
            \_ ->
                injectOutputs
                    (Dict.fromList [ ( "t1", "A" ), ( "t2", "B" ) ])
                    "{{t1.output}} + {{t2.output}}"
                    |> Expect.equal "A + B"
        , test "replaces the same reference twice" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "t1", "X" ) ]) "{{t1.output}} and {{t1.output}}"
                    |> Expect.equal "X and X"
        , test "adjacent templates" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "a", "1" ), ( "b", "2" ) ]) "{{a.output}}{{b.output}}"
                    |> Expect.equal "12"
        , test "unknown id becomes a marker, no raw template leaks" <|
            \_ ->
                let
                    out =
                        injectOutputs Dict.empty "see {{t9.output}} here"
                in
                Expect.all
                    [ \s -> Expect.equal False (String.contains "{{" s)
                    , \s -> Expect.equal True (String.contains "t9" s)
                    , \s -> Expect.equal True (String.contains "no output recorded for upstream task" s)
                    ]
                    out
        , test "known id without output becomes a marker" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "t1", "" ) ]) "{{t1.output}}"
                    |> Expect.equal "(no output recorded for upstream task t1)"
        , test "no template: text unchanged" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "t1", "X" ) ]) "plain prompt"
                    |> Expect.equal "plain prompt"
        , test "literal braces without .output are preserved" <|
            \_ ->
                injectOutputs Dict.empty "use { { braces } } and {{nope}}"
                    |> Expect.equal "use { { braces } } and {{nope}}"
        , test "id may contain digits dashes underscores" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "node-2_x", "v" ) ]) "{{node-2_x.output}}"
                    |> Expect.equal "v"
        , test "template inside larger word-like text" <|
            \_ ->
                injectOutputs (Dict.fromList [ ( "t1", "OUT" ) ]) "pre{{t1.output}}post"
                    |> Expect.equal "preOUTpost"
        ]
