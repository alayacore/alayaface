module Plan.Meta exposing
    ( Origin
    , PlanMeta
    , Feedback
    , encodeMeta
    , decodeMeta
    , metaPathFor
    , plansOwnedBySession
    , depthOf
    , parentPlanIdOfSession
    , depthForOrigin
    , shouldInjectPlanPrompt
    , shouldAutoRun
    )

{-| Runtime metadata for a plan, stored in
`sessions/<originSessionId>/plans/<planId>/<planId>.meta.json` (P28: a
plan always belongs to the session that created it). The plan document
(`<planId>.json`) stays pure (type/schema/tasks); this file holds the
runtime linkage:

    {
      "origin": { "sessionId": "...", "planIndex": 1 },
      "feedbacks": [ { "at": 172..., "status": "completed", "text": "...", "planId": "..." } ],
      "depth": 2,
      "created_at": 172...,
      "name": "analyze machine parameters",
      "last_status": "completed"
    }

- `origin` — the session's ON-DISK id (resumes get fresh live ids whose
  dirs don't exist; the plan lives under the original dir id) and the
  plan INDEX within that session whose assistant message triggered the
  auto-create. planIndex = which plan message of that session (1-based,
  counted with the same isPlanMessage predicate as the detector). Used
  by feedback (send the plan result back to the origin session), the
  status-bar binding (sessionId + planIndex → planId) and the plan's
  on-disk path, all after restarts.
- `feedbacks` — every completed/stopped run's feedback entry (success:
  the summary text that was sent; failed/stopped runs record nothing to
  the conversation but keep a status entry here so a reopened session
  can render the status bar and the `[Plan: xxx]` link).
- `depth` — the plan's OWN recursion depth counter: 1 for a top-level
  plan (no plan above it), parent.depth + 1 for a sub-plan (its origin
  session is a node session of another plan). Computed once at creation
  and persisted; sessions under a plan check it against the global
  recursion limit (see `shouldInjectPlanPrompt` / `shouldAutoRun`).
- `created_at` — creation timestamp.
- `name` — the plan's display name, snapshotted at creation (see the
  record comment; the status bar renders it without opening the plan).
- `last_status` — last known run status string (PT.runStatusToString),
  rewritten whenever the run status changes; reopened sessions render
  it in the status bar instead of a placeholder.

The decoder is STRICT: every plan is created by a session, so origin is
required (a meta.json that fails to decode is skipped by the index
rebuild — no lenient/legacy fallbacks).
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Plan.Types as PT


type alias Origin =
    { sessionId : String
    , planIndex : Int
    }


type alias Feedback =
    { at : Int
    , status : String
    , text : String
    , planId : String
    }


type alias PlanMeta =
    { origin : Origin
    , feedbacks : List Feedback
    , depth : Int
    , createdAt : Int
    -- The plan's display name, snapshotted at creation (slugified id
    -- loses case/spacing, so the status bar can't recover it from the
    -- planId alone). Persisted so the status bar shows the real name
    -- without opening the plan window / reading plan.json.
    , name : String
    -- Last known run status (PT.runStatusToString). Persisted whenever
    -- the run status changes (runStepIn), so a reopened session's
    -- status bar shows e.g. Completed instead of a placeholder.
    , lastStatus : String
    }


{-| The meta file path for a plan id (same directory as the plan file —
the plan's own dir under its owning session).
-}
metaPathFor : String -> String -> String
metaPathFor planDir planId =
    planDir ++ "/" ++ planId ++ ".meta.json"


encodeMeta : PlanMeta -> E.Value
encodeMeta m =
    E.object
        [ ( "origin"
          , E.object
                [ ( "sessionId", E.string m.origin.sessionId )
                , ( "planIndex", E.int m.origin.planIndex )
                ]
          )
        , ( "feedbacks"
          , E.list
                (\f ->
                    E.object
                        [ ( "at", E.int f.at )
                        , ( "status", E.string f.status )
                        , ( "text", E.string f.text )
                        , ( "planId", E.string f.planId )
                        ]
                )
                m.feedbacks
          )
        , ( "depth", E.int m.depth )
        , ( "created_at", E.int m.createdAt )
        , ( "name", E.string m.name )
        , ( "last_status", E.string m.lastStatus )
        ]


decodeMeta : D.Decoder PlanMeta
decodeMeta =
    D.map6 PlanMeta
        (D.field "origin"
            (D.map2 Origin
                (D.field "sessionId" D.string)
                (D.field "planIndex" D.int)
            )
        )
        (D.field "feedbacks"
            (D.list
                (D.map4 Feedback
                    (D.field "at" D.int)
                    (D.field "status" D.string)
                    (D.field "text" D.string)
                    (D.field "planId" D.string)
                )
            )
        )
        (D.field "depth" D.int)
        (D.field "created_at" D.int)
        (D.field "name" D.string)
        (D.field "last_status" D.string)


{-| Every plan id whose meta `origin` is the given ON-DISK session id.
Used by the cascade close (P34): closing a session window also closes
every plan it owns (stop the run, close its node sessions, close the
plan window) — recursively, since node sessions may own sub-plans.
-}
plansOwnedBySession : Dict String PlanMeta -> String -> List String
plansOwnedBySession metas diskSessionId =
    Dict.foldl
        (\pid meta acc ->
            if meta.origin.sessionId == diskSessionId then
                pid :: acc
            else
                acc
        )
        []
        metas


-- ─── Recursion depth ───────────────────────────────────────────────

{-| A plan's recursion depth: 1 for a top-level plan, parent.depth + 1
for a sub-plan. Persisted in meta.json at creation and rebuilt with the
planMetas index on session open, so it survives restarts. Unknown plans
default to 1 (top-level) — the conservative direction (confirmation
required, prompt injected).
-}
depthOf : Dict String PlanMeta -> String -> Int
depthOf metas planId =
    Dict.get planId metas
        |> Maybe.map .depth
        |> Maybe.withDefault 1


{-| The id of the plan whose run binds the given session as a node.
Run state maps planId → node run states, and each node records its
session's ON-DISK id (sessionId, or lastSessionId once closed) — the
same id a sub-plan's meta origin uses, so resumed sessions match too.
Used only at plan creation, when the parent plan is open (WaitingForPlan
nodes keep their window); a missing parent — impossible in normal flow,
cascade close keeps the chain — falls back to top-level depth.
-}
parentPlanIdOfSession : Dict String (Dict String PT.NodeRunState) -> String -> Maybe String
parentPlanIdOfSession runStates sid =
    Dict.foldl
        (\pid nodes acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    if Dict.toList nodes |> List.any (\( _, n ) -> n.sessionId == Just sid || n.lastSessionId == Just sid) then
                        Just pid

                    else
                        Nothing
        )
        Nothing
        runStates


{-| Depth of a NEW plan whose origin is the given ON-DISK session id:
parent.depth + 1 when that session is a plan node's session, else 1
(top-level).
-}
depthForOrigin : Dict String PlanMeta -> Dict String (Dict String PT.NodeRunState) -> String -> Int
depthForOrigin metas runStates originSid =
    case parentPlanIdOfSession runStates originSid of
        Just parentId ->
            depthOf metas parentId + 1

        Nothing ->
            1


{-| Whether a plan's node sessions get the plan system prompt: only
within the global recursion limit (plan.depth ≤ limit). Over the limit
the prompt is omitted so the model stops delegating — the soft recursion
limit.
-}
shouldInjectPlanPrompt : Int -> Int -> Bool
shouldInjectPlanPrompt depth limit =
    depth <= limit


{-| Whether a plan runs without user confirmation: only sub-plans
(depth > 1) auto-run; the top-level plan is the single user gate.
-}
shouldAutoRun : Int -> Bool
shouldAutoRun depth =
    depth > 1
