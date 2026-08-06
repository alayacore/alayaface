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

- `origin` — the session (and its message id) whose assistant message
  triggered the auto-create. Used by feedback (send the plan result back
  to the origin session) and by the status-bar binding (messageId →
  planId) after restarts.
- `feedbacks` — every completed/stopped run's feedback entry (success:
  the summary text that was sent; failed/stopped runs record nothing to
  the conversation but keep a status entry here so a reopened session
  can render the status bar and the `[Plan: xxx]` link).
- `created_at` — creation timestamp.

The decoder is lenient (missing origin → Nothing) so meta files from
before the R-series still open.
-}

import Json.Decode as D
import Json.Encode as E


type alias Origin =
    { sessionId : String
    , messageId : String
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


{-| The meta file path for a plan id (same directory as the plan file).
-}
metaPathFor : String -> String -> String
metaPathFor plansDir planId =
    plansDir ++ "/" ++ planId ++ ".meta.json"


encodeMeta : PlanMeta -> E.Value
encodeMeta m =
    E.object
        [ ( "origin"
          , case m.origin of
                Just o ->
                    E.object
                        [ ( "sessionId", E.string o.sessionId )
                        , ( "messageId", E.string o.messageId )
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
                (D.map2 Origin
                    (D.field "sessionId" D.string)
                    (D.field "messageId" D.string)
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
