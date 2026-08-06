module PlanRunnerTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Dict exposing (Dict)
import Plan.Runner as R
import Plan.Types as P


planFromJson : String -> P.Plan
planFromJson json =
    case P.parsePlan json of
        Ok p ->
            p

        Err errs ->
            Debug.todo ("bad test plan: " ++ String.join "; " errs)


runFromPlan : P.Plan -> P.RunState
runFromPlan plan =
    P.emptyRunState "run-1" plan


nodeState : String -> P.RunState -> P.NodeRunState
nodeState id run =
    case Dict.get id run.nodes of
        Just n ->
            n

        Nothing ->
            Debug.todo ("missing node " ++ id)


statuses : P.RunState -> Dict String P.NodeStatus
statuses run =
    Dict.map (\_ n -> n.status) run.nodes


effects : List P.Effect -> List String
effects es =
    List.map effectName es


effectName : P.Effect -> String
effectName e =
    case e of
        P.CreateSessionFor id -> "create:" ++ id
        P.SendPrompt sid text -> "prompt:" ++ sid ++ ":" ++ text
        P.CloseSessionFor sid _ -> "close:" ++ sid
        P.ScheduleRetry id _ -> "retry:" ++ id
        P.PersistRunState -> "persist"
        P.Notify _ -> "notify"


-- three parallel tasks, concurrency 2
parallelPlan : P.Plan
parallelPlan =
    planFromJson """{ "name": "x", "concurrency": 2, "tasks": [
      { "id": "a", "title": "A", "prompt": "a" },
      { "id": "b", "title": "B", "prompt": "b" },
      { "id": "c", "title": "C", "prompt": "c" }
    ] }"""


chainPlan : P.Plan
chainPlan =
    planFromJson """{ "name": "x", "concurrency": 2, "tasks": [
      { "id": "a", "title": "A", "prompt": "a" },
      { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
      { "id": "c", "title": "C", "prompt": "c", "depends_on": ["b"] }
    ] }"""


singlePlan : P.Plan
singlePlan =
    planFromJson """{ "name": "x", "tasks": [
      { "id": "a", "title": "A", "prompt": "a" }
    ] }"""


tests : Test
tests =
    describe "Plan.Runner"
        [ describe "start & scheduling"
            [ test "StartRun marks nodes for launch and run InProgress" <|
                \_ ->
                    let
                        ( run, es ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.InProgress run.status
                        , \_ -> Expect.equal (Just P.Starting) (Dict.get "a" (statuses run))
                        , \_ -> Expect.equal (Just P.Starting) (Dict.get "b" (statuses run))
                        , \_ -> Expect.equal (Just P.Pending) (Dict.get "c" (statuses run))
                        , \_ -> Expect.equal 2 (List.length (List.filter (\e -> String.startsWith "create:" (effectName e)) es))
                        ]
                        ()
            , test "start launches up to concurrency" <|
                \_ ->
                    let
                        ( run, es ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal 2 (List.length (List.filter (\e -> String.startsWith "create:" (effectName e)) es))
                        , \r -> Expect.equal P.Starting (nodeState "a" r).status
                        , \r -> Expect.equal P.Starting (nodeState "b" r).status
                        , \r -> Expect.equal P.Pending (nodeState "c" r).status
                        ]
                        run
            , test "starting twice is idempotent (no duplicate creates)" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, es ) =
                            R.step 2000 R.StartRun run1
                    in
                    Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "create:" (effectName e)) es))
                        |> always (Expect.equal P.InProgress run2.status)
            , test "Pending nodes wait for all deps to succeed (chain gating)" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan chainPlan)

                        -- a completes
                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" False) run2
                    in
                    -- after a succeeded, b (Pending) should be launched
                    Expect.all
                        [ \r -> Expect.equal P.Succeeded (nodeState "a" r).status
                        , \r -> Expect.equal P.Starting (nodeState "b" r).status
                        , \r -> Expect.equal P.Pending (nodeState "c" r).status
                        ]
                        run3
            ]
        , describe "prompt dispatch"
            [ test "binding a created session emits exactly one SendPrompt with the node prompt text" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, es ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just P.Running) (Dict.get "a" (statuses run2))
                        , \_ -> Expect.equal (Just "s1") (nodeState "a" run2).sessionId
                        , \_ -> Expect.equal True (List.member "prompt:s1:a" (effects es))
                        , \_ -> Expect.equal 1 (List.length (List.filter (\e -> String.startsWith "prompt:" e) (effects es)))
                        ]
                        ()
            , test "re-binding an already Running node does not re-send" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        -- a late/duplicate SessionCreatedFor (node already
                        -- Running) must not emit a second prompt
                        ( run3, es ) =
                            R.step 3000 (R.SessionCreatedFor "a" "s1") run2
                    in
                    Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "prompt:" e) (effects es)))
                        |> always (Expect.equal (Just "s1") (nodeState "a" run3).sessionId)
            , test "SendPrompt carries the exact plan prompt (parallel plan)" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "concurrency": 3, "tasks": [
                              { "id": "a", "title": "A", "prompt": "do task A now" },
                              { "id": "b", "title": "B", "prompt": "do task B now" }
                            ] }"""

                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan plan)

                        ( run2, es ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (List.member "prompt:s1:do task A now" (effects es))
                        , \_ -> Expect.equal False (List.member "prompt:s1:do task B now" (effects es))
                        ]
                        ()
            , test "full lifecycle: create → bind → prompt → done" <|
                \_ ->
                    let
                        ( run1, es1 ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, es2 ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" False) run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (List.member "create:a" (effects es1))
                        , \_ -> Expect.equal True (List.member "prompt:s1:a" (effects es2))
                        , \r -> Expect.equal P.Succeeded (nodeState "a" r).status
                        ]
                        run3
            ]
        , describe "task completion"
            [ test "TaskDone ok marks node Succeeded and keeps session" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" False) run2
                    in
                    Expect.all
                        [ \r -> Expect.equal P.Succeeded (nodeState "a" r).status
                        , \r -> Expect.equal (Just "s1") (nodeState "a" r).sessionId
                        ]
                        run3
            , test "TaskDone error triggers retry (Waiting + ScheduleRetry)" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, es ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        a =
                            nodeState "a" run3
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Waiting a.status
                        , \_ -> Expect.equal 1 a.attempts
                        , \_ -> Expect.equal 1 (List.length a.failures)
                        , \_ -> Expect.equal 1 (Maybe.withDefault 0 (List.head a.failures |> Maybe.map .attempt))
                        , \_ -> Expect.equal Nothing a.sessionId
                        -- the closed session stays reopenable via lastSessionId
                        , \_ -> Expect.equal (Just "s1") a.lastSessionId
                        , \_ -> Expect.equal True (List.member "close:s1" (effects es))
                        , \_ -> Expect.equal True (List.any (\e -> String.startsWith "retry:a" e) (effects es))
                        ]
                        ()
            , test "retry tick returns node to Pending and relaunches" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        ( run4, es ) =
                            R.step 4000 (R.RetryTick "a") run3
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Starting (nodeState "a" run4).status
                        , \_ -> Expect.equal True (List.member "create:a" (effects es))
                        ]
                        ()
            , test "stop during retry backoff: late tick is a no-op (no revival)" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        -- user presses Stop while the node waits for backoff
                        ( run4, _ ) =
                            R.step 3500 R.StopRun run3

                        -- the scheduled timer fires late: must NOT revive
                        ( run5, es ) =
                            R.step 4000 (R.RetryTick "a") run4
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Canceled (nodeState "a" run5).status
                        , \_ -> Expect.equal P.Stopped run5.status
                        , \_ -> Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "create:" (effectName e)) es))
                        ]
                        ()
            , test "manual RetryNode after stop relaunches only that node" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        ( run4, _ ) =
                            R.step 3500 R.StopRun run3

                        ( run5, es ) =
                            R.step 4000 (R.RetryNode "a") run4
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Starting (nodeState "a" run5).status
                        , \_ -> Expect.equal P.InProgress run5.status
                        , \_ -> Expect.equal True (List.member "create:a" (effects es))
                        -- b was Canceled by Stop and stays Canceled
                        , \_ -> Expect.equal P.Canceled (nodeState "b" run5).status
                        ]
                        ()
            , test "ScheduleRetry is emitted once per Waiting entry (no stacked timers)" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, es1 ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        -- another unrelated event while a stays Waiting must
                        -- NOT schedule a second retry timer
                        ( run4, es2 ) =
                            R.step 3500 R.PauseRun run3
                    in
                    Expect.all
                        [ \_ -> Expect.equal 1 (List.length (List.filter (\e -> String.startsWith "retry:a" e) (effects es1)))
                        , \_ -> Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "retry:a" e) (effects es2)))
                        , \_ -> Expect.equal P.Waiting (nodeState "a" run4).status
                        ]
                        ()
            , test "SessionCreatedFor on a Canceled node does not bind or prompt" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        -- Stop while the create is in flight (node Starting)
                        ( run2, _ ) =
                            R.step 1500 R.StopRun run1

                        ( run3, es ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Canceled (nodeState "a" run3).status
                        , \_ -> Expect.equal Nothing (nodeState "a" run3).sessionId
                        , \_ -> Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "prompt:" e) (effects es)))
                        ]
                        ()
            , test "SessionCreateFailed fails the Starting node (retry, no hang)" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, es ) =
                            R.step 1500 (R.SessionCreateFailed "a" "preset not found") run1

                        a =
                            nodeState "a" run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Waiting a.status
                        , \_ -> Expect.equal 1 a.attempts
                        , \_ -> Expect.equal "Session create failed: preset not found" (Maybe.withDefault "" (List.head a.failures |> Maybe.map .reason))
                        , \_ -> Expect.equal True (List.any (\e -> String.startsWith "retry:a" e) (effects es))
                        , \_ -> Expect.equal Nothing a.sessionId
                        ]
                        ()
            , test "SessionCreateFailed on a non-Starting node is ignored" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan singlePlan)

                        ( run2, _ ) =
                            R.step 1500 R.StopRun run1

                        ( run3, es ) =
                            R.step 2000 (R.SessionCreateFailed "a" "boom") run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Canceled (nodeState "a" run3).status
                        , \_ -> Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "retry:" e) (effects es)))
                        ]
                        ()
            , test "SessionCreateFailed exhausts attempts then Failed" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a", "max_attempts": 1 }
                            ] }"""

                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan plan)

                        ( run2, _ ) =
                            R.step 1500 (R.SessionCreateFailed "a" "bad preset") run1

                        a =
                            nodeState "a" run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Failed a.status
                        , \_ -> Expect.equal P.FailedRun run2.status
                        ]
                        ()
            , test "exhausts max attempts then Failed, downstream Blocked" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a", "max_attempts": 2 },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] }
                            ] }"""

                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan plan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        ( run4, _ ) =
                            R.step 4000 (R.RetryNode "a") run3

                        ( run5, _ ) =
                            R.step 5000 (R.SessionCreatedFor "a" "s2") run4

                        ( run6, _ ) =
                            R.step 6000 (R.TaskDone "s2" True) run5

                        a =
                            nodeState "a" run6

                        b =
                            nodeState "b" run6
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Failed a.status
                        , \_ -> Expect.equal 2 a.attempts
                        , \_ -> Expect.equal 2 (List.length a.failures)
                        , \_ -> Expect.equal P.Blocked b.status
                        , \_ -> Expect.equal P.FailedRun run6.status
                        ]
                        ()
            , test "failed node keeps lastSessionId so the DAG can reopen it" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a", "max_attempts": 1 }
                            ] }"""

                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan plan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        a =
                            nodeState "a" run3
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Failed a.status
                        , \_ -> Expect.equal Nothing a.sessionId
                        -- binding survives closeAndClear for reopening
                        , \_ -> Expect.equal (Just "s1") a.lastSessionId
                        ]
                        ()
            , test "re-run clears lastSessionId (fresh run, fresh bindings)" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a", "max_attempts": 1 }
                            ] }"""

                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan plan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        ( run4, _ ) =
                            R.step 4000 R.StartRun run3

                        a =
                            nodeState "a" run4
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Starting a.status
                        , \_ -> Expect.equal Nothing a.sessionId
                        , \_ -> Expect.equal Nothing a.lastSessionId
                        ]
                        ()
            , test "run completes when all nodes succeed" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.SessionCreatedFor "b" "s2") run2

                        ( run4, _ ) =
                            R.step 4000 (R.TaskDone "s1" False) run3

                        ( run5, _ ) =
                            R.step 5000 (R.TaskDone "s2" False) run4

                        ( run6, _ ) =
                            R.step 6000 (R.SessionCreatedFor "c" "s3") run5

                        ( run7, _ ) =
                            R.step 7000 (R.TaskDone "s3" False) run6
                    in
                    Expect.equal P.Completed run7.status
            ]
        , describe "failure sources"
            [ test "SessionError fails a running node" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.SessionError "s1" "boom") run2

                        a =
                            nodeState "a" run3
                    in
                    Expect.equal P.Waiting a.status
                        |> always
                            (case List.head a.failures of
                                Just f ->
                                    Expect.equal "boom" f.reason

                                Nothing ->
                                    Expect.fail "no failure recorded"
                            )
            , test "SessionDisconnected fails a running node with reason" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.SessionDisconnected "s1" "Connection closed") run2

                        a =
                            nodeState "a" run3
                    in
                    case List.head a.failures of
                        Just f ->
                            Expect.equal "Session disconnected: Connection closed" f.reason

                        Nothing ->
                            Expect.fail "no failure recorded"
            , test "late events after failure are ignored" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        -- a is Waiting now; a late TaskDone must not touch it
                        ( run4, _ ) =
                            R.step 4000 (R.TaskDone "s1" False) run3

                        a =
                            nodeState "a" run4
                    in
                    Expect.equal P.Waiting a.status
            ]
        , describe "stop / pause / resume / manual retry"
            [ test "StopRun cancels active nodes and stops the run" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, es ) =
                            R.step 3000 R.StopRun run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Stopped run3.status
                        , \_ -> Expect.equal P.Canceled (nodeState "a" run3).status
                        , \_ -> Expect.equal P.Canceled (nodeState "c" run3).status
                        , \_ -> Expect.equal True (List.member "close:s1" (effects es))
                        ]
                        ()
            , test "PauseRun stops launching new nodes" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 R.PauseRun run1

                        ( run3, es ) =
                            R.step 3000 (R.SessionCreatedFor "a" "s1") run2
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Paused run3.status
                        , \_ -> Expect.equal 0 (List.length (List.filter (\e -> String.startsWith "create:" (effectName e)) es))
                        ]
                        ()
            , test "ResumeRun continues scheduling" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 R.PauseRun run1

                        ( run3, _ ) =
                            R.step 3000 R.ResumeRun run2

                        ( run4, es ) =
                            R.step 4000 (R.SessionCreatedFor "a" "s1") run3

                        ( run5, es2 ) =
                            R.step 5000 (R.TaskDone "s1" False) run4
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.InProgress run5.status
                        , \_ -> Expect.equal True (List.any (\e -> String.startsWith "create:" e) (effects es2))
                        ]
                        ()
            , test "manual retry resets attempts and failures history kept" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a", "max_attempts": 1 }
                            ] }"""

                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan plan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "a" "s1") run1

                        ( run3, _ ) =
                            R.step 3000 (R.TaskDone "s1" True) run2

                        ( run4, _ ) =
                            R.step 4000 (R.RetryNode "a") run3

                        a =
                            nodeState "a" run4
                    in
                    Expect.all
                        [ \_ -> Expect.equal P.Starting a.status
                        , \_ -> Expect.equal 0 a.attempts
                        , \_ -> Expect.equal 1 (List.length a.failures)
                        ]
                        ()
            , test "nodeBySessionId maps session to node" <|
                \_ ->
                    let
                        ( run1, _ ) =
                            R.step 1000 R.StartRun (runFromPlan parallelPlan)

                        ( run2, _ ) =
                            R.step 2000 (R.SessionCreatedFor "b" "s2") run1
                    in
                    Expect.equal (Just "b") (R.nodeBySessionId "s2" run2)
            ]
        ]
