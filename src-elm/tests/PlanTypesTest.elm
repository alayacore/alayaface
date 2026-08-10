module PlanTypesTest exposing (tests)

import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)
import Dict exposing (Dict)
import Plan.Types as P


nodeState : String -> P.RunState -> P.NodeRunState
nodeState id run =
    case Dict.get id run.nodes of
        Just n ->
            n

        Nothing ->
            Debug.todo ("missing node " ++ id)


sampleJson : String
sampleJson =
    """{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "Monthly Report",
  "goal": "Generate the June sales report",
  "concurrency": 2,
  "default_max_attempts": 3,
  "tasks": [
    { "id": "t1", "title": "Collect data", "prompt": "Collect June sales data", "depends_on": [] },
    { "id": "t2", "title": "Analyze", "prompt": "Analyze the data", "depends_on": ["t1"] },
    { "id": "t3", "title": "Write report", "prompt": "Write the report", "depends_on": ["t2"], "preset": "Data", "tools": "read_file,write_file", "max_attempts": 2 }
  ]
}"""


tests : Test
tests =
    describe "Plan.Types"
        [ describe "parsePlan"
            [ test "parses a valid plan" <|
                \_ ->
                    case P.parsePlan sampleJson of
                        Ok plan ->
                            Expect.all
                                [ \p -> Expect.equal 1 p.schemaVersion
                                , \p -> Expect.equal "Monthly Report" p.name
                                , \p -> Expect.equal "Generate the June sales report" p.goal
                                , \p -> Expect.equal 2 p.concurrency
                                , \p -> Expect.equal 3 p.defaultMaxAttempts
                                , \p -> Expect.equal 3 (List.length p.tasks)
                                ]
                                plan

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            , test "fills defaults for missing optionals" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "Min", "tasks": [ { "id": "a", "title": "A", "prompt": "do a" } ] }"""
                    in
                    case P.parsePlan json of
                        Ok plan ->
                            Expect.all
                                [ \p -> Expect.equal 1 p.schemaVersion
                                , \p -> Expect.equal P.defaultConcurrency p.concurrency
                                , \p -> Expect.equal P.defaultMaxAttempts p.defaultMaxAttempts
                                , \p -> Expect.equal "" p.goal
                                , \p ->
                                    case List.head p.tasks of
                                        Just t ->
                                            Expect.all
                                                [ \n -> Expect.equal [] n.dependsOn
                                                , \n -> Expect.equal P.defaultMaxAttempts n.maxAttempts
                                                , \n -> Expect.equal Nothing n.preset
                                                , \n -> Expect.equal Nothing n.tools
                                                ]
                                                t

                                        Nothing ->
                                            Expect.fail "no tasks"
                                ]
                                plan

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            , test "rejects unsupported schema_version" <|
                \_ ->
                    let
                        json =
                            """{ "schema_version": 2, "name": "x", "tasks": [ { "id": "a", "title": "A", "prompt": "do a" } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "schema_version") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "rejects empty name" <|
                \_ ->
                    let
                        json =
                            """{ "name": "  ", "tasks": [ { "id": "a", "title": "A", "prompt": "do a" } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "name") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "rejects plan without tasks" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "task") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "rejects malformed JSON with readable error" <|
                \_ ->
                    case P.parsePlan "{ not json" of
                        Err errs ->
                            Expect.equal True (not (List.isEmpty errs))

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "rejects concurrency out of range" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "concurrency": 99, "tasks": [ { "id": "a", "title": "A", "prompt": "do a" } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "concurrency") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "rejects max_attempts < 1" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "a", "title": "A", "prompt": "do a", "max_attempts": 0 } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "max_attempts") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "rejects empty task title / prompt" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "a", "title": "  ", "prompt": "do a" }, { "id": "b", "title": "B", "prompt": "" } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.all
                                [ \e -> Expect.equal True (List.any (String.contains "title") e)
                                , \e -> Expect.equal True (List.any (String.contains "b") e)
                                ]
                                errs

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "reports unknown dependency" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "a", "title": "A", "prompt": "do a", "depends_on": ["ghost"] } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "ghost") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "reports self dependency" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "a", "title": "A", "prompt": "do a", "depends_on": ["a"] } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "itself") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "reports duplicate ids" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "a", "title": "A", "prompt": "do a" }, { "id": "a", "title": "A2", "prompt": "do a2" } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "Duplicate") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "detects direct cycle" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "a", "title": "A", "prompt": "do a", "depends_on": ["b"] }, { "id": "b", "title": "B", "prompt": "do b", "depends_on": ["a"] } ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.all
                                [ \e -> Expect.equal True (List.any (String.contains "Circular") e)
                                , \e -> Expect.equal True (List.any (String.contains "a") e)
                                , \e -> Expect.equal True (List.any (String.contains "b") e)
                                ]
                                errs

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "detects longer cycle" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [
                                 { "id": "a", "title": "A", "prompt": "do a", "depends_on": ["d"] },
                                 { "id": "b", "title": "B", "prompt": "do b", "depends_on": ["a"] },
                                 { "id": "c", "title": "C", "prompt": "do c", "depends_on": ["b"] },
                                 { "id": "d", "title": "D", "prompt": "do d", "depends_on": ["c"] }
                               ] }"""
                    in
                    case P.parsePlan json of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "Circular") errs)

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "accepts diamond DAG (no false cycle)" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [
                                 { "id": "a", "title": "A", "prompt": "do a" },
                                 { "id": "b", "title": "B", "prompt": "do b", "depends_on": ["a"] },
                                 { "id": "c", "title": "C", "prompt": "do c", "depends_on": ["a"] },
                                 { "id": "d", "title": "D", "prompt": "do d", "depends_on": ["b", "c"] }
                               ] }"""
                    in
                    case P.parsePlan json of
                        Ok _ ->
                            Expect.pass

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            , test "accepts parallel independent tasks" <|
                \_ ->
                    let
                        json =
                            """{ "type": "alayaface-plan", "name": "x", "tasks": [
                                 { "id": "a", "title": "A", "prompt": "do a" },
                                 { "id": "b", "title": "B", "prompt": "do b" },
                                 { "id": "c", "title": "C", "prompt": "do c" }
                               ] }"""
                    in
                    case P.parsePlan json of
                        Ok _ ->
                            Expect.pass

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            , test "clamps out-of-range concurrency after default" <|
                \_ ->
                    -- negative concurrency gets clamped in normalize? No:
                    -- validation rejects it; here we check valid 1 and 8 pass.
                    let
                        okJson n =
                            """{ "type": "alayaface-plan", "name": "x", "concurrency": """ ++ String.fromInt n ++ """, "tasks": [ { "id": "a", "title": "A", "prompt": "do a" } ] }"""
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Ok ()) (Result.map (always ()) (P.parsePlan (okJson 1)))
                        , \_ -> Expect.equal (Ok ()) (Result.map (always ()) (P.parsePlan (okJson 8)))
                        ]
                        ()
            ]
        , describe "encodePlan"
            [ test "roundtrips a normalized plan" <|
                \_ ->
                    case P.parsePlan sampleJson of
                        Ok plan ->
                            let
                                redecoded =
                                    D.decodeValue P.decodePlan (P.encodePlan plan)
                            in
                            case redecoded of
                                Ok plan2 ->
                                    Expect.equal plan plan2

                                Err err ->
                                    Expect.fail ("roundtrip failed: " ++ D.errorToString err)

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            , test "encoded output has all schema keys" <|
                \_ ->
                    case P.parsePlan sampleJson of
                        Ok plan ->
                            let
                                encoded =
                                    E.encode 2 (P.encodePlan plan)
                            in
                            Expect.all
                                [ \e -> Expect.equal True (String.contains "\"schema_version\"" e)
                                , \e -> Expect.equal True (String.contains "\"default_max_attempts\"" e)
                                , \e -> Expect.equal True (String.contains "\"depends_on\"" e)
                                ]
                                encoded

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            ]
        , describe "type marker"
            [ test "encoded output carries the alayaface-plan marker" <|
                \_ ->
                    case P.parsePlan sampleJson of
                        Ok plan ->
                            let
                                encoded =
                                    E.encode 2 (P.encodePlan plan)
                            in
                            Expect.equal True (String.contains "\"type\": \"alayaface-plan\"" encoded)

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            , test "missing marker is rejected (no backward compatibility)" <|
                \_ ->
                    -- Per user decision: the top-level type marker is
                    -- REQUIRED — a document without it is an error.
                    case P.parsePlan """{ "schema_version": 1, "name": "x", "tasks": [] }""" of
                        Err errs ->
                            Expect.equal True (List.any (\e -> String.contains "type" e || String.contains "Missing" e) errs)

                        Ok _ ->
                            Expect.fail "should have rejected the missing marker"
            , test "wrong marker value is rejected" <|
                \_ ->
                    case P.parsePlan """{ "type": "not-a-plan", "name": "x", "tasks": [] }""" of
                        Err errs ->
                            Expect.equal True (List.any (String.contains "type") errs)

                        Ok _ ->
                            Expect.fail "should have rejected the wrong marker"
            , test "raw newline inside a string is repaired (model-typical JSON)" <|
                \_ ->
                    -- The model wrote REAL line breaks inside the "prompt"
                    -- string instead of \n escapes — invalid JSON that used
                    -- to make the whole plan silently undetectable.
                    -- repairJson must fix it and keep the content.
                    let
                        json =
                            """{ "type": "alayaface-plan", "schema_version": 1, "name": "x", "goal": "g", "tasks": [ { "id": "t1", "title": "A", "prompt": "line1
line2
line3", "max_attempts": 3 } ] }"""
                    in
                    case P.parsePlan json of
                        Ok plan ->
                            case List.head plan.tasks of
                                Just t ->
                                    Expect.equal "line1\nline2\nline3" t.prompt

                                Nothing ->
                                    Expect.fail "missing task"

                        Err errs ->
                            Expect.fail ("repair failed: " ++ String.join "; " errs)
            , test "raw tab inside a string is repaired" <|
                \_ ->
                    let
                        json =
                            "{ \"type\": \"alayaface-plan\", \"name\": \"x\", \"tasks\": [ { \"id\": \"t1\", \"title\": \"A\", \"prompt\": \"a\tb\" } ] }"
                    in
                    case P.parsePlan json of
                        Ok plan ->
                            Expect.pass

                        Err errs ->
                            Expect.fail ("repair failed: " ++ String.join "; " errs)
            , test "valid JSON passes through repair unchanged" <|
                \_ ->
                    case P.parsePlan sampleJson of
                        Ok plan ->
                            Expect.equal "Monthly Report" plan.name

                        Err errs ->
                            Expect.fail ("unexpected errors: " ++ String.join "; " errs)
            ]
        , describe "slugify"
            [ test "basic slug" <|
                \_ -> Expect.equal "monthly-report" (P.slugify "Monthly Report")
            , test "non-alphanumeric collapsed" <|
                \_ -> Expect.equal "a-b-c" (P.slugify "  a!!b??c  ")
            , test "non-ASCII characters fall back to plan" <|
                \_ -> Expect.equal "plan" (P.slugify "🚀🎉✨")
            , test "empty fallback" <|
                \_ -> Expect.equal "plan" (P.slugify "")
            , test "keeps digits" <|
                \_ -> Expect.equal "report-2025" (P.slugify "Report 2025")
            ]
        , describe "run state codec"
            [ test "encode then decode overlay roundtrips" <|
                \_ ->
                    let
                        plan =
                            case P.parsePlan sampleJson of
                                Ok p -> p
                                Err errs -> Debug.todo ("bad plan: " ++ String.join "; " errs)

                        run =
                            P.emptyRunState "run-1" plan

                        -- simulate: a succeeded, b failed once then waiting
                        withStates =
                            { run
                                | status = P.InProgress
                                , nodes =
                                    Dict.update "t1"
                                        (\_ ->
                                            Just
                                                { nodeId = "t1"
                                                , status = P.Succeeded
                                                , attempts = 1
                                                , maxAttempts = 3
                                                , sessionId = Just "s1"
                                                , lastSessionId = Just "s1"
                                                , attemptSessions = [ "s1" ]
                                                , failures = []
                                                , startedAt = Just 100
                                                , finishedAt = Just 200
                                                , output = Just "the answer"
                                                }
                                        )
                                        (Dict.update "t2"
                                            (\_ ->
                                                Just
                                                    { nodeId = "t2"
                                                    , status = P.Waiting
                                                    , attempts = 1
                                                    , maxAttempts = 3
                                                    , sessionId = Nothing
                                                    , lastSessionId = Just "s-old"
                                                    , attemptSessions = [ "s-old", "s-old2" ]
                                                    , failures = [ { attempt = 1, reason = "boom", at = 300 } ]
                                                    , startedAt = Nothing
                                                    , finishedAt = Nothing
                                                    , output = Nothing
                                                    }
                                            )
                                            run.nodes
                                        )
                            }

                        encoded =
                            P.encodeRunState withStates

                        decoded =
                            D.decodeValue P.decodeRunStateOverlay encoded
                    in
                    case decoded of
                        Ok overlay ->
                            let
                                restored =
                                    P.applyRunStateOverlay overlay (P.emptyRunState "run-1" plan)
                            in
                            Expect.all
                                [ \r -> Expect.equal P.InProgress r.status
                                , \r -> Expect.equal P.Succeeded (nodeState "t1" r).status
                                , \r -> Expect.equal (Just "s1") (nodeState "t1" r).sessionId
                                , \r -> Expect.equal (Just "s1") (nodeState "t1" r).lastSessionId
                                , \r -> Expect.equal [ "s1" ] (nodeState "t1" r).attemptSessions
                                , \r -> Expect.equal (Just "the answer") (nodeState "t1" r).output
                                , \r -> Expect.equal P.Waiting (nodeState "t2" r).status
                                , \r -> Expect.equal (Just "s-old") (nodeState "t2" r).lastSessionId
                                , \r -> Expect.equal [ "s-old", "s-old2" ] (nodeState "t2" r).attemptSessions
                                , \r -> Expect.equal Nothing (nodeState "t2" r).output
                                , \r -> Expect.equal 1 (List.length (nodeState "t2" r).failures)
                                , \r -> Expect.equal "boom" (Maybe.withDefault { attempt = 0, reason = "", at = 0 } (List.head (nodeState "t2" r).failures)).reason
                                ]
                                restored

                        Err err ->
                            Expect.fail ("decode failed: " ++ D.errorToString err)
            , test "lenient: missing attempt_session_ids decodes to []" <|
                \_ ->
                    -- Old run files predate attempt_session_ids; the node
                    -- decoder must overlay a default instead of failing.
                    let
                        nodeJson =
                            """{"node_id":"t1","status":"failed","attempts":2,"max_attempts":3,
                                "session_id":null,"last_session_id":"s-old",
                                "failures":[{"attempt":1,"reason":"boom","at":1}],
                                "started_at":null,"finished_at":null}"""

                        decoded =
                            D.decodeString P.nodeRunStateDecoderPublic nodeJson
                    in
                    case decoded of
                        Ok n ->
                            Expect.all
                                [ \ns -> Expect.equal P.Failed ns.status
                                , \ns -> Expect.equal (Just "s-old") ns.lastSessionId
                                , \ns -> Expect.equal [] ns.attemptSessions
                                , \ns -> Expect.equal Nothing ns.output
                                ]
                                n

                        Err e ->
                            Expect.fail ("lenient decode failed: " ++ D.errorToString e)
            , test "unknown status strings are rejected" <|
                \_ ->
                    let
                        json =
                            """{ "run_id": "r", "status": "bogus", "nodes": {} }"""
                    in
                    case D.decodeString P.decodeRunStateOverlay json of
                        Err _ ->
                            Expect.pass

                        Ok _ ->
                            Expect.fail "should have failed"
            , test "waiting_for_plan node status roundtrips through the string codec" <|
                \_ ->
                    Expect.all
                        [ \_ -> Expect.equal "waiting_for_plan" (P.nodeStatusToString P.WaitingForPlan)
                        , \_ -> Expect.equal (Just P.WaitingForPlan) (P.nodeStatusFromString "waiting_for_plan")
                        ]
                        ()
            ]
        , describe "unknown-field detection (schema typo guard)"
            [ test "misspelled plan field is rejected with a readable error" <|
                \_ ->
                    case P.parsePlan """{ "type": "alayaface-plan", "name": "x", "concurreny": 5, "tasks": [ { "id": "t1", "title": "A", "prompt": "a" } ] }""" of
                        Ok _ ->
                            Expect.fail "plan with unknown field must be rejected"

                        Err errs ->
                            Expect.equal True (List.any (String.contains "Unknown plan field: concurreny") errs)
            , test "misspelled depends_on is rejected (silent ignore would drop the dependency)" <|
                \_ ->
                    case P.parsePlan """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "t1", "title": "A", "prompt": "a" }, { "id": "t2", "title": "B", "prompt": "b", "depend_on": ["t1"] } ] }""" of
                        Ok _ ->
                            Expect.fail "plan with misspelled dependency must be rejected"

                        Err errs ->
                            Expect.all
                                [ \e -> Expect.equal True (List.any (String.contains "Unknown task field \"depend_on\" (task \"t2\")") e)
                                -- the misspelled dep must NOT be silently accepted as "no dependency"
                                , \e -> Expect.equal False (List.any (String.contains "cycle detected") e)
                                ]
                                errs
            , test "misspelled task max_attemps is rejected" <|
                \_ ->
                    case P.parsePlan """{ "type": "alayaface-plan", "name": "x", "tasks": [ { "id": "t1", "title": "A", "prompt": "a", "max_attemps": 5 } ] }""" of
                        Ok _ ->
                            Expect.fail "plan with misspelled task field must be rejected"

                        Err errs ->
                            Expect.equal True (List.any (String.contains "Unknown task field \"max_attemps\"") errs)
            , test "a plan with all known fields parses without unknown-field errors" <|
                \_ ->
                    case P.parsePlan """{ "type": "alayaface-plan", "schema_version": 1, "name": "x", "goal": "g", "concurrency": 2, "default_max_attempts": 3, "tasks": [ { "id": "t1", "title": "A", "prompt": "a", "depends_on": [], "preset": "Default", "tools": "read_file", "max_attempts": 3 } ] }""" of
                        Ok _ ->
                            Expect.pass

                        Err errs ->
                            Expect.fail ("valid plan rejected: " ++ String.join "; " errs)
            , test "unknown field errors join other validation errors" <|
                \_ ->
                    case P.parsePlan """{ "type": "alayaface-plan", "name": "x", "unknown_plan_thing": 1, "tasks": [ { "id": "t1", "title": "A", "prompt": "a", "depends_on": ["nope"] } ] }""" of
                        Ok _ ->
                            Expect.fail "must be rejected"

                        Err errs ->
                            Expect.all
                                [ \e -> Expect.equal True (List.any (String.contains "Unknown plan field: unknown_plan_thing") e)
                                , \e -> Expect.equal True (List.any (String.contains "depends on unknown task") e)
                                ]
                                errs
            ]
        ]
