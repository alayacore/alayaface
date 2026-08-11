module Plan.Cascade exposing
    ( ImpactLevel
    , ImpactScope
    , CascadeLevel
    , CascadeState
    , CascadeForkTarget
    , impactScope
    , needsConfirm
    , buildCascadeState
    , findInsertionIndex
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
import Plan.Types as PT
import Plan.Meta as PM
import Session.Meta as SM
import Session.Types as T


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

                rootIdx =
                    findInsertionIndex rootPlanId (messagesOf ctx rootSid)

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
            , closePlanIds = closePlans { planMetas = ctx.planMetas } truncSessions chainIds
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
            -- (feedback + truncation need the live session).
            if not (Dict.member originHead ctx.sessions) then
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
                                findInsertionIndex parentId (messagesOf ctx parentOrigin)

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


closePlans : { planMetas : Dict String PM.PlanMeta } -> List String -> List String -> List String
closePlans ctx truncSessions chainIds =
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
        ctx.planMetas


messagesOf : { a | sessions : Dict String T.SessionState } -> String -> List T.Message
messagesOf ctx sid =
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
its summary changed, `nodeSessionId` is truncated, the node is reset
Succeeded → WaitingForPlan and resumed; once it succeeds, its transitive
downstream in the ancestor re-runs (ResumeBranchFrom); when the ancestor
completes, `oldSummary` gates the propagation upward.
-}
type alias CascadeLevel =
    { planId : String
    , nodeId : String
    , nodeSessionId : String
    , oldSummary : String
    }


type alias CascadeState =
    { rootPlanId : String
    , rootOldSummary : String
    , levels : List CascadeLevel
    }


{-| A fork issued to TRUNCATE a parent session's history (P38): instead
of truncating in memory (which never persists — session.alaya is written
by alayacore), the cascade forks the parent session at the message
before the old `[Plan Result]`. The fork's session.alaya on disk really
only contains the truncated history, so reopening after a restart shows
the correct state. `planId`/`nodeId` = the ancestor node the fork
replaces ("" for a plain origin); `forkSource` = the live session being
forked.
-}
type alias CascadeForkTarget =
    { childPlanId : String
    , summary : String
    , planId : String
    , nodeId : String
    , forkSource : String
    -- The plan's owning session id (dir id): locates the fork's on-disk
    -- dir for the lineage meta write
    -- (sessions/<origin>/plans/<planId>/<nodeId>/<forkId>/ for a plan
    -- node fork; "" for a plain fork, which lives at sessions/<forkId>/).
    , originSessionId : String
    }


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
                                        , nodeSessionId = lvl.nodeSessionId
                                        , oldSummary = feedbackSummary run
                                        }
                                    )

                        Nothing ->
                            Nothing
                )
                scope.levels
    in
    if Dict.get scope.rootPlanId runs == Nothing then
        Nothing

    else
        Just
            { rootPlanId = scope.rootPlanId
            , rootOldSummary = rootOld
            , levels = levels
            }


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
the plan's last `[Plan Result]` insertion. A fork "up to" that content
id yields a session whose history is exactly the truncated history
(everything before the old result). Nothing when there is no insertion
point or the predecessor carries no history id (fall back to the
in-memory truncation).
-}
forkHistoryId : String -> List T.Message -> Maybe String
forkHistoryId planId messages =
    case findInsertionIndex planId messages of
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
