module Plan.Cascade exposing
    ( ImpactLevel
    , ImpactScope
    , CascadeLevel
    , CascadeState
    , CascadePhase(..)
    , CascadeForkTarget
    , Event(..)
    , Effect(..)
    , impactScope
    , needsConfirm
    , buildCascadeState
    , cascadeStep
    , findInsertionIndex
    , anchorIndexFor
    , findPlanAnchor
    , countUserMessagesAfter
    , truncateMessagesAt
    , forkHistoryId
    , transitiveSuccessors
    , feedbackSummary
    , insertPrefix
    , bindingInRun
    )

{-| P38 re-run cascade (§7.4): pure helpers for the "truncate parent,
re-insert the new result, propagate upward" flow.

Everything takes explicit inputs (plan metas, run states, sessions) so
the whole cascade is unit-testable without a Model. The ancestry is
walked via the PERSISTED `parentPlanId` in meta.json — closed ancestor
windows (auto-closed on completion, D11) still participate.
-}

import Dict exposing (Dict)
import Plan.Detect
import Plan.Types as PT
import Plan.Meta as PM
import Session.Meta as SM
import Session.Types as T
import App.NodeConnection as NC


-- ─── Impact scope (confirmation display) ───────────────────────────

{-| One ancestor level of the cascade: the plan whose node session is
the child's origin. `nodeSessionId` is where the child's result lives
(truncated + resumed); `truncateSessionId` is this plan's OWN origin
(where its old result lives). `nodeId` / `branchNodes` are filled when
the ancestor's run is open (Nothing / [] when closed — display only).
-}
type alias ImpactLevel =
    { planId : String
    , planName : String
    , nodeId : Maybe String
    , nodeSessionId : String
    , truncateSessionId : String
    , truncateUserMessages : Int
    , branchNodes : List String
    }


type alias ImpactScope =
    { rootPlanId : String
    , rootPlanName : String
    , rootSessionId : String
    , rootHasInsertion : Bool
    , rootUserMessages : Int
    , levels : List ImpactLevel
    , topSessionId : Maybe String
    , closePlanIds : List String
    }


{-| Whether a Run click needs the confirmation dialog: the root already
has an insertion point in its origin session (re-run) or the cascade has
at least one ancestor level. First runs → False (current behavior).
-}
needsConfirm : ImpactScope -> Bool
needsConfirm scope =
    scope.rootHasInsertion || not (List.isEmpty scope.levels)


{-| Walk the ancestry of `rootPlanId` via meta.parentPlanId, nearest
ancestor first. Stops when a session on the path is closed (no
feedback/truncation can happen — D7 record-only) or at a top-level plan
(its origin is a plain session). `closePlanIds` = every plan owned by a
truncation-target session that is not part of the chain (their windows
are closed and their feedback suppressed on confirm).
-}
impactScope :
    { planMetas : Dict String PM.PlanMeta
    , runs : Dict String (Maybe PT.RunState)
    , sessions : Dict String T.SessionState
    , sessionLineage : Dict String SM.SessionMeta
    , planResumedFrom : Dict String String
    }
    -> String
    -> ImpactScope
impactScope ctx rootPlanId =
    case Dict.get rootPlanId ctx.planMetas of
        Nothing ->
            { rootPlanId = rootPlanId
            , rootPlanName = rootPlanId
            , rootSessionId = ""
            , rootHasInsertion = False
            , rootUserMessages = 0
            , levels = []
            , topSessionId = Nothing
            , closePlanIds = []
            }

        Just rm ->
            let
                -- P38: the result lives in the parent conversation, which
                -- may be a fork of the creation origin. P39/Phase B: the
                -- physical session to operate on is the conversation's
                -- HEAD instance (the fork registered itself at adoption);
                -- a pre-lineage root falls back to the conversation id.
                rootSid =
                    headOf ctx rm.origin.sessionId

                -- P39/D8: the truncation anchor is the plan's LAST old
                -- [Plan Result] feedback when it ever completed in this
                -- session; otherwise it falls back to the plan's CREATION
                -- anchor (the message right after its plan JSON) — so a
                -- plan that lives in the MIDDLE of a conversation (other
                -- plans/messages after it) replaces what follows it
                -- instead of appending to the very end.
                rootIdx =
                    anchorIndexFor rm.origin.planIndex rootPlanId (messagesOf ctx rootSid)

                -- P38: the cascade is only needed when the root already
                -- completed (its old result sits in the origin session —
                -- ancestors' delegated nodes are Succeeded and must be
                -- reset + their downstream re-run). A first-time run has
                -- no insertion point: the existing flow already handles
                -- it (nodes are WaitingForPlan, downstream hasn't run).
                ( levels, topSid ) =
                    if rootIdx == Nothing then
                        ( [], Nothing )

                    else
                        walkLevels ctx rootPlanId []

                truncSessions =
                    rootSid :: List.map .truncateSessionId levels

                chainIds =
                    rootPlanId :: List.map .planId levels
            in
            { rootPlanId = rootPlanId
            , rootPlanName = rm.name
            , rootSessionId = rootSid
            , rootHasInsertion = rootIdx /= Nothing
            , rootUserMessages = countUserMessagesAfter rootIdx (messagesOf ctx rootSid)
            , levels = levels
            , topSessionId = topSid
            , closePlanIds =
                closePlans
                    { planMetas = ctx.planMetas, sessionLineage = ctx.sessionLineage }
                    truncSessions
                    chainIds
            }


{-| The conversation's HEAD physical instance (fallback: the
conversation id itself when the registry has no entry — pre-lineage
roots are their own head).
-}
headOf :
    { a | sessionLineage : Dict String SM.SessionMeta }
    -> String
    -> String
headOf ctx conversationId =
    SM.headInstanceFor ctx.sessionLineage conversationId
        |> Maybe.withDefault conversationId


walkLevels :
    { planMetas : Dict String PM.PlanMeta
    , runs : Dict String (Maybe PT.RunState)
    , sessions : Dict String T.SessionState
    , sessionLineage : Dict String SM.SessionMeta
    , planResumedFrom : Dict String String
    }
    -> String
    -> List ImpactLevel
    -> ( List ImpactLevel, Maybe String )
walkLevels ctx planId acc =
    case Dict.get planId ctx.planMetas of
        Nothing ->
            ( acc, Nothing )

        Just meta ->
            let
                -- P39/Phase B: the conversation this plan's result lives
                -- in (stable — the node binding is keyed by it) and the
                -- HEAD physical instance (where truncation + live checks
                -- actually operate).
                originConv =
                    meta.origin.sessionId

                originHead =
                    headOf ctx originConv
            in
            -- The session where THIS plan's result lives must be open
            -- (feedback + truncation need the live session). Resolve
            -- resumes: after a restart the head is shown via a fresh
            -- live id (planResumedFrom live → head).
            if NC.liveSessionForOrigin ctx.sessions ctx.planResumedFrom originHead == Nothing then
                ( acc, Nothing )

            else
                case meta.parentPlanId of
                    Nothing ->
                        -- top-level plan: chain ends at its plain origin
                        ( acc, Just originHead )

                    Just parentId ->
                        let
                            parentRun =
                                Dict.get parentId ctx.runs
                                    |> Maybe.andThen identity

                            ( nodeId, branch ) =
                                case bindingInRun originConv parentRun of
                                    Just ( nid, branchIds ) ->
                                        ( Just nid, branchIds )

                                    Nothing ->
                                        ( Nothing, [] )

                            parentMeta =
                                Dict.get parentId ctx.planMetas

                            parentOrigin =
                                parentMeta
                                    |> Maybe.map (\m -> headOf ctx m.origin.sessionId)
                                    |> Maybe.withDefault ""

                            parentName =
                                parentMeta |> Maybe.map .name |> Maybe.withDefault parentId

                            parentIdx =
                                -- Same anchor rule as the root: the
                                -- parent's old feedback, else its creation
                                -- anchor (a parent that never completed
                                -- still replaces what follows its plan).
                                case parentMeta of
                                    Just pm ->
                                        anchorIndexFor pm.origin.planIndex parentId (messagesOf ctx parentOrigin)

                                    Nothing ->
                                        Nothing

                            level =
                                { planId = parentId
                                , planName = parentName
                                , nodeId = nodeId
                                , nodeSessionId = originConv
                                , truncateSessionId = parentOrigin
                                , truncateUserMessages = countUserMessagesAfter parentIdx (messagesOf ctx parentOrigin)
                                , branchNodes = branch
                                }
                        in
                        walkLevels ctx parentId (acc ++ [ level ])


closePlans : { planMetas : Dict String PM.PlanMeta, sessionLineage : Dict String SM.SessionMeta } -> List String -> List String -> List String
closePlans ctx truncSessions chainIds =
    -- P39/D8: match by CONVERSATION, not physical instance — the
    -- truncation target is the conversation's HEAD instance (a fork
    -- replaced the creation instance), while plan metas record the
    -- creation instance id. A plan whose origin conversation is being
    -- truncated must close even when its meta predates the fork.
    let
        truncConvs =
            List.map (SM.resolveConversation ctx.sessionLineage) truncSessions
    in
    Dict.foldl
        (\pid meta acc ->
            if List.member pid chainIds then
                acc

            else if List.member (SM.resolveConversation ctx.sessionLineage meta.origin.sessionId) truncConvs then
                pid :: acc

            else
                acc
        )
        []
        ctx.planMetas


messagesOf : { a | sessions : Dict String T.SessionState, planResumedFrom : Dict String String } -> String -> List T.Message
messagesOf ctx sid =
    -- Resolve a resumed live id first: after a restart the conversation
    -- head is shown via a FRESH id (planResumedFrom live → on-disk id),
    -- and the messages live under the live id.
    NC.liveSessionForOrigin ctx.sessions ctx.planResumedFrom sid
        |> Maybe.andThen (\liveId -> Dict.get liveId ctx.sessions)
        |> Maybe.map .messages
        |> Maybe.withDefault []


{-| The node (and its transitive downstream branch) in an open run that
binds the given on-disk session id as a node session. Nothing when the
run is closed or no node binds the session.
-}
bindingInRun : String -> Maybe PT.RunState -> Maybe ( String, List String )
bindingInRun sid maybeRun =
    case maybeRun of
        Just run ->
            Dict.foldl
                (\nodeId n acc ->
                    case acc of
                        Just _ ->
                            acc

                        Nothing ->
                            if n.conversationId == Just sid || n.lastSessionId == Just sid then
                                Just ( nodeId, nodeId :: transitiveSuccessors nodeId run.plan.tasks )

                            else
                                Nothing
                )
                Nothing
                run.nodes

        Nothing ->
            Nothing


-- ─── Cascade execution state ───────────────────────────────────────

{-| Execution state for one ancestor level: when the child completes and
its summary changed, the level's delegated node is resumed; once it
succeeds, its transitive downstream in the ancestor re-runs
(ResumeBranchFrom); when the ancestor completes, `oldSummary` gates the
propagation upward. `conversationId` is the node session's STABLE
identity (P39/Phase B — fork instances resolve to it through the
registry; the old physical `nodeSessionId` is gone).
-}
type alias CascadeLevel =
    { planId : String
    , nodeId : String
    , conversationId : String
    , oldSummary : String
    }


{-| Phase of an active re-run cascade:
- `WaitingPlan` — the root (or a head level's branch) is running; its
  completion event decides gate → propagate or end.
- `WaitingFork` — a truncating fork is in flight (InstanceReady), or
  the executor is about to insert in place (InsertInPlace).
- `WaitingNode` — the delegated node was resumed; its answer
  (NodeSucceeded / LevelFailed) decides the branch re-run.
- `BranchRunning` — the head plan's downstream branch is re-running;
  its completion (PlanCompleted) propagates to the next level.
- `Done` — terminal (gate hit, failure, fork error): further events
  are ignored.
-}
type CascadePhase
    = WaitingPlan
    | WaitingFork
    | WaitingNode
    | BranchRunning
    | Done


type alias CascadeState =
    { rootPlanId : String
    , rootOldSummary : String
    , levels : List CascadeLevel
    , phase : CascadePhase
    -- The plan currently being propagated (root, then each level in
    -- turn) and its NEW summary — needed when the fork/insert resolves
    -- to build the [Plan Result] feedback.
    , currentPlanId : String
    , currentSummary : String
    }


{-| Machine events — the ONLY way the cascade state changes. The
executor translates runner/frame events into these (zero ordering
assumptions: the phase guards what applies, D4). `PlanCompleted`
carries the plan's CURRENT feedback summary so the gate (summary
unchanged → silently end) lives inside the machine.
-}
type Event
    = ReRunConfirmed CascadeState
    | PlanCompleted String String
    | NodeSucceeded String String
    | LevelFailed String String
    | InstanceReady (Result String String)
    | InsertInPlace String


{-| Effects the machine asks the executor to perform. The executor has
the Model (live sessions, messages, spawn args, fork targets); the
machine only says WHAT to do, with the ids the machine knows.
-}
type Effect
    = ForkInstance String
    -- planId: truncate-fork that plan's parent conversation (the
    -- executor falls back to InsertInPlace when there is no fork point)
    | InsertResult String String String
    -- planId, instanceId, summary: send the [Plan Result] feedback
    | ResumeNode String String String
    -- planId, nodeId, conversationId: reset Succeeded → WaitingForPlan
    -- and resume the delegated node
    | BranchRerun String String
    -- planId, nodeId: reset the node's transitive downstream branch
    | RegisterFork String
    -- forkId: register the fork's lineage (memory + session.meta.json)
    -- and close the old head instance
    | OpenAncestor String
    -- planId: reopen a closed ancestor window (its run is needed)


{-| Build the execution state from a confirmed scope. Requires every
ancestor's run to be OPEN (they are reopened on confirm before the root
starts) so the delegated node ids are known; old summaries are captured
BEFORE the root run resets any outputs. Nothing when the root run is
missing (should not happen — the Run button lives in its window).
-}
buildCascadeState : ImpactScope -> Dict String (Maybe PT.RunState) -> Maybe CascadeState
buildCascadeState scope runs =
    let
        rootOld =
            Dict.get scope.rootPlanId runs
                |> Maybe.andThen identity
                |> Maybe.map feedbackSummary
                |> Maybe.withDefault ""

        levels =
            List.filterMap
                (\lvl ->
                    case lvl.nodeId of
                        Just nodeId ->
                            Dict.get lvl.planId runs
                                |> Maybe.andThen identity
                                |> Maybe.map
                                    (\run ->
                                        { planId = lvl.planId
                                        , nodeId = nodeId
                                        , conversationId = lvl.nodeSessionId
                                        , oldSummary = feedbackSummary run
                                        }
                                    )

                        Nothing ->
                            Nothing
                )
                scope.levels
    in
    if Dict.get scope.rootPlanId runs == Nothing then
        -- P39/D8: the root may never have run (a FIRST run whose
        -- creation anchor is followed by other messages — the confirm
        -- flow arms the cascade and the completion drives the same
        -- truncate/fork/insert path). Nothing to compare against: the
        -- gate (old summary "") passes on any completion.
        Just
            { rootPlanId = scope.rootPlanId
            , rootOldSummary = ""
            , levels = levels
            , phase = WaitingPlan
            , currentPlanId = scope.rootPlanId
            , currentSummary = ""
            }

    else
        Just
            { rootPlanId = scope.rootPlanId
            , rootOldSummary = rootOld
            , levels = levels
            , phase = WaitingPlan
            , currentPlanId = scope.rootPlanId
            , currentSummary = rootOld
            }


{-| A fork issued to TRUNCATE a parent session's history (P38/P39): the
cascade forks the parent session at the message before the old
`[Plan Result]`, so the fork's session.alaya on disk really only
contains the truncated history. `planId`/`nodeId` = the ancestor node
the fork replaces ("" for a plain origin); `forkSource` = the live
session being forked; `originSessionId` locates the fork's on-disk dir
for the lineage meta write.
-}
type alias CascadeForkTarget =
    { childPlanId : String
    , summary : String
    , planId : String
    , nodeId : String
    , forkSource : String
    , originSessionId : String
    }


-- ─── State machine (P39/Phase C) ───────────────────────────────────

{-| One machine step: pure, one event at a time, no ordering assumptions
(D4 — the executor feeds events as they arrive; the phase guards what
applies; anything else is ignored). Returns the new state and the
effects to perform (which the executor translates with the Model).
-}
cascadeStep : Event -> CascadeState -> ( CascadeState, List Effect )
cascadeStep ev cs =
    case ev of
        ReRunConfirmed cs0 ->
            -- The executor built the state (runs are not available in
            -- the machine); the confirm arms the machine.
            ( { cs0 | phase = WaitingPlan }, [] )

        PlanCompleted planId summary ->
            case cs.phase of
                WaitingPlan ->
                    if planId == cs.rootPlanId then
                        if summary == cs.rootOldSummary then
                            -- gate: nothing changed — silently end.
                            ( { cs | phase = Done }, [] )

                        else
                            ( { cs
                                | phase = WaitingFork
                                , currentPlanId = planId
                                , currentSummary = summary
                              }
                            , [ ForkInstance planId ]
                            )

                    else
                        ( cs, [] )

                BranchRunning ->
                    case List.head cs.levels of
                        Just lvl ->
                            if planId == lvl.planId then
                                if summary == lvl.oldSummary then
                                    ( { cs | phase = Done }, [] )

                                else
                                    ( { cs
                                        | phase = WaitingFork
                                        , levels = List.drop 1 cs.levels
                                        , currentPlanId = planId
                                        , currentSummary = summary
                                      }
                                    , [ ForkInstance planId ]
                                    )

                            else
                                ( cs, [] )

                        Nothing ->
                            ( cs, [] )

                _ ->
                    ( cs, [] )

        NodeSucceeded planId nodeId ->
            case ( cs.phase, List.head cs.levels ) of
                ( WaitingNode, Just lvl ) ->
                    if planId == lvl.planId && nodeId == lvl.nodeId then
                        ( { cs | phase = BranchRunning }
                        , [ BranchRerun planId nodeId ]
                        )

                    else
                        ( cs, [] )

                _ ->
                    ( cs, [] )

        LevelFailed planId nodeId ->
            case ( cs.phase, List.head cs.levels ) of
                ( WaitingNode, Just lvl ) ->
                    if planId == lvl.planId && nodeId == lvl.nodeId then
                        ( { cs | phase = Done }, [] )

                    else
                        ( cs, [] )

                _ ->
                    ( cs, [] )

        InstanceReady result ->
            case cs.phase of
                WaitingFork ->
                    case result of
                        Ok forkId ->
                            let
                                resumeEffects =
                                    case List.head cs.levels of
                                        Just lvl ->
                                            [ ResumeNode lvl.planId lvl.nodeId lvl.conversationId ]

                                        Nothing ->
                                            []
                            in
                            ( { cs | phase = WaitingNode }
                            , RegisterFork forkId
                                :: InsertResult cs.currentPlanId forkId cs.currentSummary
                                :: resumeEffects
                            )

                        Err _ ->
                            -- Fork failed: nothing was truncated, no node
                            -- was reset — end the cascade.
                            ( { cs | phase = Done }, [] )

                _ ->
                    ( cs, [] )

        InsertInPlace instanceId ->
            case cs.phase of
                WaitingFork ->
                    -- No fork point: the executor truncated in memory and
                    -- inserts into the head instance directly.
                    let
                        resumeEffects =
                            case List.head cs.levels of
                                Just lvl ->
                                    [ ResumeNode lvl.planId lvl.nodeId lvl.conversationId ]

                                Nothing ->
                                    []
                    in
                    ( { cs | phase = WaitingNode }
                    , InsertResult cs.currentPlanId instanceId cs.currentSummary :: resumeEffects
                    )

                _ ->
                    ( cs, [] )


-- ─── Truncation helpers ───────────────────────────────────────────

{-| Index of the LAST message that is this plan's old result insertion
(a User message starting with `[Plan Result]` and carrying the plan's
`[Plan: <planId>]` marker). Nothing = first run / no insertion.
-}
findInsertionIndex : String -> List T.Message -> Maybe Int
findInsertionIndex planId messages =
    messages
        |> List.indexedMap (\i m -> ( i, m ))
        |> List.filter
            (\( _, m ) ->
                m.role == T.User
                    && String.startsWith "[Plan Result]" m.content
                    && String.contains ("[Plan: " ++ planId ++ "]") m.content
            )
        |> List.map Tuple.first
        |> List.maximum


{-| The plan's CREATION anchor: the index right AFTER its plan JSON
message (the session's `planIndex`-th plan message, 1-based, counted
with the same Plan.Detect predicate as auto-creation). The anchor is
where a plan that never completed in this session belongs — replacing
what follows it instead of appending to the very end. Nothing when the
planIndex is unknown (<= 0) or out of range (the plan message was
truncated away by an earlier re-run).
-}
findPlanAnchor : Int -> List T.Message -> Maybe Int
findPlanAnchor planIndex messages =
    if planIndex <= 0 then
        Nothing

    else
        messages
            |> List.indexedMap Tuple.pair
            |> List.filter (\( _, m ) -> Plan.Detect.isPlanMessage m.content)
            |> List.drop (planIndex - 1)
            |> List.head
            |> Maybe.map (\( i, _ ) -> i + 1)


{-| The truncation/insertion anchor for a plan: its LAST old
`[Plan Result]` feedback when it ever completed in this session,
otherwise its CREATION anchor (right after the plan JSON). Nothing when
there is neither — or the creation anchor sits at the very end of the
session (nothing follows the plan: plain append, unchanged).

One refinement: when OTHER plan messages sit between the creation
anchor and the old feedback, the feedback was appended PAST them (the
pre-D8 append-to-end bug) — the plan's result must not live behind
later plans, so the creation anchor wins and the plan replaces
everything after its plan JSON.
-}
anchorIndexFor : Int -> String -> List T.Message -> Maybe Int
anchorIndexFor planIndex planId messages =
    case ( findInsertionIndex planId messages, findPlanAnchor planIndex messages ) of
        ( Just i, Just a ) ->
            if a < i && hasPlanMessageBetween a i messages then
                Just a

            else
                Just i

        ( Just i, Nothing ) ->
            Just i

        ( Nothing, Just a ) ->
            if a >= List.length messages then
                Nothing

            else
                Just a

        ( Nothing, Nothing ) ->
            Nothing


{-| Whether any PLAN message (Plan.Detect predicate) sits in
messages[from..to-1] — the sign that an old feedback was appended past
other plans instead of right after its own plan JSON.
-}
hasPlanMessageBetween : Int -> Int -> List T.Message -> Bool
hasPlanMessageBetween from to messages =
    messages
        |> List.drop from
        |> List.take (max 0 (to - from))
        |> List.any (\m -> Plan.Detect.isPlanMessage m.content)


{-| Number of USER-authored messages after the insertion point (the
[Plan Result] message itself and everything after it will be truncated).
0 when there is no insertion point.
-}
countUserMessagesAfter : Maybe Int -> List T.Message -> Int
countUserMessagesAfter maybeIdx messages =
    case maybeIdx of
        Nothing ->
            0

        Just idx ->
            messages
                |> List.drop (idx + 1)
                |> List.filter (\m -> m.role == T.User)
                |> List.length


{-| Truncate a session's messages AT the insertion point (inclusive):
keep everything before the old `[Plan Result]`, drop it and all after.
-}
truncateMessagesAt : Int -> List T.Message -> List T.Message
truncateMessagesAt idx messages =
    List.take idx messages


{-| The alayacore content id to fork AT: the message immediately BEFORE
the plan's anchor — its last `[Plan Result]` insertion (a fork "up to"
that content id yields a session whose history is exactly the truncated
history, everything before the old result) or, for a plan that never
completed, its plan JSON message itself (the fork keeps the plan JSON
and drops everything after it). Nothing when there is no anchor or the
predecessor carries no history id (fall back to the in-memory
truncation).
-}
forkHistoryId : Int -> String -> List T.Message -> Maybe String
forkHistoryId planIndex planId messages =
    case anchorIndexFor planIndex planId messages of
        Just idx ->
            if idx <= 0 then
                Nothing

            else
                messages
                    |> List.drop (idx - 1)
                    |> List.head
                    |> Maybe.andThen .historyId

        Nothing ->
            Nothing


-- ─── Feedback summary / prefix ─────────────────────────────────────

{-| Concatenate every succeeded node's recorded output (the text sent
back to the origin as the plan's result). Used both to build the
feedback prompt and to gate the cascade (old vs new summary).
-}
feedbackSummary : PT.RunState -> String
feedbackSummary run =
    run.plan.tasks
        |> List.filterMap
            (\t ->
                case Dict.get t.id run.nodes of
                    Just n ->
                        if n.status == PT.Succeeded then
                            Maybe.map (\out -> "## " ++ t.id ++ " · " ++ t.title ++ "\n" ++ out) n.output

                        else
                            Nothing

                    Nothing ->
                        Nothing
            )
        |> String.join "\n\n"


{-| The feedback prompt inserted into the origin session. The trailing
`[Plan: <planId>]` marker is the UI link token (viewTextWithPlanLinks
renders it as a clickable "open plan" button) — intentionally at the
END so the model-facing instruction starts clean.
-}
insertPrefix : String -> String -> String
insertPrefix planId summary =
    "[Plan Result] The plan has completed. Results:\n\n"
        ++ summary
        ++ "\n\n[Plan: "
        ++ planId
        ++ "]"


{-| Every task id that (transitively) depends on the given task —
the branch that must re-run when the node's output changes.
-}
transitiveSuccessors : String -> List PT.TaskNode -> List String
transitiveSuccessors rootId tasks =
    let
        directDeps id =
            tasks
                |> List.filter (\t -> List.member id t.dependsOn)
                |> List.map .id

        step frontier visited =
            case frontier of
                [] ->
                    visited

                id :: rest ->
                    if List.member id visited then
                        step rest visited

                    else
                        step (rest ++ directDeps id) (id :: visited)
    in
    step (directDeps rootId) []
