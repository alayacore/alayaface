module PlanCountTest exposing (suite)

{-| M3 (D4) semantics lock: the incremental per-session plan-message
counter (becamePlanMessage + bumpPlanCount + planCountOf) must be
byte-identical to the O(n) planIndexForMessage scan at EVERY step —
under delta-mode streaming, non-delta AT frames, mixed content,
multiple plan messages and replay/restore (same frames on a fresh
session). The update layer's exact bump points are replicated here
(prevContent = historyContents before the frame, AT-with-empty-content
must not double-count).
-}

import Expect
import Test exposing (Test, describe, test)
import Dict
import Session.Types as T
import Session.Handlers as H
import Session.Protocol as P
import Plan.Update as PU
import TestHelpers exposing (initModelWithSession)


type alias Sim =
    { session : T.SessionState
    , counts : Dict.Dict String Int
    }


newSim : Sim
newSim =
    { session = T.emptySession "s1"
    , counts = Dict.empty
    }


{-| Replicate the App/Update DeltaEvent bump point exactly.
-}
stepDelta : String -> String -> String -> Sim -> Sim
stepDelta tag hid content sim =
    let
        prevContent =
            Dict.get (tag ++ ":" ++ hid) sim.session.historyContents
                |> Maybe.withDefault ""

        becamePlan =
            PU.becamePlanMessage prevContent (prevContent ++ content)

        session2 =
            H.handleDeltaEvent sim.session
                { sessionId = "s1", historyId = hid, content = content, tag = tag }
    in
    { session = session2
    , counts = PU.bumpPlanCount sim.counts "s1" becamePlan
    }


{-| Replicate the App/Update FrameEvent bump point exactly.
-}
stepFrame : String -> Maybe String -> Maybe String -> Sim -> Sim
stepFrame tag hid content sim =
    let
        prevAccum =
            hid
                |> Maybe.andThen (\h -> Dict.get (tag ++ ":" ++ h) sim.session.historyContents)
                |> Maybe.withDefault ""

        becamePlan =
            PU.becamePlanMessage prevAccum (Maybe.withDefault "" content)

        session2 =
            H.handleFrameEvent sim.session
                { sessionId = "s1"
                , tag = tag
                , rawValue = ""
                , historyId = hid
                , content = content
                , json = Nothing
                , userContentType = Nothing
                }
    in
    { session = session2
    , counts = PU.bumpPlanCount sim.counts "s1" becamePlan
    }


assertMatchesScan : Sim -> Expect.Expectation
assertMatchesScan sim =
    Expect.equal
        (PU.planCountOf sim.counts "s1")
        (PU.planIndexForMessage sim.session.messages)


planJson : String
planJson =
    """{"type": "alayaface-plan", "name": "x", "concurrency": 1, "tasks": [{"id": "t1", "title": "T1", "prompt": "p"}]}"""


fencedPlan : String
fencedPlan =
    "```json\n" ++ planJson ++ "\n```"


suite : Test
suite =
    describe "Incremental plan counter == planIndexForMessage"
        [ test "non-delta AT with full plan content counts once" <|
            \_ ->
                let
                    s0 =
                        newSim

                    s1 =
                        stepFrame "UT" (Just "h-u") (Just "hello there") s0

                    s2 =
                        stepFrame "AT" (Just "h1") (Just fencedPlan) s1
                in
                Expect.all
                    [ \sim -> assertMatchesScan sim
                    , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") 1
                    ]
                    s2
        , test "delta-mode streaming: fence crossing bumps exactly once, AT empty does not double-count" <|
            \_ ->
                let
                    s0 =
                        newSim

                    -- first delta creates the message with a partial prefix
                    s1 =
                        stepDelta "At" "h1" "```json\n{\"ty" s0

                    s3 =
                        stepDelta "At" "h1" "pe\": \"alayaface-plan\", \"name\": \"x\", \"concurrency\": 1, \"tasks\": [{\"id\":\"t1\",\"title\":\"T1\",\"prompt\":\"p\"}]}\n```" s1

                    s4 =
                        stepFrame "AT" (Just "h1") (Just "") s3
                in
                Expect.all
                    [ \sim -> assertMatchesScan sim
                    , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") 1
                    ]
                    s4
        , test "a partial stream that never closes the fence is not counted" <|
                \_ ->
                    let
                        s0 =
                            newSim

                        s1 =
                            stepDelta "At" "h1" "```json\n{\"type\": \"alayaface-plan\"" s0

                        s2 =
                            stepFrame "AT" (Just "h1") (Just "") s1
                    in
                    Expect.all
                        [ \sim -> assertMatchesScan sim
                        , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") 0
                        ]
                        s2
        , test "multiple plan messages count incrementally" <|
            \_ ->
                let
                    s0 =
                        newSim

                    s1 =
                        stepFrame "AT" (Just "h1") (Just fencedPlan) s0

                    s2 =
                        stepFrame "AT" (Just "h2") (Just "plain answer") s1

                    s3 =
                        stepFrame "AT" (Just "h3") (Just fencedPlan) s2

                    s4 =
                        stepFrame "AR" (Just "h4") (Just "reasoning") s3
                in
                Expect.all
                    [ \sim -> assertMatchesScan sim
                    , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") 2
                    ]
                    s4
        , test "plan text without the fence marker never counts" <|
            \_ ->
                let
                    s0 =
                        newSim

                    s1 =
                        stepFrame "AT" (Just "h1") (Just "```python\nprint(1)\n```") s0

                    s2 =
                        stepFrame "AT" (Just "h2") (Just "no plan here") s1
                in
                Expect.all
                    [ \sim -> assertMatchesScan sim
                    , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") 0
                    ]
                    s2
        , test "replay/restore: the same frames on a fresh session converge" <|
            \_ ->
                let
                    frames =
                        [ stepDelta "At" "h1" "```json\n{\"ty"
                        , stepDelta "At" "h1" "pe\": \"alayaface-plan\", \"name\": \"x\", \"concurrency\": 1, \"tasks\": [{\"id\":\"t1\",\"title\":\"T1\",\"prompt\":\"p\"}]}\n```"
                        , stepFrame "AT" (Just "h1") (Just "")
                        , stepFrame "AT" (Just "h2") (Just "plain")
                        , stepFrame "AT" (Just "h3") (Just fencedPlan)
                        ]

                    run =
                        List.foldl (\f sim -> f sim) newSim frames

                    replay =
                        List.foldl (\f sim -> f sim) newSim frames
                in
                Expect.all
                    [ \sim -> assertMatchesScan sim
                    , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") 2
                    , \sim -> Expect.equal (PU.planCountOf sim.counts "s1") (PU.planCountOf replay.counts "s1")
                    ]
                    run
        ]
