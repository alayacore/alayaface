module Plan.Meta exposing
    ( Origin
    , PlanMeta
    , Feedback
    , encodeMeta
    , decodeMeta
    , metaPathFor
    )

{-| Runtime metadata for a plan, stored in `plans/<planId>.meta.json`
(R-series refactor §2). The plan document (`<planId>.json`) stays pure
(type/schema/tasks); this file holds the runtime linkage:

    {
      "origin": { "sessionId": "...", "messageId": "hist-..." },
      "feedbacks": [ { "at": 172..., "status": "completed", "text": "...", "planId": "..." } ],
      "created_at": 172...
    }

- `origin` — the session (and its plan INDEX within that session) whose
  assistant message triggered the auto-create. Message ids are NOT used
  for matching: they are per-session implementation details (alayacore
  HistoryID) that can differ across cores/restores, while the order of
  plan messages in a session is stable (append-only). planIndex = which
  plan message of that session (1-based, counted with the same
  isPlanMessage predicate as the detector). Used by feedback (send the
  plan result back to the origin session) and by the status-bar binding
  (sessionId + planIndex → planId) after restarts.
- `feedbacks` — every completed/stopped run's feedback entry (success:
  the summary text that was sent; failed/stopped runs record nothing to
  the conversation but keep a status entry here so a reopened session
  can render the status bar and the `[Plan: xxx]` link).
- `created_at` — creation timestamp.

The decoder is lenient (missing origin → Nothing; legacy origin without
planIndex decodes to planIndex -1 — never matches a real message, so old
bindings simply don't render a status bar; feedback routing still works
because it only needs sessionId).
-}

import Json.Decode as D
import Json.Encode as E


type alias Origin =
    { sessionId : String
    , planIndex : Int
    , messageId : Maybe String
    }


type alias Feedback =
    { at : Int
    , status : String
    , text : String
    , planId : String
    }


type alias PlanMeta =
    { origin : Maybe Origin
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
          , case m.origin of
                Just o ->
                    E.object
                        [ ( "sessionId", E.string o.sessionId )
                        , ( "planIndex", E.int o.planIndex )
                        ]

                Nothing ->
                    E.null
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
        (D.oneOf
            [ D.field "origin"
                (D.map3 Origin
                    (D.field "sessionId" D.string)
                    -- Legacy meta files (pre plan-index) have no
                    -- planIndex: decode to -1 so they never match a
                    -- real message (feedback still works via sessionId).
                    (D.oneOf [ D.field "planIndex" D.int, D.succeed -1 ])
                    (D.oneOf
                        [ D.field "messageId" D.string |> D.map Just
                        , D.succeed Nothing
                        ]
                    )
                )
                |> D.map Just
            , D.succeed Nothing
            ]
        )
        (D.oneOf
            [ D.field "feedbacks"
                (D.list
                    (D.map4 Feedback
                        (D.field "at" D.int)
                        (D.field "status" D.string)
                        (D.field "text" D.string)
                        (D.field "planId" D.string)
                    )
                )
            , D.succeed []
            ]
        )
        (D.oneOf [ D.field "created_at" D.int, D.succeed 0 ])
