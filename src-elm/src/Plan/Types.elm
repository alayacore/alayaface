module Plan.Types exposing
    ( TaskNode
    , Plan
    , defaultConcurrency
    , defaultMaxAttempts
    , schemaVersion
    , decodePlan
    , parsePlan
    , normalizeAndValidate
    , encodePlan
    , slugify
      -- Runner types (state machine logic lives in Plan.Runner)
    , NodeStatus(..)
    , RunStatus(..)
    , FailureRecord
    , NodeRunState
    , RunState
    , Effect(..)
    , emptyNodeRunState
    , emptyRunState
    )

{-| Plan Mode data model: DAG plan schema, JSON codecs, normalization
and validation. Pure module — no ports, no side effects.

The on-disk schema (see docs/plan-mode.md §5):

    {
      "schema_version": 1,
      "name": "...",
      "goal": "...",
      "concurrency": 2,
      "default_max_attempts": 3,
      "tasks": [
        { "id": "t1", "title": "...", "prompt": "...",
          "depends_on": [], "preset": "Data", "tools": "...",
          "max_attempts": 2 }
      ]
    }

Decoding is lenient (missing optionals get defaults); validation then
reports all readable errors (dup ids, unknown deps, cycles, ...). The
saved file is always the NORMALIZED plan (schema_version=1, defaults
filled) via `encodePlan`.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E


-- Constants


schemaVersion : Int
schemaVersion =
    1


defaultConcurrency : Int
defaultConcurrency =
    2


defaultMaxAttempts : Int
defaultMaxAttempts =
    3


maxConcurrency : Int
maxConcurrency =
    8


minConcurrency : Int
minConcurrency =
    1


-- Model


type alias TaskNode =
    { id : String
    , title : String
    , prompt : String
    , dependsOn : List String
    , preset : Maybe String
    , tools : Maybe String
    , maxAttempts : Int
    }


type alias Plan =
    { schemaVersion : Int
    , name : String
    , goal : String
    , concurrency : Int
    , defaultMaxAttempts : Int
    , tasks : List TaskNode
    }


-- Runner types (defined here so Types.elm stays the single model home;
-- state machine logic lives in Plan.Runner)


type NodeStatus
    = Pending
    | Starting
    | Running
    | Succeeded
    | Failed
    | Blocked
    | Canceled


type RunStatus
    = NotStarted
    | InProgress
    | Paused
    | Completed
    | FailedRun
    | Stopped


type alias FailureRecord =
    { attempt : Int
    , reason : String
    , at : Int
    }


type alias NodeRunState =
    { nodeId : String
    , status : NodeStatus
    , attempts : Int
    , maxAttempts : Int
    , sessionId : Maybe String
    , failures : List FailureRecord
    , startedAt : Maybe Int
    , finishedAt : Maybe Int
    }


type alias RunState =
    { plan : Plan
    , runId : String
    , status : RunStatus
    , concurrency : Int
    , nodes : Dict String NodeRunState
    , startedAt : Maybe Int
    , finishedAt : Maybe Int
    }


type Effect
    = CreateSessionFor String
    | SendPrompt String String
    | CloseSessionFor String String
    | ScheduleRetry String Int
    | PersistRunState
    | Notify String


emptyNodeRunState : TaskNode -> NodeRunState
emptyNodeRunState node =
    { nodeId = node.id
    , status = Pending
    , attempts = 0
    , maxAttempts = node.maxAttempts
    , sessionId = Nothing
    , failures = []
    , startedAt = Nothing
    , finishedAt = Nothing
    }


emptyRunState : String -> Plan -> RunState
emptyRunState runId plan =
    { plan = plan
    , runId = runId
    , status = NotStarted
    , concurrency = plan.concurrency
    , nodes = Dict.fromList (List.map (\t -> ( t.id, emptyNodeRunState t )) plan.tasks)
    , startedAt = Nothing
    , finishedAt = Nothing
    }


-- JSON decoding (lenient: missing optionals get defaults)


taskDecoder : D.Decoder TaskNode
taskDecoder =
    D.map7 TaskNode
        (D.field "id" D.string)
        (D.field "title" D.string)
        (D.field "prompt" D.string)
        (D.oneOf [ D.field "depends_on" (D.list D.string), D.succeed [] ])
        (D.maybe (D.field "preset" D.string))
        (D.maybe (D.field "tools" D.string))
        (D.oneOf [ D.field "max_attempts" D.int, D.succeed defaultMaxAttempts ])


planDecoder : D.Decoder Plan
planDecoder =
    D.map6 Plan
        (D.oneOf [ D.field "schema_version" D.int, D.succeed schemaVersion ])
        (D.field "name" D.string)
        (D.oneOf [ D.field "goal" D.string, D.succeed "" ])
        (D.oneOf [ D.field "concurrency" D.int, D.succeed defaultConcurrency ])
        (D.oneOf [ D.field "default_max_attempts" D.int, D.succeed defaultMaxAttempts ])
        (D.field "tasks" (D.list taskDecoder))


decodePlan : D.Decoder Plan
decodePlan =
    planDecoder


{-| Parse raw plan JSON text: decode, then normalize + validate.
Errors are a readable list (all problems found, not just the first).
-}
parsePlan : String -> Result (List String) Plan
parsePlan text =
    case D.decodeString planDecoder text of
        Ok plan ->
            normalizeAndValidate plan

        Err err ->
            Err [ D.errorToString err ]


{-| Normalize defaults and validate. Returns the normalized plan on
success (schema_version fixed to 1, defaults filled, bounded values).
-}
normalizeAndValidate : Plan -> Result (List String) Plan
normalizeAndValidate plan =
    let
        errors =
            validate plan
    in
    if List.isEmpty errors then
        Ok (normalize plan)

    else
        Err errors


normalize : Plan -> Plan
normalize plan =
    { plan
        | schemaVersion = schemaVersion
        , concurrency = clamp minConcurrency maxConcurrency plan.concurrency
        , defaultMaxAttempts = max 1 plan.defaultMaxAttempts
        , tasks = List.map normalizeTask plan.tasks
    }


normalizeTask : TaskNode -> TaskNode
normalizeTask t =
    { t | maxAttempts = max 1 t.maxAttempts }


validate : Plan -> List String
validate plan =
    List.concat
        [ if plan.schemaVersion == schemaVersion then
            []

          else
            [ "Unsupported schema_version: " ++ String.fromInt plan.schemaVersion ++ " (expected " ++ String.fromInt schemaVersion ++ ")" ]
        , if String.isEmpty (String.trim plan.name) then
            [ "Plan name must not be empty" ]

          else
            []
        , if List.isEmpty plan.tasks then
            [ "Plan must contain at least one task" ]

          else
            []
        , if plan.concurrency < minConcurrency || plan.concurrency > maxConcurrency then
            [ "concurrency must be between " ++ String.fromInt minConcurrency ++ " and " ++ String.fromInt maxConcurrency ]

          else
            []
        , if plan.defaultMaxAttempts < 1 then
            [ "default_max_attempts must be >= 1" ]

          else
            []
        , List.concatMap (validateTask plan) plan.tasks
        , duplicateIdErrors plan.tasks
        , cycleErrors plan.tasks
        ]


validateTask : Plan -> TaskNode -> List String
validateTask plan t =
    List.concat
        [ if String.isEmpty (String.trim t.id) then
            [ "Task id must not be empty" ]

          else
            []
        , if String.isEmpty (String.trim t.title) then
            [ "Task \"" ++ t.id ++ "\" title must not be empty" ]

          else
            []
        , if String.isEmpty (String.trim t.prompt) then
            [ "Task \"" ++ t.id ++ "\" prompt must not be empty" ]

          else
            []
        , if t.maxAttempts < 1 then
            [ "Task \"" ++ t.id ++ "\" max_attempts must be >= 1" ]

          else
            []
        , if List.member t.id t.dependsOn then
            [ "Task \"" ++ t.id ++ "\" depends on itself" ]

          else
            []
        , List.filterMap (unknownDepError plan t) t.dependsOn
        ]


unknownDepError : Plan -> TaskNode -> String -> Maybe String
unknownDepError plan t dep =
    if List.any (\other -> other.id == dep) plan.tasks then
        Nothing

    else
        Just ("Task \"" ++ t.id ++ "\" depends on unknown task \"" ++ dep ++ "\"")


duplicateIdErrors : List TaskNode -> List String
duplicateIdErrors tasks =
    let
        counts =
            List.foldl
                (\t acc ->
                    Dict.update t.id
                        (\maybeN -> Just (Maybe.withDefault 0 maybeN + 1))
                        acc
                )
                Dict.empty
                tasks
    in
    Dict.toList counts
        |> List.filter (\( _, n ) -> n > 1)
        |> List.map (\( id, n ) -> "Duplicate task id \"" ++ id ++ "\" (" ++ String.fromInt n ++ " times)")


cycleErrors : List TaskNode -> List String
cycleErrors tasks =
    let
        byId =
            List.foldl (\t acc -> Dict.insert t.id t acc) Dict.empty tasks

        remaining =
            remainingAfterTopo byId
    in
    if List.isEmpty remaining then
        []

    else
        [ "Circular dependency involving: " ++ String.join ", " remaining ]


{-| Node ids that cannot be processed by Kahn's algorithm — i.e. nodes
in a cycle or depending on a cycle. Dependencies on unknown ids are
ignored here (reported separately by unknownDepError).
-}
remainingAfterTopo : Dict String TaskNode -> List String
remainingAfterTopo byId =
    let
        indegree : Dict String Int
        indegree =
            Dict.map
                (\_ t -> List.filter (\d -> Dict.member d byId) t.dependsOn |> List.length)
                byId

        initialQueue =
            Dict.foldl
                (\id n acc -> if n == 0 then id :: acc else acc)
                []
                indegree

        step : List String -> List String -> Dict String Int -> List String
        step queue visited indeg =
            case queue of
                [] ->
                    -- done: nodes never visited are cyclic (or depend on a cycle)
                    Dict.keys byId |> List.filter (\id -> not (List.member id visited))

                id :: rest ->
                    case Dict.get id byId of
                        Nothing ->
                            step rest visited indeg

                        Just t ->
                            let
                                ( newIndeg, zeros ) =
                                    -- Kahn: decrement indegree of t's SUCCESSORS
                                    -- (nodes that depend on t), not its deps.
                                    successors t.id byId
                                        |> List.foldl
                                            (\s ( ind, newZeros ) ->
                                                case Dict.get s ind of
                                                    Just n ->
                                                        let
                                                            n2 = n - 1
                                                        in
                                                        if n2 <= 0 then
                                                            ( Dict.insert s 0 ind, s :: newZeros )

                                                        else
                                                            ( Dict.insert s n2 ind, newZeros )

                                                    Nothing ->
                                                        ( ind, newZeros )
                                            )
                                            ( indeg, [] )
                            in
                            step (rest ++ List.reverse zeros) (id :: visited) newIndeg
    in
    step initialQueue [] indegree


{-| Ids of nodes that depend on the given id (its successors in the DAG).
-}
successors : String -> Dict String TaskNode -> List String
successors id byId =
    Dict.foldl
        (\_ t acc -> if List.member id t.dependsOn then t.id :: acc else acc)
        []
        byId


-- JSON encoding (normalized plan → disk)


encodePlan : Plan -> E.Value
encodePlan p =
    E.object
        [ ( "schema_version", E.int p.schemaVersion )
        , ( "name", E.string p.name )
        , ( "goal", E.string p.goal )
        , ( "concurrency", E.int p.concurrency )
        , ( "default_max_attempts", E.int p.defaultMaxAttempts )
        , ( "tasks", E.list encodeTask p.tasks )
        ]


encodeTask : TaskNode -> E.Value
encodeTask t =
    E.object
        (List.filterMap identity
            [ Just ( "id", E.string t.id )
            , Just ( "title", E.string t.title )
            , Just ( "prompt", E.string t.prompt )
            , Just ( "depends_on", E.list E.string t.dependsOn )
            , Maybe.map (\p -> ( "preset", E.string p )) t.preset
            , Maybe.map (\x -> ( "tools", E.string x )) t.tools
            , Just ( "max_attempts", E.int t.maxAttempts )
            ]
        )


{-| Filesystem-safe slug from a plan name (lowercase, non-alphanumeric
→ "-", collapsed; empty result falls back to "plan").
-}
slugify : String -> String
slugify name =
    let
        raw =
            name
                |> String.toLower
                |> String.toList
                |> List.map (\c -> if Char.isAlphaNum c then c else '-')
                |> String.fromList
                |> String.split "-"
                |> List.filter (not << String.isEmpty)
                |> String.join "-"
    in
    if String.isEmpty raw then
        "plan"

    else
        raw
