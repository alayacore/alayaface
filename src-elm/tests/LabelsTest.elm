module LabelsTest exposing (tests)

{-| The session label document (G-series, docs/session-identity.md).

Two things this suite exists to keep from happening:

  * **A field silently dropped from the user's file.** `sync_session_label`
    replaces the document, so the serialised key list is pinned (`keysAreTheDocument`)
    exactly as `AsrConfigTest` pins `asr.conf` — adding a field has to be a
    decision, not an accident of someone's encoder.
  * **The three implementations disagreeing about a name.** The client, the Go
    backend and the Rust backend each decide "is this stored label usable", and
    a mismatch shows up as the same session named in the title bar and nameless
    in the manager. `testdata/serialization/label_cases.json` is the shared table
    for the two backends; the `readTableAgreesWithTheBackends` group below is the
    client's copy of the cases that decide, kept in sync by hand and named the
    same on purpose. (Elm cannot read a file in a test, so a fixture case added
    without its twin here is a real gap — the names are the check.)

What is NOT covered here, and why: `withLabelSave` returns a `Cmd` (the
`App/UiLayout` shape — a model-aware module may), and a test cannot see which
port a `Cmd` names. The model half IS asserted, and the two are one step: the
function that emits the write is the only thing that may change the map, so a
model assertion catches "wrote when it should not" but not "updated the model
and never sent". `e2e/label-e2e.mjs` (G3) is what proves the port fires, by
reading the file back through the RPC.
-}

import App.Labels as AL
import App.Types as AT
import App.Update as AU
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Json.Decode as D
import Json.Encode as E
import Session.Labels as L
import Test exposing (Test, describe, test)
import TestHelpers exposing (initModelWithSession)


encodeTest : L.Label -> E.Value
encodeTest =
    L.encode


{-| One round trip as an assertion on the unit value, so `Expect.all` can hold
several of them in one test.
-}
roundTrips : String -> Bool -> () -> Expectation
roundTrips text auto _ =
    let
        label =
            { text = text, auto = auto }
    in
    label
        |> encodeTest
        |> L.decode
        |> Expect.equal (Just label)


decodeTest : String -> Maybe L.Label
decodeTest json =
    case D.decodeString D.value json |> Result.toMaybe of
        Just value ->
            L.decode value

        Nothing ->
            Nothing


{-| A model with one open session, ready to be named or left unnamed. -}
board : AT.Model
board =
    initModelWithSession


{-| A board whose session already has a name. `viaSave` picks HOW it got it —
from a listing (disk) or from this process's own save (what the editor will do in
G2). Both must be immune to a later derivation (SD-G8), and they are different
origins even though the model stores only the name.
-}
named : Bool -> String -> AT.Model -> AT.Model
named viaSave text model =
    if viaSave then
        Tuple.first (AL.withLabelSave "/home/u/.alayaface/sessions" "s1" { text = text, auto = False } ( model, Cmd.none ))

    else
        { model | sessionLabels = Dict.insert "s1" text model.sessionLabels }


tests : Test
tests =
    describe "session label"
        [ documentGroup
        , readTableAgreesWithTheBackends
        , autoNameGroup
        , policyGroup
        , autoDecisionGroup
        , dispatcherGroup
        ]


documentGroup : Test
documentGroup =
    describe "the document"
        [ test "the serialised document is exactly these bytes" <|
            \_ ->
                -- Order matters for the first time anyone diffs two clients'
                -- files, and the KEY SET matters always: `sync_session_label`
                -- replaces the file, so a key the encoder forgets is a key the
                -- user loses (the `model.conf` / `asr.conf` lesson). Asserted on
                -- the string because Elm's `Dict.keys` SORTS — a decode-into-Dict
                -- assertion can prove the set and can never prove the order,
                -- which is how the first version of this test passed while
                -- checking nothing.
                -- `E.encode 2` is what `App.Labels.withLabelSave` sends, so this
                -- is the exact text of the user's file — 2-space pretty, the same
                -- choice `Arch.Values.refsContent` makes for session.refs.json.
                L.encode { text = "refactor the parser", auto = False }
                    |> E.encode 2
                    |> Expect.equal
                        """{
  "v": 1,
  "label": "refactor the parser",
  "auto": false
}"""

        , test "the key list is the one the backends store" <|
            \_ ->
                Expect.equal [ "v", "label", "auto" ] L.keys

        , test "round trip: what is written is what is read back" <|
            \_ ->
                Expect.all
                    [ roundTrips "refactor the parser" False
                    , roundTrips "重构 parser" True
                    , roundTrips " x " False
                    ]
                    ()

        , test "a padded label round-trips VERBATIM — the reader does not repair" <|
            \_ ->
                -- The backends return the stored bytes untouched (SD-G9's second
                -- half). If the client trimmed on read, a name with a trailing
                -- space would show in the manager (backend-provided) and not in
                -- the title bar (client-provided).
                decodeTest """{"v":1,"label":"  keep me  ","auto":false}"""
                    |> Maybe.map .text
                    |> Expect.equal (Just "  keep me  ")

        , test "an unknown version still reads (forward compatibility)" <|
            \_ ->
                decodeTest """{"v":99,"label":"written by a newer client","auto":false}"""
                    |> Expect.equal (Just { text = "written by a newer client", auto = False })

        , test "the path is the identity's root directory, not a work copy" <|
            \_ ->
                L.storedPath "/home/u/.alayaface/sessions" "sess-1"
                    |> Expect.equal "/home/u/.alayaface/sessions/sess-1/session.label.json"
        ]


{-| The client's copy of the deciding cases from
testdata/serialization/label_cases.json. Same names, same expectations: the two
backends run the file, this runs the same table, and any drift means one
implementation shows a name the others refuse.
-}
readTableAgreesWithTheBackends : Test
readTableAgreesWithTheBackends =
    let
        caseOf : ( String, Maybe String ) -> Test
        caseOf ( name, expected ) =
            test name <|
                \_ ->
                    Expect.equal (Maybe.map (\t -> { text = t, auto = autoOf name }) expected)
                        (decodeTest (bodyOf name))
    in
    describe "the read table (label_cases.json names shared)"
        (List.map caseOf
            [ ( "plain", Just "refactor the parser" )
            , ( "chinese-label", Just "帮我看看 reader.go 为什么" )
            , ( "hanzi-at-cap", Just (String.repeat 120 "中") )
            , ( "hanzi-over-cap", Nothing )
            , ( "latin-at-cap", Just (String.repeat 120 "a") )
            , ( "latin-over-cap", Nothing )
            , ( "future-version-reads", Just "written by a newer client" )
            , ( "unmodelled-field-wrong-type", Just "ok" )
            , ( "label-null", Nothing )
            , ( "label-missing", Nothing )
            , ( "label-empty", Nothing )
            , ( "label-whitespace-only", Nothing )
            , ( "padded-label-verbatim", Just " x " )
            , ( "label-wrong-type", Nothing )
            , ( "not-json-body", Nothing )
            , ( "non-object-body", Nothing )
            , ( "trailing-garbage", Nothing )
            , ( "empty-body", Nothing )
            ]
        )


{-| Which `auto` the shared-name cases carry. The fixture stores `auto: true`
only for the Chinese auto-derived case; the rest are user-chosen. Keeping this a
function of the case name means the table above stays one list.
-}
autoOf : String -> Bool
autoOf name =
    name == "chinese-label"


bodyOf : String -> String
bodyOf name =
    case name of
        "plain" ->
            """{"v":1,"label":"refactor the parser","auto":false}"""

        "chinese-label" ->
            """{"v":1,"label":"帮我看看 reader.go 为什么","auto":true}"""

        "hanzi-at-cap" ->
            labelBody (String.repeat 120 "中")

        "hanzi-over-cap" ->
            labelBody (String.repeat 121 "中")

        "latin-at-cap" ->
            labelBody (String.repeat 120 "a")

        "latin-over-cap" ->
            labelBody (String.repeat 121 "a")

        "future-version-reads" ->
            """{"v":2,"label":"written by a newer client","auto":false}"""

        "unmodelled-field-wrong-type" ->
            """{"v":1,"label":"ok","auto":"yes"}"""

        "label-null" ->
            """{"v":1,"label":null,"auto":false}"""

        "label-missing" ->
            """{"v":1,"auto":false}"""

        "label-empty" ->
            """{"v":1,"label":"","auto":false}"""

        "label-whitespace-only" ->
            """{"v":1,"label":"   \n ","auto":false}"""

        "padded-label-verbatim" ->
            """{"v":1,"label":" x ","auto":false}"""

        "label-wrong-type" ->
            """{"v":1,"label":42,"auto":false}"""

        "not-json-body" ->
            "this is not json"

        "non-object-body" ->
            "[1,2]"

        "trailing-garbage" ->
            """{"v":1,"label":"a","auto":false} trailing"""

        "empty-body" ->
            ""

        _ ->
            ""


labelBody : String -> String
labelBody text =
    E.encode 2 (E.object [ ( "v", E.int 1 ), ( "label", E.string text ), ( "auto", E.bool False ) ])


autoNameGroup : Test
autoNameGroup =
    describe "autoFromPrompt"
        [ test "blank or whitespace-only input derives nothing" <|
            \_ ->
                List.map L.autoFromPrompt [ "", "   ", "\n\t " ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]

        , test "a short prompt becomes the whole name, marked auto" <|
            \_ ->
                L.autoFromPrompt "does this rename work?"
                    |> Expect.equal (Just { text = "does this rename work?", auto = True })

        , test "newlines and tabs collapse to single spaces" <|
            \_ ->
                L.autoFromPrompt "  line one\n\tline two   three "
                    |> Maybe.map .text
                    |> Expect.equal (Just "line one line two three")

        , test "normalise is idempotent (the editor must not open dirty)" <|
            \_ ->
                let
                    once =
                        L.normalise "a\n\n b\t c "

                    twice =
                        L.normalise once
                in
                Expect.equal once twice

        , test "a long prompt is cut at a word boundary, not mid-word" <|
            \_ ->
                let
                    derived =
                        L.autoFromPrompt
                            "the quick brown fox jumps over the lazy dog and keeps running far past the limit yes"
                            |> Maybe.map .text
                            |> Maybe.withDefault ""

                    body =
                        String.slice 0 -1 derived
                in
                Expect.all
                    [ \() -> Expect.equal True (String.endsWith "…" derived)
                    , \() -> Expect.atMost (L.autoLabelChars + 1) (String.length derived)
                    , \() -> Expect.equal False (String.endsWith " " body)
                    , \() -> Expect.equal True (String.contains "lazy dog" body)
                    ]
                    ()

        , test "a prompt with no spaces at all is hard-cut, not lost" <|
            \_ ->
                L.autoFromPrompt (String.repeat 200 "x")
                    |> Maybe.map .text
                    |> Maybe.withDefault ""
                    |> String.length
                    |> Expect.equal (L.autoLabelChars + 1)

        , test "the derived name always fits the storage cap" <|
            \_ ->
                -- autoLabelChars is a client-only number; if it ever grew past
                -- maxLabelChars the auto write would be refused by its own
                -- document, i.e. names would silently stop being derived.
                Expect.atMost L.maxLabelChars L.autoLabelChars

        , test "the storage cap counts CHARACTERS (120 hanzi is 360 bytes)" <|
            \_ ->
                L.decode
                    (E.object
                        [ ( "v", E.int 1 )
                        , ( "label", E.string (String.repeat 120 "中") )
                        , ( "auto", E.bool False )
                        ]
                    )
                    |> Expect.equal (Just { text = String.repeat 120 "中", auto = False })

        , test "an astral-plane name is refused HERE though the backends would store it" <|
            \_ ->
                -- Elm counts UTF-16 units, Go runes, Rust chars. 120 emoji are
                -- 120 characters there and 240 units here, so the client is the
                -- strictest of the three. That direction is the safe one (a user
                -- sees "too long" on their own input; the store never keeps a
                -- name the UI will not show). This test asserts the DIRECTION so
                -- a change to the unit has to be deliberate.
                Expect.equal Nothing
                    (L.decode
                        (E.object
                            [ ( "v", E.int 1 )
                            , ( "label", E.string (String.repeat 120 "😀") )
                            , ( "auto", E.bool False )
                            ]
                        )
                    )
        ]


policyGroup : Test
policyGroup =
    describe "App.Labels policy"
        [ test "a listing fills names this process does not have" <|
            \_ ->
                AL.foldListing [ dirJson "s1" "from disk" ] board
                    |> .sessionLabels
                    |> Dict.get "s1"
                    |> Expect.equal (Just "from disk")

        , test "a listing never overwrites what the user just named" <|
            \_ ->
                -- The refresh and the save are both in flight over an async RPC.
                -- Disk-wins here would put the old name back on screen after the
                -- user typed the new one, and no final-model test would see it.
                AL.foldListing [ dirJson "s1" "old name" ] (named True "new name" board)
                    |> .sessionLabels
                    |> Dict.get "s1"
                    |> Expect.equal (Just "new name")

        , test "an entry for a session the listing does not mention survives" <|
            \_ ->
                -- A session created after the listing was taken is legitimately
                -- absent from it; dropping it would blank a live window's name.
                AL.foldListing [] (named False "just made" board)
                    |> .sessionLabels
                    |> Dict.size
                    |> Expect.equal 1

        , test "a listing entry with no usable name adds nothing" <|
            \_ ->
                AL.foldListing [ dirJson "s1" "", dirJson "s2" "   " ] board
                    |> .sessionLabels
                    |> Dict.isEmpty
                    |> Expect.equal True

        , test "titleFor: the name when there is one" <|
            \_ ->
                AL.titleFor (named False "重构 parser" board) "s1"
                    |> Expect.equal "重构 parser"

        , test "titleFor: the seat number when there is none (unchanged UI)" <|
            \_ ->
                -- The fallback must be exactly what the bar said before this
                -- feature, or "a session with no name" becomes a visible
                -- regression rather than a no-op.
                let
                    seated =
                        { board | sessionNums = Dict.insert "s1" 7 board.sessionNums }
                in
                Expect.all
                    [ \() -> Expect.equal "Session 7" (AL.titleFor seated "s1")
                    , \() -> Expect.equal "Session 0" (AL.titleFor board "s1")
                    ]
                    ()

        , test "titleFor: an unknown id is a seat 0, not a crash or a blank" <|
            \_ ->
                Expect.equal "Session 0" (AL.titleFor board "no-such-session")

        , test "titleTooltip: the name verbatim plus the id" <|
            \_ ->
                -- The bar truncates by width (SD-G13), so the tooltip is the
                -- only place a long name is fully readable, and the id is the
                -- only stable handle when there is no name at all.
                AL.titleTooltip (named False "  padded name  " board) "s1"
                    |> Expect.equal "  padded name  \ns1"

        , test "forgetAll drops a deleted identity, and only those" <|
            \_ ->
                { board
                    | sessionLabels =
                        Dict.fromList [ ( "s1", "gone" ), ( "s2", "kept" ) ]
                }
                    |> AL.forgetAll [ "s1", "p1" ]
                    |> .sessionLabels
                    |> Dict.keys
                    |> Expect.equal [ "s2" ]
        ]


dirJson : String -> String -> E.Value
dirJson id label =
    E.object
        [ ( "id", E.string id )
        , ( "created_at", E.string "1756000000" )
        , ( "preset", E.string "Default" )
        , ( "label", E.string label )
        ]


{-| The context `autoNameOnFirstPrompt` asks for. Every test uses the session
`TestHelpers` already put on the board ("s1"), so the record is built from the
case rather than reached for out of the model — the caller (the dispatcher) is
the one that resolves those facts, and this module passes what it resolved
(AGENTS.md's rule for these modules).
-}
autoPrompt : String -> { sessionsDir : String, sessionId : String, prompt : String, isNodeSession : Bool }
autoPrompt text =
    { sessionsDir = "/home/u/.alayaface/sessions"
    , sessionId = "s1"
    , prompt = text
    , isNodeSession = False
    }


nodePrompt : String -> { sessionsDir : String, sessionId : String, prompt : String, isNodeSession : Bool }
nodePrompt text =
    let
        base =
            autoPrompt text
    in
    { base | isNodeSession = True }


autoDecisionGroup : Test
autoDecisionGroup =
    describe "autoNameOnFirstPrompt decides"
        [ test "no name yet → the model now carries the derived one" <|
            \_ ->
                let
                    ( m, _ ) =
                        AL.autoNameOnFirstPrompt (autoPrompt "first thing typed") ( board, neverCmd )
                in
                Expect.equal (Just "first thing typed") (Dict.get "s1" m.sessionLabels)

        , test "a name that came from disk is not replaced by a derivation" <|
            \_ ->
                let
                    ( m, _ ) =
                        AL.autoNameOnFirstPrompt (autoPrompt "second thing")
                            ( named False "first thing" board, neverCmd )
                in
                Expect.equal (Just "first thing") (Dict.get "s1" m.sessionLabels)

        , test "a name the user chose is not replaced by a derivation" <|
            \_ ->
                let
                    ( m, _ ) =
                        AL.autoNameOnFirstPrompt (autoPrompt "second thing")
                            ( named True "what I meant" board, neverCmd )
                in
                Expect.equal (Just "what I meant") (Dict.get "s1" m.sessionLabels)

        , test "a plan node session is not named at all (SD-G15)" <|
            \_ ->
                let
                    ( m, _ ) =
                        AL.autoNameOnFirstPrompt (nodePrompt "node prompt") ( board, neverCmd )
                in
                Expect.equal Dict.empty m.sessionLabels

        , test "nothing is stored for a prompt that is only media (blank text)" <|
            \_ ->
                let
                    ( m, _ ) =
                        AL.autoNameOnFirstPrompt (autoPrompt "   ") ( board, neverCmd )
                in
                Expect.equal Dict.empty m.sessionLabels

        , test "writing a name puts it in the model AND asks for the save" <|
            \_ ->
                -- The two are one step (`withLabelSave` is the only producer of
                -- both), so this is the assertion that a "set the map, forget
                -- the port" change fails. The Cmd is opaque to a test, so the
                -- port actually firing is proven by e2e/label-e2e.mjs (G3).
                let
                    ( m, cmd ) =
                        AL.withLabelSave "/home/u/.alayaface/sessions" "s2"
                            { text = "renamed", auto = False }
                            ( board, neverCmd )
                in
                Expect.all
                    [ \() ->
                        Expect.equal (Just "renamed") (Dict.get "s2" m.sessionLabels)
                    , \() ->
                        -- the incoming command is carried, not dropped
                        Expect.notEqual neverCmd cmd
                    ]
                    ()
        ]


{-| The dispatcher's own path: a send is where the auto name comes from, and the
model after `SendPrompt` is what the window title will read. Asserting through
`App.Update.update` (not just the module) is what keeps the hook attached to the
send rather than merely existing next to it.
-}
dispatcherGroup : Test
dispatcherGroup =
    describe "the send path names the session"
        [ test "typing a first prompt records the derived name" <|
            \_ ->
                let
                    model =
                        { board
                            | homeDir = "/home/u"
                            , sessions =
                                Dict.update "s1"
                                    (Maybe.map (\s -> { s | input = "summarise the failing test output" }))
                                    board.sessions
                        }

                    ( m, _ ) =
                        AU.update AT.SendPrompt model
                in
                Expect.equal (Just "summarise the failing test output")
                    (Dict.get "s1" m.sessionLabels)

        , test "a send in a session that already has a name changes nothing" <|
            \_ ->
                let
                    -- A record update needs a plain variable base:
                    -- `{ named ... board | homeDir = ... }` is a parse error,
                    -- the rule docs/update-slices.md records from the first
                    -- slice (and which I walked straight into here).
                    already =
                        named True "my name" board
                in
                let
                    model =
                        { already
                            | homeDir = "/home/u"
                            , sessions =
                                Dict.update "s1"
                                    (Maybe.map (\s -> { s | input = "another prompt" }))
                                    already.sessions
                        }

                    ( m, _ ) =
                        AU.update AT.SendPrompt model
                in
                Expect.equal (Just "my name") (Dict.get "s1" m.sessionLabels)
        ]


neverCmd : Cmd AT.Msg
neverCmd =
    Cmd.none
