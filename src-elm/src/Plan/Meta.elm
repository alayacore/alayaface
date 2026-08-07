module Plan.Meta exposing
    ( Origin
    , PlanMeta
    , Feedback
    , encodeMeta
    , decodeMeta
    , metaPathFor
    )

{-| Runtime metadata for a plan, stored in
`sessions/<originSessionId>/plans/<planId>/<planId>.meta.json` (P28: a
plan always belongs to the session that created it). The plan document
(`<planId>.json`) stays pure (type/schema/tasks); this file holds the
runtime linkage:

    {
      "origin": { "sessionId": "...", "planIndex": 1 },
      "feedbacks": [ { "at": 172..., "status": "completed", "text": "...", "planId": "..." } ],
      "created_at": 172...
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
- `created_at` — creation timestamp.

The decoder is STRICT: every plan is created by a session, so origin is
required (a meta.json that fails to decode is skipped by the index
rebuild — no lenient/legacy fallbacks).
-}

import Json.Decode as D
import Json.Encode as E


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
    , createdAt : Int
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
        , ( "created_at", E.int m.createdAt )
        ]


decodeMeta : D.Decoder PlanMeta
decodeMeta =
    D.map3 PlanMeta
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
        (D.field "created_at" D.int)
