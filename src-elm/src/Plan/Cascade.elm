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
    , anchorIndexFor
    , findPlanAnchor
    , countUserMessagesAfter
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
                -- C2b: Session.id is stable = plan origin (no lineage/head resolution).
                rootSid =
                    rm.origin.sessionId

                -- P39/D8: the truncation anchor is the plan's CREATION
                -- point — the message right after its plan JSON. A
                -- plan's result always replaces what follows its plan
                -- (never appended past later plans); input is disabled
                -- while a plan runs, so nothing legitimately sits
                -- between the plan and its own result.
                rootIdx =
                    anchorIndexFor rm.origin.planIndex (messagesOf ctx rootSid)

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
                closePlans ctx.planMetas truncSessions chainIds
            }


walkLevels :
    { planMetas : Dict String PM.PlanMeta
    , runs : Dict String (Maybe PT.RunState)
    , sessions : Dict String T.SessionState
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
                -- C2b: Session.id is stable = plan origin (no head/lineage resolution).
                originConv =
                    meta.origin.sessionId

                originHead =
                    originConv
            in
            -- The session where THIS plan's result lives must be open
            -- (feedback + truncation need a live session; under C2b/C3
            -- windows are keyed by Session.id, so look it up directly).
            if NC.liveSessionForOrigin ctx.sessions originHead == Nothing then
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
                                    |> Maybe.map (\m -> m.origin.sessionId)
                                    |> Maybe.withDefault ""

                            parentName =
                                parentMeta |> Maybe.map .name |> Maybe.withDefault parentId

                            parentIdx =
                                -- Same anchor rule as the root: the
                                -- parent's creation point.
                                case parentMeta of
                                    Just pm ->
                                        anchorIndexFor pm.origin.planIndex (messagesOf ctx parentOrigin)

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


closePlans : Dict String PM.PlanMeta -> List String -> List String -> List String
closePlans planMetas truncSessions chainIds =
    -- C2b: Session.id is stable = plan origin — match directly by origin
    -- (no conversation/head resolution).
    Dict.foldl
        (\pid meta acc ->
            if List.member pid chainIds then
                acc

            else if List.member meta.origin.sessionId truncSessions then
                pid :: acc

            else
                acc
        )
        []
        planMetas


messagesOf : { a | sessions : Dict String T.SessionState } -> String -> List T.Message
messagesOf ctx sid =
    -- C2b/C3: sessions are keyed by Session.id — fetch directly.
    Dict.get sid ctx.sessions
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
- `WaitingFork` — a truncating fork is in flight (InstanceReady). The
  fork is the ONLY truncation mechanism (it really rewrites
  session.alaya on disk); if it cannot be issued or fails, the cascade
  ends with a `CascadeError` — there is no in-memory fallback.
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


{-| Effects the machine asks the executor to perform. The executor has
the Model (live sessions, messages, spawn args, fork targets); the
machine only says WHAT to do, with the ids the machine knows.
-}
type Effect
    = ForkInstance String
    -- planId: truncate-fork that plan's parent conversation (the only
    -- truncation mechanism; no fallback if it cannot be issued)
    | InsertResult String String String
    -- planId, instanceId, summary: send the [Plan Result] feedback
    | CascadeError String String
    -- planId, reason: the truncating fork failed or cannot be issued —
    -- surface the error, end the cascade, leave the conversation
    -- untouched (nothing truncated, nothing inserted).
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

                        Err reason ->
                            -- Fork failed: nothing was truncated, no node
                            -- was reset — surface the error and end the
                            -- cascade.
                            ( { cs | phase = Done }, [ CascadeError cs.rootPlanId reason ] )

                _ ->
                    ( cs, [] )


-- ─── Truncation helpers ───────────────────────────────────────────

{-| The plan's CREATION anchor: the index right AFTER its plan JSON
message (the session's `planIndex`-th plan message, 1-based, counted
with the same Plan.Detect predicate as auto-creation). A plan's result
ALWAYS replaces what follows its plan JSON — never appended past later
plans (input is disabled while a plan runs, so nothing can legitimately
sit between the plan and its own result). Nothing when the planIndex is
unknown (<= 0) or out of range (the plan message was truncated away by
an earlier re-run).
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


{-| The truncation/insertion anchor for a plan: its CREATION point
(right after the plan JSON). Nothing when the plan message is unknown
or sits at the very end of the session (nothing follows the plan: plain
append, unchanged).
-}
anchorIndexFor : Int -> List T.Message -> Maybe Int
anchorIndexFor planIndex messages =
    case findPlanAnchor planIndex messages of
        Just idx ->
            if idx >= List.length messages then
                Nothing

            else
                Just idx

        Nothing ->
            Nothing


{-| Number of USER-authored messages after the anchor (the anchor itself
and everything after it will be truncated). 0 when there is no anchor.
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


{-| The alayacore content id to fork AT: the message immediately BEFORE
the plan's anchor — its plan JSON message itself (a fork "up to" that
content id yields a session whose history is exactly the truncated
history: everything through the plan JSON, nothing after it). Nothing
when there is no anchor or the plan message carries no history id —
the executor then surfaces a cascade error (there is no in-memory
fallback: a non-durable truncation would resurrect after a restart).
-}
forkHistoryId : Int -> List T.Message -> Maybe String
forkHistoryId planIndex messages =
    case anchorIndexFor planIndex messages of
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
