module ArchTest exposing (tests)

{-| `App.Arch`: the freeze queue and object-store replies.

This path had no unit tests at all before it was sliced out of the dispatcher —
the e2e suites (`pt`, `cancel-confirm`, `plan`) cover it end to end, which is why
it survived, but none of them can see the things pinned here: that a reply
arriving after its freeze was abandoned does not corrupt the next one, that a
failed write drops the QUEUE and not just the freeze, that the refs file is the
only thing addressed by session id rather than by hash, and that an object which
is neither a version nor a block is not cached under its hash (a poisoned cache
entry is permanent, because the key is the content).

Effects are asserted because `App.Arch` returns them as `Action` data — a `Cmd`
return value would have left the whole refs/put behaviour untestable.
-}

import App.Arch as Arch exposing (Action(..))
import App.Types as AT
import Arch.Freeze as Freeze
import Arch.Values as AV
import Dict
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)
import TestHelpers



-- ─── fixtures ──────────────────────────────────────────────────────

base : AT.Model
base =
    let
        m =
            TestHelpers.initModelWithSession
    in
    { m | homeDir = "/home/t" }


runSummary : AV.RunSummary
runSummary =
    { runId = "r1"
    , status = "Succeeded"
    , startedAt = 1
    , finishedAt = Just 2
    , summary = "one task"
    }


{-| A freeze of one run and no message blocks: reqIds 0 = the run, 1 = the
version object. Blocks would need 50 messages to appear, and the arithmetic under
test is the same either way.
-}
freeze : Freeze.FreezeState
freeze =
    Freeze.begin "s1" [] [ ( "p1", runSummary ) ] [] Nothing Nothing


frozen : Int -> String -> Freeze.FreezeState
frozen reqId hash =
    Freeze.onPutResult reqId (Just hash) freeze


active : Freeze.FreezeState -> AT.Model
active st =
    let
        m =
            base
    in
    { m | freezeActive = Just st }


putReply : Int -> Bool -> String -> E.Value
putReply reqId ok hash =
    E.object
        [ ( "reqId", E.string (String.fromInt reqId) )
        , ( "ok", E.bool ok )
        , ( "hash", E.string hash )
        , ( "error", E.string "" )
        ]


getReply : String -> Bool -> String -> E.Value
getReply hash ok content =
    E.object
        [ ( "reqId", E.string hash )
        , ( "ok", E.bool ok )
        , ( "content", E.string content )
        , ( "error", E.string "" )
        ]


versionJson : List String -> String
versionJson blocks =
    E.encode 0
        (E.object
            [ ( "blocks", E.list E.string blocks )
            , ( "planViews", E.object [] )
            , ( "parent", E.null )
            ]
        )


kindOf : List Arch.Action -> List String
kindOf actions =
    List.map
        (\action ->
            case action of
                Put reqId _ ->
                    "Put " ++ String.fromInt reqId

                Get hash ->
                    "Get " ++ hash

                WriteRefs path _ ->
                    "WriteRefs " ++ path
        )
        actions


refsOf : AT.Model -> String -> AV.SessionRefs
refsOf model sid =
    Dict.get sid model.sessionRefs |> Maybe.withDefault (AV.SessionRefs sid "" [] Nothing)



-- ─── the object_put reply ──────────────────────────────────────────

putTests : Test
putTests =
    describe "App.Arch — one freeze at a time"
        [ test "a put reply with no active freeze changes nothing" <|
            \_ ->
                -- reqId only means something inside the active freeze, so a reply
                -- whose freeze was already abandoned must not be applied to
                -- whatever froze next.
                Arch.objectPutResult (putReply 0 True "h") base
                    |> Expect.equal ( base, [] )
        , test "an unreadable put reply changes nothing" <|
            \_ ->
                Arch.objectPutResult (E.object []) (active freeze)
                    |> Expect.equal ( active freeze, [] )
        , test "a run put advances the freeze and asks for the version object" <|
            \_ ->
                let
                    ( m, actions ) =
                        Arch.objectPutResult (putReply 0 True "rh1") (active freeze)

                    -- `Put 1` is the version object's reqId: blocks(0) + runs(1).
                    st =
                        Maybe.withDefault freeze m.freezeActive
                in
                Expect.all
                    [ \_ -> Expect.equal True (Dict.member 0 st.runHashes)
                    , \_ -> Expect.equal Nothing st.versionHash
                    , \_ -> Expect.equal [ "Put 1" ] (kindOf actions)
                    , \_ -> Expect.equal "" (refsOf m "s1").head
                    ]
                    ()
        , test "the version put completes the freeze and moves the head pointer" <|
            \_ ->
                let
                    ( step1, _ ) =
                        Arch.objectPutResult (putReply 0 True "rh1") (active freeze)

                    ( m, actions ) =
                        Arch.objectPutResult (putReply 1 True "vh1") step1

                    refs =
                        refsOf m "s1"
                in
                Expect.all
                    [ \_ -> Expect.equal "vh1" refs.head
                    , \_ -> Expect.equal [ "vh1" ] refs.versions
                    , \_ -> Expect.equal Nothing m.freezeActive
                    , \_ -> Expect.equal [ "WriteRefs /home/t/.alayaface/sessions/s1/session.refs.json" ] (kindOf actions)
                    ]
                    ()
        , test "the refs file carries the new head, written by session id" <|
            \_ ->
                let
                    ( step1, _ ) =
                        Arch.objectPutResult (putReply 0 True "rh1") (active freeze)

                    ( _, actions ) =
                        Arch.objectPutResult (putReply 1 True "vh1") step1
                in
                case actions of
                    [ WriteRefs _ content ] ->
                        Expect.all
                            [ \_ -> Expect.equal True (String.contains "\"head\": \"vh1\"" content)
                            , \_ -> Expect.equal True (String.contains "\"s1\"" content)
                            ]
                            ()

                    other ->
                        Expect.fail ("expected exactly one refs write, got " ++ String.fromInt (List.length other))
        , test "a failed object write drops the whole queue, not just this freeze" <|
            \_ ->
                -- Half a version is worse than no version, and re-running the later
                -- freeze against the same messages would rebuild the same objects.
                let
                    m =
                        { base | freezeActive = Just freeze, freezeQueue = [ freeze, freeze ] }
                in
                Arch.objectPutResult (putReply 0 False "") m
                    |> Tuple.first
                    |> Expect.all
                        [ \mm -> Expect.equal Nothing mm.freezeActive
                        , \mm -> Expect.equal [] mm.freezeQueue
                        ]
        , test "a queued freeze starts the moment the active one finishes" <|
            \_ ->
                let
                    m =
                        { base | freezeActive = Just freeze, freezeQueue = [ frozen 0 "rh2" ] }

                    ( step1, _ ) =
                        Arch.objectPutResult (putReply 0 True "rh1") m

                    ( step2, actions ) =
                        Arch.objectPutResult (putReply 1 True "vh1") step1
                in
                Expect.all
                    [ \_ -> Expect.equal [] step2.freezeQueue
                    , \_ -> Expect.equal (Just (frozen 0 "rh2")) step2.freezeActive
                    , \_ -> Expect.equal [ "Put 0", "WriteRefs /home/t/.alayaface/sessions/s1/session.refs.json" ] (kindOf actions)
                    ]
                    ()
        ]



-- ─── the object_get reply ──────────────────────────────────────────

getTests : Test
getTests =
    describe "App.Arch — reading objects back"
        [ test "a version payload fills the version cache" <|
            \_ ->
                let
                    ( m, actions ) =
                        Arch.objectGetResult (getReply "v1" True (versionJson [ "b1", "b2" ])) base
                in
                Expect.all
                    [ \_ -> Expect.equal 1 (Dict.size m.versionCache)
                    , \_ -> Expect.equal (Just [ "b1", "b2" ]) (Dict.get "v1" m.versionCache |> Maybe.map .blocks)
                    , \_ -> Expect.equal [] actions
                    ]
                    ()
        , test "no blocks are fetched for a version nobody is looking at" <|
            \_ ->
                let
                    ( _, actions ) =
                        Arch.objectGetResult (getReply "v1" True (versionJson [ "b1" ])) base
                in
                Expect.equal [] actions
        , test "the version being viewed fetches ONLY its missing blocks" <|
            \_ ->
                -- Both entry points into a version share this rule; a second copy
                -- is how a version ends up rendered with a hole in it.
                let
                    m =
                        { base | versionViewFor = Just "v1", blockCache = Dict.fromList [ ( "b1", [] ) ] }

                    ( _, actions ) =
                        Arch.objectGetResult (getReply "v1" True (versionJson [ "b1", "b2" ])) m
                in
                Expect.equal [ "Get b2" ] (kindOf actions)
        , test "a block payload fills the block cache, not the version cache" <|
            \_ ->
                let
                    ( m, _ ) =
                        Arch.objectGetResult (getReply "b1" True """{"messages":[]}""") base
                in
                Expect.all
                    [ \_ -> Expect.equal [ "b1" ] (Dict.keys m.blockCache)
                    , \_ -> Expect.equal [] (Dict.keys m.versionCache)
                    ]
                    ()
        , test "content that is neither version nor block is dropped, not cached" <|
            \_ ->
                -- The cache key IS the content hash, so storing garbage here is
                -- permanent: every later read of that hash would return it.
                Arch.objectGetResult (getReply "zz" True "not json") base
                    |> Expect.equal ( base, [] )
        , test "a failed get changes nothing" <|
            \_ ->
                Arch.objectGetResult (getReply "v1" False "") base
                    |> Expect.equal ( base, [] )
        ]



-- ─── version browsing ──────────────────────────────────────────────

browseTests : Test
browseTests =
    let
        cached =
            { base | versionCache = Dict.fromList [ ( "v1", AV.Version [ "b1", "b2" ] Dict.empty Nothing ) ] }
    in
    describe "App.Arch — browsing versions (read-only)"
        [ test "opening a list takes the overlay slot from the Session Manager" <|
            \_ ->
                let
                    m =
                        { base | showSessionManager = True }

                    ( m1, actions ) =
                        Arch.openVersionList "s1" m
                in
                Expect.all
                    [ \_ -> Expect.equal (Just "s1") m1.versionListFor
                    , \_ -> Expect.equal False m1.showSessionManager
                    , \_ -> Expect.equal [] actions
                    ]
                    ()
        , test "an uncached version asks for the version object and waits" <|
            \_ ->
                -- One round trip: objectGetResult fetches the blocks when the
                -- version lands, so racing both here would double every get.
                let
                    ( m, actions ) =
                        Arch.viewVersion "s1" "v9" base
                in
                Expect.all
                    [ \_ -> Expect.equal [ "Get v9" ] (kindOf actions)
                    , \_ -> Expect.equal (Just "v9") m.versionViewFor
                    , \_ -> Expect.equal (Just "s1") m.versionViewSession
                    , \_ -> Expect.equal Nothing m.versionListFor
                    ]
                    ()
        , test "a cached version goes straight to its missing blocks" <|
            \_ ->
                let
                    withOne =
                        { cached | blockCache = Dict.fromList [ ( "b1", [] ) ] }

                    ( _, actions ) =
                        Arch.viewVersion "s1" "v1" withOne
                in
                Expect.equal [ "Get b2" ] (kindOf actions)
        , test "closing the view clears the hash and the session it came from" <|
            \_ ->
                let
                    m =
                        { base | versionViewFor = Just "v1", versionViewSession = Just "s1" }
                in
                Arch.closeVersionView m
                    |> Tuple.first
                    |> Expect.all
                        [ \mm -> Expect.equal Nothing mm.versionViewFor
                        , \mm -> Expect.equal Nothing mm.versionViewSession
                        ]
        , test "closing the list leaves the view alone" <|
            \_ ->
                let
                    m =
                        { base | versionListFor = Just "s1", versionViewFor = Just "v1" }

                    ( m1, _ ) =
                        Arch.closeVersionList m
                in
                Expect.all
                    [ \_ -> Expect.equal Nothing m1.versionListFor
                    , \_ -> Expect.equal (Just "v1") m1.versionViewFor
                    ]
                    ()
        ]



-- ─── the entry point ───────────────────────────────────────────────

tests : Test
tests =
    describe "App.Arch — the freeze queue and the object store"
        [ putTests
        , getTests
        , browseTests
        ]
