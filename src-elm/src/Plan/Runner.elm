module Plan.Runner exposing
    ( Event(..)
    , step
    , isTerminal
    , nodeBySessionId
    , resumeState
    )

{-| Pure DAG runner state machine for Plan Mode.

    step : Int -> Event -> RunState -> ( RunState, List Effect )

`now` is a millisecond timestamp (from Time.now in the Update layer) so
the machine stays pure. Effects are consumed by App/Update:

  - CreateSessionFor nodeId  → Ports.createSession (serialized: one
    in-flight create at a time; bind via SessionCreatedFor)
  - SendPrompt sid nodeId    → Ports.sendPrompt (node prompt text); emitted
    exactly once when the created session is bound (Starting → Running)
  - CloseSessionFor sid nodeId → Ports.closeSession
  - ScheduleRetry nodeId ms  → Process.sleep then RetryNode
  - PersistRunState          → write <planId>.run.json

Node lifecycle:

    Pending --CreateSessionFor--> Starting --SessionCreatedFor--> Running
      ^                                                           |
      |  ScheduleRetry (Waiting) <---- fail (attempts < max) ----+-- TaskDone ok
      |                                                          V
      +---- RetryNode                                          Succeeded
    Failed (attempts >= max) --> downstream Blocked

Failure sources: SM task task_error, SM error, session disconnect.
TaskDone/SessionError only apply to Running nodes — an idle SM task
frame arriving while Starting (before the prompt is sent) is ignored.
-}

import Dict exposing (Dict)
import Plan.Types as PT


type Event
    = StartRun
    | ContinueRun
    | PauseRun
    | ResumeRun
    | StopRun
    | SessionCreatedFor String String
    | TaskDone String Bool
    | SessionError String String
    | SessionDisconnected String String
    | RetryNode String


step : Int -> Event -> PT.RunState -> ( PT.RunState, List PT.Effect )
step now ev run =
    let
        ( updated, preEffects ) =
            case ev of
                StartRun ->
                    ( startRun now run, [] )

                ContinueRun ->
                    ( continueRun run, [] )

                PauseRun ->
                    if run.status == PT.InProgress then
                        ( { run | status = PT.Paused }, [] )

                    else
                        ( run, [] )

                ResumeRun ->
                    if run.status == PT.Paused then
                        ( { run | status = PT.InProgress }, [] )

                    else
                        ( run, [] )

                StopRun ->
                    ( stopRun run, [] )

                SessionCreatedFor nodeId sid ->
                    -- Sending the node prompt is the direct consequence of
                    -- binding a freshly created session: emit it exactly
                    -- once (bindSession only fires on Starting → Running).
                    bindSession nodeId sid run

                TaskDone sid isError ->
                    ( taskDone now sid isError run, [] )

                SessionError sid text ->
                    ( sessionError now sid text run, [] )

                SessionDisconnected sid reason ->
                    ( sessionDisconnected now sid reason run, [] )

                RetryNode nodeId ->
                    ( retryNode nodeId run, [] )
    in
    let
        ( runFinal, effects ) =
            finishStep now updated
    in
    ( runFinal, preEffects ++ effects )


-- ─── Event handlers ────────────────────────────────────────────────


startRun : Int -> PT.RunState -> PT.RunState
startRun now run =
    if run.status == PT.NotStarted || run.status == PT.Stopped || run.status == PT.FailedRun || run.status == PT.Completed then
        let
            nodes =
                Dict.map
                    (\_ n ->
                        { n
                            | status = PT.Pending
                            , attempts = 0
                            , sessionId = Nothing
                            , failures = []
                            , startedAt = Nothing
                            , finishedAt = Nothing
                        }
                    )
                    run.nodes
        in
        { run | status = PT.InProgress, nodes = nodes, startedAt = Just now, finishedAt = Nothing }

    else
        run


continueRun : PT.RunState -> PT.RunState
continueRun run =
    if run.status == PT.Paused || run.status == PT.NotStarted || run.status == PT.Stopped || run.status == PT.FailedRun || run.status == PT.Completed then
        { run | status = PT.InProgress }

    else
        run


stopRun : PT.RunState -> PT.RunState
stopRun run =
    let
        nodes =
            Dict.map
                (\_ n ->
                    if n.status == PT.Pending || n.status == PT.Starting || n.status == PT.Running || n.status == PT.Waiting then
                        { n | status = PT.Canceled }

                    else
                        n
                )
                run.nodes
    in
    { run | status = PT.Stopped, nodes = nodes }


bindSession : String -> String -> PT.RunState -> ( PT.RunState, List PT.Effect )
bindSession nodeId sid run =
    case Dict.get nodeId run.nodes of
        Just n ->
            if n.status == PT.Starting then
                ( { run | nodes = Dict.insert nodeId { n | status = PT.Running, sessionId = Just sid } run.nodes }
                , [ PT.SendPrompt sid nodeId ]
                )

            else
                ( run, [] )

        Nothing ->
            ( run, [] )


taskDone : Int -> String -> Bool -> PT.RunState -> PT.RunState
taskDone now sid isError run =
    case nodeBySessionId sid run of
        Just nodeId ->
            updateNode nodeId
                (\n ->
                    if n.status == PT.Running then
                        if isError then
                            failNode now "Task failed" n

                        else
                            { n | status = PT.Succeeded, finishedAt = Just now }

                    else
                        n
                )
                run

        Nothing ->
            run


sessionError : Int -> String -> String -> PT.RunState -> PT.RunState
sessionError now sid text run =
    case nodeBySessionId sid run of
        Just nodeId ->
            updateNode nodeId
                (\n ->
                    if n.status == PT.Running then
                        failNode now text n

                    else
                        n
                )
                run

        Nothing ->
            run


sessionDisconnected : Int -> String -> String -> PT.RunState -> PT.RunState
sessionDisconnected now sid reason run =
    case nodeBySessionId sid run of
        Just nodeId ->
            updateNode nodeId
                (\n ->
                    if n.status == PT.Running || n.status == PT.Starting then
                        failNode now ("Session disconnected: " ++ reason) n

                    else
                        n
                )
                run

        Nothing ->
            run


retryNode : String -> PT.RunState -> PT.RunState
retryNode nodeId run =
    let
        run1 =
            updateNode nodeId
                (\n ->
                    case n.status of
                        -- automatic retry tick after backoff: back to the queue
                        PT.Waiting ->
                            { n | status = PT.Pending }

                        -- manual retry: fresh attempt (history kept)
                        PT.Failed ->
                            { n | status = PT.Pending, attempts = 0 }

                        PT.Canceled ->
                            { n | status = PT.Pending, attempts = 0 }

                        _ ->
                            n
                )
                run
    in
    -- Manual retry on a finished run reactivates scheduling for the
    -- retried node (other Canceled nodes stay Canceled).
    if run1.status == PT.FailedRun || run1.status == PT.Completed || run1.status == PT.Stopped then
        { run1 | status = PT.InProgress }

    else
        run1


failNode : Int -> String -> PT.NodeRunState -> PT.NodeRunState
failNode now reason node =
    let
        attempts =
            node.attempts + 1

        failures =
            { attempt = attempts, reason = reason, at = now } :: node.failures
    in
    if attempts < node.maxAttempts then
        -- Waiting: backoff, then RetryNode returns it to Pending
        { node
            | status = PT.Waiting
            , attempts = attempts
            , failures = failures
        }

    else
        { node
            | status = PT.Failed
            , attempts = attempts
            , failures = failures
            , finishedAt = Just now
        }


-- ─── Post-step processing ──────────────────────────────────────────


finishStep : Int -> PT.RunState -> ( PT.RunState, List PT.Effect )
finishStep now run =
    let
        run1 =
            blockedPropagation run

        ( run2, closeEffects ) =
            closeAndClear run1

        run3 =
            updateRunStatus now run2

        ( run4, createEffects ) =
            schedule run3

        retryEffects =
            Dict.foldl
                (\_ n acc ->
                    if n.status == PT.Waiting then
                        PT.ScheduleRetry n.nodeId retryDelayMs :: acc

                    else
                        acc
                )
                []
                run4.nodes
    in
    ( run4
    , closeEffects ++ createEffects ++ retryEffects ++ [ PT.PersistRunState ]
    )


retryDelayMs : Int
retryDelayMs =
    2000


{-| Close sessions of nodes that left Running without success (Waiting /
Failed / Canceled) and drop the session binding so late events are
ignored. Succeeded nodes keep their session (openable from the DAG).
-}
closeAndClear : PT.RunState -> ( PT.RunState, List PT.Effect )
closeAndClear run =
    Dict.foldl
        (\_ n ( r, acc ) ->
            case n.sessionId of
                Just sid ->
                    if n.status == PT.Waiting || n.status == PT.Failed || n.status == PT.Canceled then
                        ( { r | nodes = Dict.insert n.nodeId { n | sessionId = Nothing } r.nodes }
                        , PT.CloseSessionFor sid n.nodeId :: acc
                        )

                    else
                        ( r, acc )

                Nothing ->
                    ( r, acc )
        )
        ( run, [] )
        run.nodes


{-| Launch up to `concurrency - running` Pending nodes whose deps all
succeeded. Marks the launched nodes Starting (so bindSession works) and
returns their CreateSessionFor effects.
-}
schedule : PT.RunState -> ( PT.RunState, List PT.Effect )
schedule run =
    if run.status /= PT.InProgress then
        ( run, [] )

    else
        let
            running =
                Dict.foldl
                    (\_ n acc ->
                        if n.status == PT.Running || n.status == PT.Starting then
                            acc + 1

                        else
                            acc
                    )
                    0
                    run.nodes

            capacity =
                max 0 (run.concurrency - running)

            pendingReady =
                Dict.foldl
                    (\_ n acc ->
                        if n.status == PT.Pending && allDepsSucceeded n.nodeId run then
                            n.nodeId :: acc

                        else
                            acc
                    )
                    []
                    run.nodes
                    |> List.reverse

            chosen =
                List.take capacity pendingReady

            run1 =
                List.foldl
                    (\nodeId r ->
                        updateNode nodeId
                            (\n ->
                                if n.status == PT.Pending then
                                    { n | status = PT.Starting }

                                else
                                    n
                            )
                            r
                    )
                    run
                    chosen
        in
        ( run1, List.map PT.CreateSessionFor chosen )


allDepsSucceeded : String -> PT.RunState -> Bool
allDepsSucceeded nodeId run =
    let
        task =
            List.filter (\t -> t.id == nodeId) run.plan.tasks |> List.head
    in
    case task of
        Just t ->
            List.all
                (\dep ->
                    case Dict.get dep run.nodes of
                        Just n ->
                            n.status == PT.Succeeded

                        Nothing ->
                            False
                )
                t.dependsOn

        Nothing ->
            False


{-| Propagate Blocked: Pending/Waiting nodes with a Failed (terminal) or
Blocked dependency become Blocked. Iterates to a fixpoint (DAG → n passes).
-}
blockedPropagation : PT.RunState -> PT.RunState
blockedPropagation run =
    let
        depMap : Dict String (List String)
        depMap =
            List.foldl
                (\t acc -> Dict.insert t.id t.dependsOn acc)
                Dict.empty
                run.plan.tasks

        n =
            Dict.size run.nodes

        stepOnce nodes =
            Dict.foldl
                (\_ nd acc ->
                    if
                        (nd.status == PT.Pending || nd.status == PT.Waiting)
                            && hasFailedDep depMap nd.nodeId nodes
                    then
                        Dict.insert nd.nodeId { nd | status = PT.Blocked } acc

                    else
                        acc
                )
                nodes
                nodes
    in
    { run | nodes = List.foldl (\_ acc -> stepOnce acc) run.nodes (List.range 1 (max 1 n)) }


hasFailedDep : Dict String (List String) -> String -> Dict String PT.NodeRunState -> Bool
hasFailedDep depMap nodeId nodes =
    Maybe.withDefault []
        (Dict.get nodeId depMap)
        |> List.any
            (\depId ->
                case Dict.get depId nodes of
                    Just dn ->
                        dn.status == PT.Failed || dn.status == PT.Blocked

                    Nothing ->
                        False
            )


updateRunStatus : Int -> PT.RunState -> PT.RunState
updateRunStatus now run =
    if run.status == PT.InProgress then
        let
            statuses =
                Dict.values run.nodes |> List.map .status

            allTerminal =
                List.all (\s -> List.member s [ PT.Succeeded, PT.Failed, PT.Blocked, PT.Canceled ]) statuses

            anyFailed =
                List.any (\s -> s == PT.Failed || s == PT.Blocked) statuses
        in
        if allTerminal then
            { run
                | status = if anyFailed then PT.FailedRun else PT.Completed
                , finishedAt = Just now
            }

        else
            run

    else
        run


-- ─── Helpers ───────────────────────────────────────────────────────


updateNode : String -> (PT.NodeRunState -> PT.NodeRunState) -> PT.RunState -> PT.RunState
updateNode nodeId fn run =
    case Dict.get nodeId run.nodes of
        Just n ->
            { run | nodes = Dict.insert nodeId (fn n) run.nodes }

        Nothing ->
            run


nodeBySessionId : String -> PT.RunState -> Maybe String
nodeBySessionId sid run =
    Dict.foldl
        (\nodeId n acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    if n.sessionId == Just sid then
                        Just nodeId

                    else
                        Nothing
        )
        Nothing
        run.nodes


isTerminal : PT.NodeStatus -> Bool
isTerminal s =
    List.member s [ PT.Succeeded, PT.Failed, PT.Blocked, PT.Canceled ]


{-| Prepare a restored RunState (from run.json) for continuation: nodes
that were mid-flight (Starting/Running/Waiting) go back to Pending and
their stale session bindings are dropped; Succeeded/Failed/Blocked stay.
Then feed `ContinueRun` to relaunch scheduling. v1 semantics: unfinished
nodes re-run from scratch (no subprocess resume).
-}
resumeState : PT.RunState -> PT.RunState
resumeState run =
    let
        nodes =
            Dict.map
                (\_ n ->
                    case n.status of
                        PT.Starting ->
                            { n | status = PT.Pending, sessionId = Nothing }

                        PT.Running ->
                            { n | status = PT.Pending, sessionId = Nothing }

                        PT.Waiting ->
                            { n | status = PT.Pending }

                        _ ->
                            n
                )
                run.nodes

        anyPending =
            List.any (\n -> n.status == PT.Pending) (Dict.values nodes)
    in
    { run
        | nodes = nodes
        , status = if anyPending then PT.InProgress else run.status
    }
