module SessionEventsTest exposing (tests)

{-| Direct tests for the inbound-event routing in `Session/Events.elm`.

These arms were previously reachable only through `App.Update.update`, which is
why they were never tested in isolation: driven from the dispatcher, a wrong
guard and a wrong field look identical from outside (both are "the transcript did
not update"), and telling them apart needed a browser and a race. The module
returns `Action` DATA, so both halves are assertable now — what it wrote and what
it wanted to do. `elm-explorations/test` has no way to open a `Cmd`, so the second
half is testable only because of that data shape.

"Left the model untouched" is a projection, not whole-model equality: `Model`
holds `E.Value`s, which have no structural equality, so comparing two models is
not available. `touched` is the write set of `deltaEvent`/`statusEvent` — read its
comment, because that is where the strength of every untouched-claim below is
actually defined.
-}

import Dict exposing (Dict)
import Expect
import Json.Decode as D
import Json.Encode as E
import Set
import App.Types as AT
import App.Update
import Set
import Plan.Runner as R
import Plan.Types as PT
import Session.Events as SE
import Session.Protocol as P
import Session.Selector as Sel exposing (Page(..))
import Session.Types as T
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


-- Fixtures


{-| A delta frame as the bridge sends it: `deltaEventDecoder` requires all four
keys, so a fixture missing one tests the Err branch instead.
-}
deltaJson : String -> String -> String -> E.Value
deltaJson sid tag content =
    E.object
        [ ( "session_id", E.string sid )
        , ( "history_id", E.string "h1" )
        , ( "content", E.string content )
        , ( "tag", E.string tag )
        ]


statusJson : String -> Bool -> String -> E.Value
statusJson sid connected message =
    E.object
        [ ( "session_id", E.string sid )
        , ( "connected", E.bool connected )
        , ( "message", E.string message )
        ]


{-| Undecodable as a delta (no `tag`), as a status (no `connected`) and as a
frame (no `tag`), so one fixture serves every Err-branch test. Pinned by a test
rather than trusted: a fixture that quietly became decodable would turn four
tests into assertions about nothing.
-}
brokenJson : E.Value
brokenJson =
    E.object [ ( "session_id", E.string "s1" ), ( "content", E.string "x" ) ]


{-| A frame as the bridge sends it. `frameEventDecoder` requires
`session_id`, `tag` and `raw_value` and takes the rest as nullable, so every
field is spelled out here: a missing one would test the Err branch, not the arm.
-}
frameJson : String -> String -> Maybe String -> String -> Maybe E.Value -> E.Value
frameJson sid tag historyId content json =
    E.object
        [ ( "session_id", E.string sid )
        , ( "tag", E.string tag )
        , ( "raw_value", E.string content )
        , ( "history_id", Maybe.map E.string historyId |> Maybe.withDefault E.null )
        , ( "content", E.string content )
        , ( "json", Maybe.withDefault E.null json )
        , ( "user_content_type", E.null )
        ]


{-| A completed assistant-text frame carrying `content` as its final message. -}
atFrame : String -> E.Value
atFrame content =
    frameJson "s1" "AT" (Just "h1") content Nothing


{-| A user echo: the same content, but the message's role is User. -}
utFrame : String -> E.Value
utFrame content =
    frameJson "s1" "UT" (Just "h2") content Nothing


{-| An `SM` system frame — readiness, task and error signals all arrive this way. -}
smFrame : String -> E.Value -> E.Value
smFrame sid json =
    frameJson sid "SM" Nothing "" (Just json)


readyJson : E.Value
readyJson =
    E.object
        [ ( "type", E.string "session" )
        , ( "data", E.object [ ( "state", E.string "ready" ) ] )
        ]


errorJson : String -> E.Value
errorJson text =
    E.object
        [ ( "type", E.string "error" )
        , ( "data", E.object [ ( "text", E.string text ) ] )
        ]


{-| A `CO` command-output frame for `model_sync`: the one frame whose handling
re-enters the dispatcher. -}
syncCo : Bool -> String -> E.Value
syncCo isError message =
    frameJson "s1" "CO" Nothing ""
        (Just
            (E.object
                [ ( "type", E.string "command_output" )
                , ( "name", E.string "model_sync" )
                , ( "is_error", E.bool isError )
                , ( "output", E.object [ ( "message", E.string message ) ] )
                ]
            )
        )


fencedPlan : String
fencedPlan =
    "```json\n{\"type\": \"alayaface-plan\", \"name\": \"x\", \"tasks\": [\n  { \"id\": \"t1\", \"title\": \"T1\", \"prompt\": \"p1\" }\n]}\n```"


session : T.SessionState
session =
    T.emptySession "s1"


{-| The session the user is looking at, scrolled up or not. Auto-follow only
re-pins a view that was already following — the point of the flag.
-}
withAtBottom : Bool -> AT.Model
withAtBottom flag =
    { initModelWithSession | sessions = Dict.insert "s1" { session | atBottom = flag } Dict.empty }


{-| A sync in flight: the overlay is waiting for a `model_sync` CO that a
disconnect will now never deliver.
-}
syncing : AT.Model
syncing =
    let
        -- A record update needs a plain variable as its base:
        -- `{ session.modelSelector | page = … }` is a parse error.
        selector =
            session.modelSelector
    in
    { initModelWithSession
        | sessions =
            Dict.insert "s1"
                { session
                    | modelSelector = { selector | page = ModelSelSyncing }
                    , sendPending = True
                }
                Dict.empty
    }


{-| The same session after a fork: `s1` now talks to `core-2`, so the ORIGINAL
core id — which for a root session IS the Session.id — names a stale work copy.
This is the case C2b (I-G) exists for: the dying process is still emitting, and a
`connected: false` from it must not reach the session the user is looking at.
-}
modelAfterFork : AT.Model
modelAfterFork =
    { initModelWithSession | sessionWorkCopies = Dict.fromList [ ( "s1", "core-2" ) ] }


{-| A work copy whose session is NOT registered: `s9` is what the mapping says,
`core-2` is what the frame carries. Without both halves the buffer-key test below
proves nothing — with no mapping, the core id and the Session.id are the same
string, so keying the buffer wrongly is invisible.
-}
modelWithUnregisteredWorkCopy : AT.Model
modelWithUnregisteredWorkCopy =
    { initModelWithSession | sessionWorkCopies = Dict.fromList [ ( "s9", "core-2" ) ] }


{-| A session whose LAST message is not the one a late `AT` frame rewrites: the
assistant message (history id `h1`) sits under a later user echo.

This fixture exists because a fresh AT frame always ends the list with an
assistant message, so nothing else can reach the offer's role guard — with that
guard deleted, every other plan test still passes. A corrected or late frame is
the real case: the transcript's last line is the user's echo, and its content is
whatever the user pasted, fences included.
-}
modelWithLatePlanTarget : AT.Model
modelWithLatePlanTarget =
    let
        msg id role content hid =
            { id = id
            , role = role
            , content = content
            , toolId = Nothing
            , toolName = Nothing
            , isError = False
            , historyId = Just hid
            , media = Nothing
            }
    in
    { initModelWithSession
        | sessions =
            Dict.insert "s1"
                { session
                    | messages =
                        [ msg "m-a" T.Assistant "an earlier answer" "h1"
                        , msg "m-u" T.User fencedPlan "h2"
                        ]
                }
                Dict.empty
    }


{-| A model whose session `sid` is owned by a running plan node.
`findPlanIdBySession` matches on `conversationId`, so that is the only binding
that has to be real.
-}
modelWithNodeSession : String -> AT.Model
modelWithNodeSession sid =
    let
        plan =
            case PT.parsePlan "{\"type\": \"alayaface-plan\", \"name\": \"x\", \"tasks\": [{ \"id\": \"t1\", \"title\": \"T1\", \"prompt\": \"p1\" }]}" of
                Ok p ->
                    p

                Err errs ->
                    Debug.todo ("bad test plan: " ++ String.join "; " errs)

        baseRun =
            PT.emptyRunState "r-1" plan

        node =
            { nodeId = "t1"
            , status = PT.Running
            , attempts = 1
            , maxAttempts = 3
            , conversationId = Just sid
            , lastSessionId = Just sid
            , attemptSessions = [ sid ]
            , failures = []
            , startedAt = Just 1
            , finishedAt = Nothing
            , output = Nothing
            }

        view0 =
            AT.emptyPlanView
    in
    { initModelWithSession
        | planWindows =
            Dict.insert
                "p1"
                { view = { view0 | plan = Just plan, path = Just "/h/sessions/s1/plans/p1/p1.json" }
                , run = Just { baseRun | nodes = Dict.insert "t1" node baseRun.nodes }
                , runPath = Nothing
                , runLog = []
                , selectedNode = Nothing
                , resumePath = Nothing
                , infoOpen = False
                }
                Dict.empty
    }


{-| Everything `deltaEvent` and `statusEvent` may write, reduced to comparable
values: per session the message count, connection state, status line, the stuck
"Sending…" flag and which model-selector page is showing; then the plan counts,
the buffer (keyed by core id, length only — the frames themselves are `E.Value`s)
and the keys that already warned.

This is the definition of every "untouched" claim below, and therefore also their
limit: it notices nothing that is not in it. If an arm gains a write, add the
field here, or the untouched tests will keep passing while the arm touches.
-}
type alias SessionTouch =
    { id : String
    , messages : Int
    , connected : Bool
    , statusMsg : String
    , sendPending : Bool
    , page : String
    , ready : Bool
    }


type alias Touch =
    { sessions : List SessionTouch
    , planCounts : Dict String Int
    , buffer : List ( String, Int )
    , overflow : List String
    , offers : List ( String, Int, String )
    , replaying : List String
    , queuedPrompts : List ( String, String )
    }


touched : AT.Model -> Touch
touched m =
    { sessions =
        m.sessions
            |> Dict.toList
            |> List.map
                (\( id, s ) ->
                    { id = id
                    , messages = List.length s.messages
                    , connected = s.connected
                    , statusMsg = s.statusMsg
                    , sendPending = s.sendPending
                    , page = pageName s.modelSelector.page
                    , ready = s.ready
                    }
                )
    , planCounts = m.planMessageCounts
    , buffer =
        m.pendingEvents
            |> Dict.toList
            |> List.map (\( key, queued ) -> ( key, List.length queued ))
    , overflow = Set.toList m.pendingOverflow
    , offers =
        m.pendingPlanOffers
            |> Dict.toList
            |> List.map (\( ( id, idx ), raw ) -> ( id, idx, raw ))
    , replaying = Set.toList m.planReplaySessions
    , queuedPrompts = Dict.toList m.pendingNodePrompts
    }


{-| The projection this suite actually compares most often: the arms write
`sessions` on nearly every path, so "untouched" has to mean "no session moved".
-}
sessionsOf : AT.Model -> List SessionTouch
sessionsOf =
    touched >> .sessions


pageName : Sel.Page -> String
pageName page =
    case page of
        ModelSelList ->
            "list"

        ModelSelEdit ->
            "edit"

        ModelSelConfirmSync ->
            "confirm"

        ModelSelSyncing ->
            "syncing"

        ModelSelSyncFailed ->
            "sync-failed"

        ModelSelLoading ->
            "loading"


warnings : List SE.Action -> List String
warnings actions =
    actions
        |> List.filterMap
            (\action ->
                case action of
                    SE.LogWarn message ->
                        Just message

                    _ ->
                        Nothing
            )


{-| Did this path warn exactly once, and about the right port? Both halves
matter: zero warnings is the silent swallow this suite exists to prevent, and a
warning that names the wrong decoder sends the next reader to the wrong file.
-}
warnedAbout : String -> List SE.Action -> Bool
warnedAbout portName actions =
    case warnings actions of
        [ only ] ->
            String.startsWith (portName ++ " decode failed: ") only

        _ ->
            False


{-| The plan offers an action list announced. Compared against the model's
`offers` by the tests below: the pair agreeing IS the D0 invariant. -}
announced : List SE.Action -> List ( String, Int )
announced actions =
    actions
        |> List.filterMap
            (\action ->
                case action of
                    SE.PlanOffer sid idx ->
                        Just ( sid, idx )

                    _ ->
                        Nothing
            )


actionsOf : List SE.Action -> List String
actionsOf actions =
    actions
        |> List.map
            (\action ->
                case action of
                    SE.LogWarn _ ->
                        "logWarn"

                    SE.ScrollToBottom _ ->
                        "scroll"

                    SE.RunnerEvent _ ->
                        "runner"

                    SE.SendPrompt _ _ ->
                        "sendPrompt"

                    SE.PlanOffer _ _ ->
                        "planOffer"

                    SE.Defer _ ->
                        "defer"
            )


{-| The runner events in an action list. These two tests are about the runner
decision, so they assert that subset: every frame also re-pins the viewport (the
session is at the bottom in the fixture), and asserting the whole list here would
be a scrolling test in disguise.
-}
runnerOf : List SE.Action -> List R.Event
runnerOf actions =
    actions
        |> List.filterMap
            (\action ->
                case action of
                    SE.RunnerEvent runnerEvent ->
                        Just runnerEvent

                    _ ->
                        Nothing
            )


bufferKeys : AT.Model -> List ( String, Int )
bufferKeys m =
    m.pendingEvents |> Dict.toList |> List.map (\( key, queued ) -> ( key, List.length queued ))


{-| Fill one buffer key PAST the cap by five, collecting the warnings it emits.
The overshoot is the fixture: at exactly `cap + 1` only one frame is ever in
violation, so a warning that fires per frame looks identical to one that fires
once.
-}
overflowing : String -> AT.Model -> ( AT.Model, List SE.Action )
overflowing key start =
    List.foldl
        (\n ( acc, acts ) ->
            SE.bufferPendingEvent acc key (E.object [ ( "n", E.int n ) ])
                |> Tuple.mapSecond (\more -> acts ++ more)
        )
        ( start, [] )
        (List.range 1 (SE.pendingEventsCap + 5))


{-| Does the broken fixture decode? It must not, and these four tests are
vacuous the moment it does — which is why the first test in this suite asserts
the answer instead of assuming it.
-}
decodes : D.Decoder a -> Bool
decodes decoder =
    D.decodeValue decoder brokenJson |> Result.toMaybe |> (/=) Nothing


tests : Test
tests =
    describe "Session/Events (inbound event routing)"
        [ describe "fixtures"
            [ test "the 'broken' fixture decodes as neither a delta, a status nor a frame" <|
                \_ ->
                    Expect.equal
                        [ False, False, False ]
                        [ decodes P.deltaEventDecoder
                        , decodes P.statusEventDecoder
                        , decodes P.frameEventDecoder
                        ]
            , test "the session fixture is what the dispatcher expects: registered, connected, following" <|
                \_ ->
                    Expect.equal
                        ( 1, Just { id = "s1", messages = 0, connected = True, statusMsg = "Connected", sendPending = False, page = "list", ready = False } )
                        ( Dict.size initModelWithSession.sessions, List.head (sessionsOf initModelWithSession) )
            ]

        -- The difference between a dropped frame and a silently swallowed
        -- protocol change is one console line, and the app looks alive either
        -- way (AGENTS.md rule #1). So: it must say so, and it must not
        -- half-apply.
        , describe "a frame that will not decode"
            [ test "deltaEvent leaves the model untouched and warns exactly once" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.deltaEvent initModelWithSession brokenJson
                    in
                    Expect.all
                        [ \_ -> Expect.equal (sessionsOf initModelWithSession) (sessionsOf m)
                        , \_ -> Expect.equal True (warnedAbout "DeltaEvent" actions)
                        ]
                        ()
            , test "statusEvent leaves the model untouched and warns exactly once" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.statusEvent initModelWithSession brokenJson
                    in
                    Expect.all
                        [ \_ -> Expect.equal (sessionsOf initModelWithSession) (sessionsOf m)
                        , \_ -> Expect.equal True (warnedAbout "StatusEvent" actions)
                        ]
                        ()
            ]

        -- C2b (I-G): the guard runs before anything else, and "before" is the
        -- property under test — a stale frame dropped AFTER being buffered is
        -- still a stale frame waiting in the replay queue.
        , describe "a frame from a stale work copy is dropped"
            [ test "delta: no session write, no buffer, no warning, no scroll" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.deltaEvent modelAfterFork (deltaJson "s1" "At" "late text from the dying core")
                    in
                    Expect.all
                        [ \_ -> Expect.equal (sessionsOf modelAfterFork) (sessionsOf m)
                        , \_ -> Expect.equal [] (bufferKeys m)
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            , test "status: a connected:false from the old core does not disconnect the new one" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.statusEvent modelAfterFork (statusJson "s1" False "old core shutting down")
                    in
                    Expect.all
                        [ \_ -> Expect.equal (sessionsOf modelAfterFork) (sessionsOf m)
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            ]

        , describe "deltaEvent on a registered session"
            [ test "the text lands in the session the frame routes to" <|
                \_ ->
                    let
                        ( m, _ ) =
                            SE.deltaEvent initModelWithSession (deltaJson "s1" "At" "hello")

                        msgs =
                            Dict.get "s1" m.sessions |> Maybe.withDefault session |> .messages
                    in
                    Expect.all
                        [ \_ -> Expect.equal 1 (List.length msgs)
                        , \_ -> Expect.equal (Just "hello") (List.head msgs |> Maybe.map .content)
                        , \_ -> Expect.equal (Just T.Assistant) (List.head msgs |> Maybe.map .role)
                        ]
                        ()
            , test "a view that was at the bottom is re-pinned" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.deltaEvent (withAtBottom True) (deltaJson "s1" "At" "hello")
                    in
                    Expect.equal [ SE.ScrollToBottom "s1" ] actions
            , test "a view the user scrolled up is not dragged down, but the text still arrives" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.deltaEvent (withAtBottom False) (deltaJson "s1" "At" "hello")
                    in
                    Expect.all
                        [ \_ -> Expect.equal [] actions
                        , \_ -> Expect.equal (Just 1) (sessionsOf m |> List.head |> Maybe.map .messages)
                        ]
                        ()
            , test "crossing the ```json fence counts the message as a plan exactly once" <|
                \_ ->
                    let
                        ( once, _ ) =
                            SE.deltaEvent initModelWithSession (deltaJson "s1" "At" fencedPlan)

                        ( twice, _ ) =
                            SE.deltaEvent once (deltaJson "s1" "At" "\nmore text\n")
                    in
                    Expect.equal
                        ( Just 1, Just 1 )
                        ( Dict.get "s1" once.planMessageCounts, Dict.get "s1" twice.planMessageCounts )
            , test "ordinary text does not bump the plan count" <|
                \_ ->
                    let
                        ( m, _ ) =
                            SE.deltaEvent initModelWithSession (deltaJson "s1" "At" "just prose")
                    in
                    Expect.equal Dict.empty m.planMessageCounts
            ]

        , describe "deltaEvent for a session nobody created yet"
            [ test "buffers a racing frame, with no effect at all" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.deltaEvent initModelWithSession (deltaJson "core-9" "At" "racing frame")
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ ( "core-9", 1 ) ] (bufferKeys m)
                        , \_ -> Expect.equal (sessionsOf initModelWithSession) (sessionsOf m)
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            , test "the key is the CORE id, not the Session.id it routes to" <|
                \_ ->
                    -- The replay runs once SessionCreated installs the mapping,
                    -- and it re-resolves every frame from the core id; storing
                    -- under the routed id would leave the queue unreachable.
                    let
                        ( m, _ ) =
                            SE.deltaEvent modelWithUnregisteredWorkCopy (deltaJson "core-2" "At" "early frame")
                    in
                    Expect.equal [ ( "core-2", 1 ) ] (bufferKeys m)
            ]

        , describe "statusEvent on a registered session"
            [ test "connected:true writes the connection state and the status line" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.statusEvent initModelWithSession (statusJson "s1" True "model ready")

                        s =
                            Dict.get "s1" m.sessions |> Maybe.withDefault session
                    in
                    Expect.all
                        [ \_ -> Expect.equal "model ready" s.statusMsg
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            , test "a disconnect clears the stuck 'Sending…' flag" <|
                \_ ->
                    let
                        ( m, _ ) =
                            SE.statusEvent syncing (statusJson "s1" False "gone")
                    in
                    Expect.equal (Just False) (sessionsOf m |> List.head |> Maybe.map .sendPending)
            , test "a disconnect mid-sync fails the sync instead of hanging the overlay" <|
                \_ ->
                    let
                        ( m, _ ) =
                            SE.statusEvent syncing (statusJson "s1" False "gone")

                        s =
                            Dict.get "s1" m.sessions |> Maybe.withDefault session
                    in
                    Expect.all
                        [ \_ -> Expect.equal "sync-failed" (pageName s.modelSelector.page)
                        , \_ -> Expect.equal (Just "Session disconnected during sync") s.modelSelector.syncError
                        ]
                        ()
            , test "a connected:true during a sync leaves the sync running" <|
                \_ ->
                    let
                        ( m, _ ) =
                            SE.statusEvent syncing (statusJson "s1" True "still here")
                    in
                    Expect.equal (Just "syncing") (sessionsOf m |> List.head |> Maybe.map .page)
            ]

        , describe "statusEvent and the plan runner"
            [ test "a node-owned session that disconnects fails its node" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.statusEvent (modelWithNodeSession "s1") (statusJson "s1" False "core died")
                    in
                    Expect.equal [ SE.RunnerEvent (R.SessionDisconnected "s1" "core died") ] actions
            , test "a session no node owns disconnects silently" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.statusEvent initModelWithSession (statusJson "s1" False "core died")
                    in
                    Expect.equal [] actions
            , test "a successful status never wakes the runner, even for a node session" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.statusEvent (modelWithNodeSession "s1") (statusJson "s1" True "fine")
                    in
                    Expect.equal [] actions
            , test "a status for an unregistered work copy buffers under the CORE id" <|
                \_ ->
                    -- The delta arm has the same rule; it is tested twice on
                    -- purpose, because each arm passes `raw` and the key to a
                    -- shared helper by hand and either can be gotten wrong.
                    let
                        ( m, actions ) =
                            SE.statusEvent modelWithUnregisteredWorkCopy (statusJson "core-2" True "early")
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ ( "core-2", 1 ) ] (bufferKeys m)
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            , test "an unknown node session is buffered AND still fails its node" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.statusEvent (modelWithNodeSession "ghost") (statusJson "ghost" False "gone before creation")
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ ( "ghost", 1 ) ] (bufferKeys m)
                        , \_ -> Expect.equal [ SE.RunnerEvent (R.SessionDisconnected "ghost" "gone before creation") ] actions
                        ]
                        ()
            ]

        -- The pair D0 merged. Until the offer lived in a module returning data
        -- there was no way to test it at all: through the dispatcher it produced
        -- a `Task.perform`, which no assertion can open.
        , describe "frameEvent: the plan offer"
            [ test "a completed plan message is recorded and announced together" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.frameEvent initModelWithSession (atFrame fencedPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal 1 (List.length (touched m).offers)
                        , \_ -> Expect.equal (List.map (\( sid, idx, _ ) -> ( sid, idx )) (touched m).offers) (announced actions)
                        ]
                        ()
            , test "the offer index is the plan count AFTER this frame bumped it" <|
                \_ ->
                    -- Load-bearing ordering: `planMessageCounts` is written before
                    -- the offer is keyed, so the first plan of a session is index
                    -- 1, not 0. Flatten the two steps and this goes to 0 — which
                    -- would silently re-key every offer against PlanCreateOffer.
                    let
                        ( m, _ ) =
                            SE.frameEvent initModelWithSession (atFrame fencedPlan)

                        keys =
                            (touched m).offers
                                |> List.map (\( sid, idx, _ ) -> ( sid, idx ))
                    in
                    Expect.equal [ ( "s1", 1 ) ] keys
            , test "the same plan frame twice announces once" <|
                \_ ->
                    let
                        ( once, first ) =
                            SE.frameEvent initModelWithSession (atFrame fencedPlan)

                        ( twice, second ) =
                            SE.frameEvent once (atFrame fencedPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ ( "s1", 1 ) ] (announced first)
                        , \_ -> Expect.equal [] (announced second)
                        , \_ -> Expect.equal 1 (List.length (touched twice).offers)
                        ]
                        ()
            , test "a plan message inside a history replay is not offered again" <|
                \_ ->
                    let
                        replaying =
                            { initModelWithSession | planReplaySessions = Set.singleton "s1" }

                        ( m, actions ) =
                            SE.frameEvent replaying (atFrame fencedPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal [] (touched m).offers
                        , \_ -> Expect.equal [] (announced actions)
                        , \_ -> Expect.equal [ "s1" ] (touched m).replaying
                        ]
                        ()
            , test "a fenced json WITHOUT the alayaface marker is not a plan" <|
                \_ ->
                    -- Models emit fenced json all the time (config, examples).
                    -- The marker is the only thing separating "offer a plan"
                    -- from "the model showed me a json blob".
                    let
                        ( m, actions ) =
                            SE.frameEvent initModelWithSession (atFrame "```json\n{\"foo\": 1}\n```")
                    in
                    Expect.all
                        [ \_ -> Expect.equal [] (touched m).offers
                        , \_ -> Expect.equal [] (announced actions)
                        ]
                        ()
            , test "a user echo wrapped in a plan fence is not a plan" <|
                \_ ->
                    -- The role guard: only an assistant message can offer. UT is
                    -- the user's own text echoed back, and users paste plans too.
                    let
                        ( m, actions ) =
                            SE.frameEvent initModelWithSession (utFrame fencedPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal [] (touched m).offers
                        , \_ -> Expect.equal [] (announced actions)
                        ]
                        ()
            , test "a late AT frame does not offer the user message now on top" <|
                \_ ->
                    -- The same guard, reached the hard way: the AT frame rewrites
                    -- an assistant message that is NOT last, so the message the
                    -- offer decision looks at is the user's echo. Every other
                    -- plan fixture leaves an assistant message last and cannot
                    -- see this branch.
                    let
                        ( m, actions ) =
                            SE.frameEvent modelWithLatePlanTarget (atFrame fencedPlan)
                    in
                    Expect.all
                        [ \_ -> Expect.equal [] (touched m).offers
                        , \_ -> Expect.equal [] (announced actions)
                        ]
                        ()
            ]

        , describe "frameEvent: readiness"
            [ test "the core's ready signal marks the session interactive" <|
                \_ ->
                    let
                        ( m, _ ) =
                            SE.frameEvent initModelWithSession (smFrame "s1" readyJson)
                    in
                    Expect.equal (Just True) ((touched m).sessions |> List.head |> Maybe.map .ready)
            , test "readiness releases the node prompt the gate was holding" <|
                \_ ->
                    let
                        held =
                            { initModelWithSession | pendingNodePrompts = Dict.fromList [ ( "s1", "the queued prompt" ) ] }

                        ( m, actions ) =
                            SE.frameEvent held (smFrame "s1" readyJson)
                    in
                    Expect.all
                        [ \_ -> Expect.equal [] (touched m).queuedPrompts
                        , \_ ->
                            -- The whole list, in order: a ready frame flushes the
                            -- gate's prompt and re-pins the (following) view, and
                            -- nothing else.
                            Expect.equal
                                [ SE.SendPrompt "s1" "the queued prompt", SE.ScrollToBottom "s1" ]
                                actions
                        ]
                        ()
            , test "a queued prompt survives a frame that does not mean ready" <|
                \_ ->
                    let
                        held =
                            { initModelWithSession | pendingNodePrompts = Dict.fromList [ ( "s1", "the queued prompt" ) ] }

                        ( m, actions ) =
                            SE.frameEvent held (smFrame "s1" (errorJson "not a ready frame"))
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ ( "s1", "the queued prompt" ) ] (touched m).queuedPrompts
                        , \_ -> Expect.equal False (List.member "sendPrompt" (actionsOf actions))
                        ]
                        ()
            , test "ready ends replay suppression" <|
                \_ ->
                    let
                        replaying =
                            { initModelWithSession | planReplaySessions = Set.singleton "s1" }

                        ( m, _ ) =
                            SE.frameEvent replaying (smFrame "s1" readyJson)
                    in
                    Expect.equal [] (touched m).replaying
            ]

        , describe "frameEvent: the viewport"
            [ test "a frame re-pins a view that was following" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.frameEvent initModelWithSession (atFrame "done")
                    in
                    Expect.equal [ SE.ScrollToBottom "s1" ] actions
            , test "a state-only frame does not drag up a view the user scrolled" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.frameEvent (withAtBottom False) (smFrame "s1" readyJson)
                    in
                    Expect.equal [] actions
            , test "a user echo is followed even when the user had scrolled up" <|
                \_ ->
                    -- The echo is the user's OWN send, so it always comes into
                    -- view regardless of atBottom.
                    let
                        ( _, actions ) =
                            SE.frameEvent (withAtBottom False) (utFrame "hello")
                    in
                    Expect.equal [ SE.ScrollToBottom "s1" ] actions
            ]

        , describe "frameEvent: the plan runner"
            [ test "an SM error on a node-owned session fails the node" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.frameEvent (modelWithNodeSession "s1") (smFrame "s1" (errorJson "boom"))
                    in
                    Expect.equal [ R.SessionError "s1" "boom" ] (runnerOf actions)
            , test "the same error on a session no node owns is silent" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.frameEvent initModelWithSession (smFrame "s1" (errorJson "boom"))
                    in
                    Expect.equal [] (runnerOf actions)
            ]

        -- The one re-entry. Two things are pinned: that the CO defers, and that
        -- deferring DROPS the frame's own effects (the dispatcher did, so this
        -- must too — see the module comment).
        , describe "frameEvent: a model_sync CO"
            [ test "while the overlay is syncing it defers, alone" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.frameEvent syncing (syncCo False "synced")
                    in
                    Expect.equal
                        [ SE.Defer (AT.ForSession "s1" (AT.ModelSelectorSyncResult False "synced")) ]
                        actions
            , test "an error CO carries the failure through the deferral" <|
                \_ ->
                    let
                        ( _, actions ) =
                            SE.frameEvent syncing (syncCo True "rejected by core")
                    in
                    Expect.equal
                        [ SE.Defer (AT.ForSession "s1" (AT.ModelSelectorSyncResult True "rejected by core")) ]
                        actions
            , test "once the overlay moved on, the same CO does not defer" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.frameEvent initModelWithSession (syncCo False "synced")
                    in
                    Expect.all
                        [ \_ -> Expect.equal False (List.member "defer" (actionsOf actions))
                        , \_ -> Expect.equal (sessionsOf initModelWithSession) (sessionsOf m)
                        ]
                        ()
            , test "a different command's CO never defers" <|
                \_ ->
                    let
                        unrelated =
                            frameJson "s1" "CO" Nothing ""
                                (Just (E.object [ ( "name", E.string "model_add" ), ( "is_error", E.bool False ) ]))

                        ( _, actions ) =
                            SE.frameEvent syncing unrelated
                    in
                    Expect.equal [ "scroll" ] (actionsOf actions)
            , test "the deferred message really is handled: the sync overlay closes" <|
                \_ ->
                    -- End to end through the dispatcher, because the fold that
                    -- makes `Defer` mean anything lives in App.Update.
                    let
                        ( m, _ ) =
                            App.Update.update (AT.FrameEvent (syncCo False "synced")) syncing

                        pageAfter =
                            Dict.get "s1" m.sessions
                                |> Maybe.map (\s -> pageName s.modelSelector.page)
                                |> Maybe.withDefault "?"
                    in
                    Expect.equal "list" pageAfter
            ]

        , describe "frameEvent: the paths every arm shares"
            [ test "a frame that will not decode leaves the model untouched and warns once" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.frameEvent initModelWithSession brokenJson
                    in
                    Expect.all
                        [ \_ -> Expect.equal (touched initModelWithSession) (touched m)
                        , \_ -> Expect.equal True (warnedAbout "FrameEvent" actions)
                        ]
                        ()
            , test "a frame from a stale work copy changes nothing at all" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.frameEvent modelAfterFork (frameJson "s1" "AT" (Just "h1") "from the old core" Nothing)
                    in
                    Expect.all
                        [ \_ -> Expect.equal (touched modelAfterFork) (touched m)
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            , test "a frame for an unregistered session buffers under the core id" <|
                \_ ->
                    let
                        ( m, actions ) =
                            SE.frameEvent modelWithUnregisteredWorkCopy (frameJson "core-2" "AT" (Just "h1") "early" Nothing)
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ ( "core-2", 1 ) ] (touched m).buffer
                        , \_ -> Expect.equal [] actions
                        ]
                        ()
            ]

        -- The replay half, beside the live half. Both decode the same three
        -- kinds; what replay must NOT do is re-run any decision.
        , describe "applyPendingEvent (replay)"
            [ test "a buffered frame, delta and status each apply their content" <|
                \_ ->
                    let
                        sessions =
                            Dict.fromList [ ( "s1", session ) ]

                        afterFrame =
                            SE.applyPendingEvent (\core -> core) (atFrame "a complete message") sessions

                        afterDelta =
                            SE.applyPendingEvent (\core -> core) (deltaJson "s1" "At" " more") afterFrame

                        afterStatus =
                            SE.applyPendingEvent (\core -> core) (statusJson "s1" False "gone") afterDelta
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just T.Assistant) (Dict.get "s1" afterFrame |> Maybe.map (\s -> List.head s.messages |> Maybe.map .role) |> Maybe.withDefault Nothing)
                        , \_ -> Expect.equal 1 (Dict.get "s1" afterFrame |> Maybe.map (\s -> List.length s.messages) |> Maybe.withDefault -1)
                        , \_ -> Expect.equal 2 (Dict.get "s1" afterDelta |> Maybe.map (\s -> List.length s.messages) |> Maybe.withDefault -1)
                        , \_ -> Expect.equal False (Dict.get "s1" afterStatus |> Maybe.map .connected |> Maybe.withDefault True)
                        ]
                        ()
            , test "replay does not touch the session the frame routes away from" <|
                \_ ->
                    -- `sidFor` is the whole routing here: a frame for a work copy
                    -- that maps to a session this replay does not have is dropped,
                    -- not applied to whatever session happens to exist.
                    let
                        after =
                            SE.applyPendingEvent (\core -> "unlisted") (atFrame "x") (Dict.fromList [ ( "s1", session ) ])
                    in
                    Expect.equal 0 (Dict.get "s1" after |> Maybe.map (\s -> List.length s.messages) |> Maybe.withDefault -1)
            , test "a work-copy frame applies to the session it routes to, not under its core id" <|
                \_ ->
                    -- The live path's buffer test taught this one: when the
                    -- assertion is about WHICH KEY a write lands under, the
                    -- fixture has to make the two candidates different values.
                    -- Routing by the raw core id would add a phantom session and
                    -- leave `s1` untouched, and only the key list can see that.
                    let
                        after =
                            SE.applyPendingEvent
                                (\core ->
                                    if core == "core-2" then
                                        "s1"

                                    else
                                        core
                                )
                                (frameJson "core-2" "AT" (Just "h1") "routed" Nothing)
                                (Dict.fromList [ ( "s1", session ) ])
                    in
                    Expect.all
                        [ \_ -> Expect.equal [ "s1" ] (Dict.keys after |> List.sort)
                        , \_ -> Expect.equal (Just 1) (Dict.get "s1" after |> Maybe.map (\s -> List.length s.messages))
                        ]
                        ()
            , test "a value that is none of the three events is ignored" <|
                \_ ->
                    let
                        sessions =
                            Dict.fromList [ ( "s1", session ) ]
                    in
                    Expect.equal (Just 0) (Dict.get "s1" (SE.applyPendingEvent (\c -> c) brokenJson sessions) |> Maybe.map (\s -> List.length s.messages))
            ]

        , describe "the buffer bound, as data"
            [ test "overflow drops the oldest and warns once, not at frame rate" <|
                \_ ->
                    let
                        ( m, actions ) =
                            overflowing "ghost" initModelWithSession
                    in
                    Expect.all
                        [ \_ -> Expect.equal SE.pendingEventsCap (bufferKeys m |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault -1)
                        , \_ -> Expect.equal 1 (List.length (warnings actions))
                        , \_ -> Expect.equal [ "ghost" ] (Set.toList m.pendingOverflow)
                        ]
                        ()
            , test "the warning is per key, so a second runaway session says so too" <|
                \_ ->
                    let
                        ( afterFirst, firstActions ) =
                            overflowing "a" initModelWithSession

                        ( afterSecond, secondActions ) =
                            overflowing "b" afterFirst
                    in
                    Expect.all
                        [ \_ -> Expect.equal 1 (List.length (warnings firstActions))
                        , \_ -> Expect.equal 1 (List.length (warnings secondActions))
                        , \_ -> Expect.equal [ "a", "b" ] (Set.toList afterSecond.pendingOverflow)
                        ]
                        ()
            ]
        ]
