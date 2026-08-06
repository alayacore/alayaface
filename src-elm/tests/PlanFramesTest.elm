module PlanFramesTest exposing (tests)

{-| Unit tests for Plan.Frames.taskEvent — the R5 boot-frame gate.

Regression guard: alayacore emits an SM task frame with
`in_progress:false` at session start (before any prompt). If that boot
frame were treated as a real task completion, the runner would mark the
just-bound node Succeeded and closeAndClear would CANCEL its
just-started session (the "Canceled right after the first prompt" bug,
reproduced on real cores with DeepSeek and LLaMA.CPP alike; fakecore's
old boot frame lacked `in_progress` so E2E never caught it).
-}

import Expect
import Test exposing (Test, describe, test)
import Set exposing (Set)
import Plan.Frames


tests : Test
tests =
    describe "Plan.Frames.taskEvent (boot-frame gate)"
        [ test "boot frame (in_progress:false, never started) is ignored" <|
            \_ ->
                let
                    ( started, ev ) =
                        Plan.Frames.taskEvent Set.empty "s1" False False
                in
                Expect.equal ( Set.empty, Nothing ) ( started, ev )
        , test "task start (in_progress:true) is tracked and emits no event" <|
            \_ ->
                let
                    ( started, ev ) =
                        Plan.Frames.taskEvent Set.empty "s1" True False
                in
                Expect.equal ( Set.singleton "s1", Nothing ) ( started, ev )
        , test "real completion after a start dispatches TaskDone" <|
            \_ ->
                let
                    ( started, ev ) =
                        Plan.Frames.taskEvent (Set.singleton "s1") "s1" False False
                in
                Expect.equal ( Set.singleton "s1", Just ( "s1", False ) ) ( started, ev )
        , test "failed completion (task_error) after a start dispatches TaskDone with the error flag" <|
            \_ ->
                let
                    ( _, ev ) =
                        Plan.Frames.taskEvent (Set.singleton "s1") "s1" False True
                in
                Expect.equal ( Just ( "s1", True ) ) ev
        , test "completion without a prior start is ignored (boot frame after bind)" <|
            \_ ->
                let
                    ( started, ev ) =
                        Plan.Frames.taskEvent Set.empty "s1" False False
                in
                Expect.equal ( Set.empty, Nothing ) ( started, ev )
        , test "the gate is per-session: one session's start does not unlock another" <|
            \_ ->
                let
                    ( _, evA ) =
                        Plan.Frames.taskEvent (Set.singleton "s1") "s2" False False
                in
                Expect.equal Nothing evA
        , test "a session can complete multiple tasks (start → done → start → done)" <|
            \_ ->
                let
                    ( s1, ev1 ) =
                        Plan.Frames.taskEvent Set.empty "s1" True False

                    ( s2, ev2 ) =
                        Plan.Frames.taskEvent s1 "s1" False False

                    ( s3, ev3 ) =
                        Plan.Frames.taskEvent s2 "s1" True False

                    ( _, ev4 ) =
                        Plan.Frames.taskEvent s3 "s1" False False
                in
                Expect.equal ( Nothing, Just ( "s1", False ) ) ( ev1, ev2 )
                    |> Expect.all
                        [ \_ -> Expect.equal Nothing ev3
                        , \_ -> Expect.equal (Just ( "s1", False )) ev4
                        ]
        , test "task-start tracking persists across the completion (set keeps the sid)" <|
            \_ ->
                let
                    ( started, _ ) =
                        Plan.Frames.taskEvent (Set.singleton "s1") "s1" False False
                in
                Expect.equal (Set.singleton "s1") started
        ]
