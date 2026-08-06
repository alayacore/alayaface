module Plan.Runner exposing
    ( Event(..)
    , step
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
import Plan.Inject
import Plan.Types as PT


type Event
    = StartRun
    | ContinueRun
    | PauseRun
    | ResumeRun
    | StopRun
    | SessionCreatedFor String String
    | SessionCreateFailed String String
    | TaskDone String Bool (Maybe String)
    | SessionError String String
    | SessionDisconnected String String
    | RetryNode String
    | RetryTick String
    -- Periodic heartbeat (app-level Time.every): fails nodes whose
    -- startedAt + effective timeout has elapsed (timeout_seconds /
    -- default_timeout_seconds; Nothing = never times out).
    | Tick Int


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

                TaskDone sid isError output ->
                    ( taskDone now sid isError output run, [] )

                -- create_session failed (e.g. invalid node preset): treat
                -- it as a node failure so retry/backoff applies instead
                -- of the node hanging in Starting forever.
                SessionCreateFailed nodeId text ->
                    ( sessionCreateFailed now nodeId text run, [] )

                SessionError sid text ->
                    ( sessionError now sid text run, [] )

                SessionDisconnected sid reason ->
                    ( sessionDisconnected now sid reason run, [] )

                -- Automatic backoff tick (Waiting → Pending only; never
                -- revives Canceled/Failed — a Stop during backoff sticks).
                RetryTick nodeId ->
                    ( retryTick nodeId run, [] )

                -- Manual retry from the node detail panel.
                RetryNode nodeId ->
                    ( retryNode nodeId run, [] )

                -- Periodic heartbeat: fail nodes past their timeout.
                Tick tickNow ->
                    ( checkTimeouts tickNow run, [] )
    in
    let
        ( runFinal, effects ) =
            finishStep now run updated
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
                            , lastSessionId = Nothing
                            , failures = []
                            , startedAt = Nothing
                            , finishedAt = Nothing
                            , output = Nothing
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
                -- Carry the prompt text in the effect so the update layer
                -- never has to re-resolve it from (possibly stale) state.
                -- Downstream {{<id>.output}} templates are resolved HERE
                -- against the outputs of succeeded upstream nodes (a node
                -- is only scheduled once all its deps succeeded, so the
                -- referenced outputs always exist by bind time).
                let
                    promptText =
                        run.plan.tasks
                            |> List.filter (\t -> t.id == nodeId)
                            |> List.head
                            |> Maybe.map (.prompt >> Plan.Inject.injectOutputs (outputsOf run))
                            |> Maybe.withDefault ""

                    attemptSessions =
                        if List.member sid n.attemptSessions then
                            n.attemptSessions

                        else
                            n.attemptSessions ++ [ sid ]
                in
                ( { run | nodes = Dict.insert nodeId { n | status = PT.Running, sessionId = Just sid, lastSessionId = Just sid, attemptSessions = attemptSessions } run.nodes }
                , [ PT.SendPrompt sid promptText ]
                )

            else
                ( run, [] )

        Nothing ->
            ( run, [] )


{-| Recorded outputs of succeeded nodes — the lookup table for
{{<id>.output}} injection. Only succeeded nodes have output.
-}
outputsOf : PT.RunState -> Dict String String
outputsOf run =
    Dict.foldl
        (\_ n acc ->
            case ( n.status, n.output ) of
                ( PT.Succeeded, Just out ) ->
                    Dict.insert n.nodeId out acc

                _ ->
                    acc
        )
        Dict.empty
        run.nodes


taskDone : Int -> String -> Bool -> Maybe String -> PT.RunState -> PT.RunState
taskDone now sid isError output run =
    case nodeBySessionId sid run of
        Just nodeId ->
            updateNode nodeId
                (\n ->
                    if n.status == PT.Running then
                        if isError then
                            failNode now "Task failed" n

                        else
                            { n | status = PT.Succeeded, finishedAt = Just now, output = output }

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


sessionCreateFailed : Int -> String -> String -> PT.RunState -> PT.RunState
sessionCreateFailed now nodeId text run =
    updateNode nodeId
        (\n ->
            if n.status == PT.Starting then
                failNode now ("Session create failed: " ++ text) n

            else
                n
        )
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


{-| Automatic backoff tick: Waiting → Pending only. Unlike manual
RetryNode it does NOT revive Failed/Canceled nodes and does NOT
reactivate a stopped run — so pressing Stop during a retry backoff
stays stopped (the late tick is a no-op).
-}
retryTick : String -> PT.RunState -> PT.RunState
retryTick nodeId run =
    updateNode nodeId
        (\n ->
            case n.status of
                PT.Waiting ->
                    { n | status = PT.Pending }

                _ ->
                    n
        )
        run


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


finishStep : Int -> PT.RunState -> PT.RunState -> ( PT.RunState, List PT.Effect )
finishStep now before run =
    let
        run1 =
            blockedPropagation run

        ( run2, closeEffects ) =
            closeAndClear run1

        run3 =
            updateRunStatus now run2

        ( run4, createEffects ) =
            schedule now run3

        retryEffects =
            -- Schedule the backoff timer only when a node newly entered
            -- Waiting in THIS step (compare against the pre-event state;
            -- re-emitting on every step would stack duplicate timers).
            Dict.foldl
                (\_ n acc ->
                    if n.status == PT.Waiting then
                        let
                            wasWaiting =
                                case Dict.get n.nodeId before.nodes of
                                    Just old ->
                                        old.status == PT.Waiting

                                    Nothing ->
                                        False
                        in
                        if wasWaiting then
                            acc

                        else
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
Failed / Canceled). The subprocess is closed (for Canceled this is what
stops the running task) but the node KEEPS its lastSessionId so the DAG
can reopen the session from disk later (resume_session). Succeeded nodes
keep their live session (openable from the DAG).
-}
closeAndClear : PT.RunState -> ( PT.RunState, List PT.Effect )
closeAndClear run =
    Dict.foldl
        (\_ n ( r, acc ) ->
            case n.sessionId of
                Just sid ->
                    if n.status == PT.Waiting || n.status == PT.Failed || n.status == PT.Canceled then
                        ( { r | nodes = Dict.insert n.nodeId { n | sessionId = Nothing, lastSessionId = Just sid } r.nodes }
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
returns their CreateSessionFor effects. startedAt is set when a node
enters Starting — the timeout clock starts at launch (covers a hanging
create_session as well as a hanging task).
-}
schedule : Int -> PT.RunState -> ( PT.RunState, List PT.Effect )
schedule now run =
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
                                    { n | status = PT.Starting, startedAt = Just now }

                                else
                                    n
                            )
                            r
                    )
                    run
                    chosen
        in
        ( run1, List.map PT.CreateSessionFor chosen )


{-| Fail Starting/Running nodes whose effective timeout has elapsed.
The effective timeout is the node's timeout_seconds, else the plan's
default_timeout_seconds, else no timeout (v1 behavior). A timeout goes
through failNode: it records "Timeout after Ns", closes the session,
and either schedules an auto-retry or marks the node Failed.
-}
checkTimeouts : Int -> PT.RunState -> PT.RunState
checkTimeouts now run =
    Dict.foldl
        (\_ n acc ->
            case ( n.status, n.startedAt ) of
                ( PT.Starting, Just t0 ) ->
                    timeoutNode now t0 n acc

                ( PT.Running, Just t0 ) ->
                    timeoutNode now t0 n acc

                _ ->
                    acc
        )
        run
        run.nodes


timeoutNode : Int -> Int -> PT.NodeRunState -> PT.RunState -> PT.RunState
timeoutNode now startedAt node run =
    let
        task =
            List.filter (\t -> t.id == node.nodeId) run.plan.tasks |> List.head

        timeoutSec =
            task |> Maybe.andThen (\t -> PT.effectiveTimeoutSeconds t run.plan)
    in
    case timeoutSec of
        Just sec ->
            if now - startedAt >= sec * 1000 then
                updateNode node.nodeId
                    (\n -> failNode now ("Timeout after " ++ String.fromInt sec ++ "s") n)
                    run

            else
                run

        Nothing ->
            run


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
