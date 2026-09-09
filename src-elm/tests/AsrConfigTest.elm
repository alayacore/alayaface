module AsrConfigTest exposing (tests)

{-| `App.AsrConfig`: the `asr.conf` schema and the overlay's transitions.

Two suites exist because of the shape of the command: `sync_asr_config` REPLACES
the file, so a field the encoder forgets is a line deleted from the user's config,
and the symptom surfaces in a later session ("the StepAudio profile lost its
language setting"). The rest pin decisions that stay invisible until they are
wrong: what a write may claim before the backend agrees, and what `close` refuses.

One test drives a message through `App.Update` rather than calling a transition:
a transition can be perfectly correct and still never reach the model.
-}

import App.AsrConfig as AS exposing (Action(..))
import App.Types as AT
import App.Update
import Dict
import Expect
import Json.Decode as D
import Json.Encode as E
import Test exposing (Test, describe, test)
import TestHelpers



-- ─── fixtures ──────────────────────────────────────────────────────

profile : String -> AS.Profile
profile id =
    { id = id
    , name = "Local " ++ id
    , protocol = "transcriptions"
    , url = "http://127.0.0.1:8080/v1/audio/transcriptions"
    , apiKey = "key-" ++ id
    , model = "whisper-1"
    , language = "auto"
    }


docOf : List AS.Profile -> AS.Document
docOf ps =
    { active = ps |> List.head |> Maybe.map .id |> Maybe.withDefault ""
    , profiles = ps
    }


withEditor : AS.Editor -> AT.Model
withEditor ed =
    let
        blank =
            TestHelpers.initModelWithSession
    in
    { blank | asrConfigEditor = ed }


{-| A reply body built the way the transport builds one — four keys present, the
profiles taken from the encoder's OWN output, so this fixture cannot drift away
from the schema it checks.
-}
replyOf : Bool -> AS.Document -> String -> E.Value
replyOf ok doc error =
    let
        profiles =
            case D.decodeValue (D.field "profiles" D.value) (AS.encode doc) of
                Ok v ->
                    v

                Err _ ->
                    E.null
    in
    E.object
        [ ( "ok", E.bool ok )
        , ( "active", E.string doc.active )
        , ( "profiles", profiles )
        , ( "error", E.string error )
        ]


topKeys : E.Value -> List String
topKeys value =
    case D.decodeValue (D.dict D.value) value of
        Ok d ->
            d |> Dict.keys |> List.sort

        Err _ ->
            []


profileKeys : E.Value -> List String
profileKeys value =
    case D.decodeValue (D.field "profiles" (D.list (D.dict D.value))) value of
        Ok rows ->
            rows |> List.head |> Maybe.map (\r -> r |> Dict.keys |> List.sort) |> Maybe.withDefault []

        Err _ ->
            []


{-| The kinds a transition asked for, as plain data, so a test can compare a whole
effect set with one `Expect.equal` instead of picking it apart.
-}
effectKinds : List AS.Action -> List String
effectKinds actions =
    List.map
        (\action ->
            case action of
                Get ->
                    "Get"

                Sync _ ->
                    "Sync"
        )
        actions


{-| The single `Sync` payload, if that is all a transition wanted.
-}
syncOf : List AS.Action -> Maybe String
syncOf actions =
    case actions of
        [ AS.Sync config ] ->
            Just config

        _ ->
            Nothing


writtenActive : List AS.Action -> Maybe String
writtenActive actions =
    case syncOf actions of
        Just s ->
            D.decodeString (D.field "active" D.string) s |> Result.toMaybe

        Nothing ->
            Nothing


writtenProfileIds : List AS.Action -> Maybe (List String)
writtenProfileIds actions =
    case syncOf actions of
        Just s ->
            D.decodeString (D.field "profiles" (D.list (D.field "id" D.string))) s |> Result.toMaybe

        Nothing ->
            Nothing


writtenFirst : String -> List AS.Action -> Maybe String
writtenFirst field actions =
    case syncOf actions of
        Just s ->
            D.decodeString (D.field "profiles" (D.list (D.field field D.string))) s
                |> Result.withDefault []
                |> List.head

        Nothing ->
            Nothing



{-| Everything, from one entry point: an extra `Test` export would also be
collected (verified), but a single aggregate cannot silently stop running.
-}
tests : Test
tests =
    describe "App/AsrConfig — the ASR profile store"
        [ vocabularyTests
        , defaultModelTests
        , schemaTests
        , lifecycleTests
        , formTests
        , listTests
        , saveTests
        , adoptTests
        ]


vocabularyTests : Test
vocabularyTests =
    describe "App/AsrConfig — protocolDisplayName"
        [ test "transcriptions → OpenAI-compatible multipart upload" <|
            \_ ->
                AS.protocolDisplayName "transcriptions"
                    |> Expect.equal "OpenAI /audio/transcriptions (multipart upload)"
        , test "chat_completions → OpenAI standard chat completions" <|
            \_ ->
                AS.protocolDisplayName "chat_completions"
                    |> Expect.equal "OpenAI /chat/completions (JSON + api-key)"
        , test "step_audio → StepFun StepAudio raw PCM + SSE" <|
            \_ ->
                AS.protocolDisplayName "step_audio"
                    |> Expect.equal "StepAudio (StepFun, raw PCM + SSE)"
        , test "unknown protocol value is shown verbatim, not as transcriptions" <|
            \_ ->
                AS.protocolDisplayName "typo_protocol"
                    |> Expect.equal "typo_protocol (unknown protocol)"
        ]


{-| The protocol-specific model default. A StepAudio profile left on the
transcriptions default made StepFun transcribe with a whisper model id, and the
backend only applies its own default when the field is EMPTY — so the form carries
the per-protocol value (`AS.setProtocol`).
-}
defaultModelTests : Test
defaultModelTests =
    describe "App/AsrConfig — defaultModel per protocol"
        [ test "step_audio defaults to the StepFun ASR model" <|
            \_ ->
                AS.defaultModel "step_audio" |> Expect.equal "stepaudio-2.5-asr"
        , test "transcriptions and chat_completions default to whisper-1" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal "whisper-1" (AS.defaultModel "transcriptions")
                    , \_ -> Expect.equal "whisper-1" (AS.defaultModel "chat_completions")
                    ]
                    ()
        , test "switching protocol swaps a model that is still a default" <|
            \_ ->
                AS.edit "p1" (docOf [ profile "p1" ]) AS.emptyEditor
                    |> AS.setProtocol "step_audio"
                    |> .model
                    |> Expect.equal "stepaudio-2.5-asr"
        , test "an empty model is filled with the new protocol's default too" <|
            \_ ->
                let
                    ed =
                        AS.emptyEditor
                in
                { ed | model = "   " } |> AS.setProtocol "step_audio" |> .model |> Expect.equal "stepaudio-2.5-asr"
        , test "a model the user typed is never clobbered" <|
            \_ ->
                let
                    ed =
                        AS.emptyEditor
                in
                { ed | model = "my-asr" } |> AS.setProtocol "step_audio" |> .model |> Expect.equal "my-asr"
        , test "…and the same through the real message, so the arm is wired" <|
            \_ ->
                let
                    ed =
                        AS.emptyEditor

                    ( m, _ ) =
                        App.Update.update (AT.SetAsrProtocol "step_audio") (withEditor { ed | model = "my-asr", inForm = True })
                in
                Expect.all
                    [ \mm -> Expect.equal "my-asr" mm.asrConfigEditor.model
                    , \mm -> Expect.equal "step_audio" mm.asrConfigEditor.protocol
                    , \mm -> Expect.equal True mm.asrConfigEditor.inForm
                    ]
                    m
        ]



-- ─── the schema ────────────────────────────────────────────────────

schemaTests : Test
schemaTests =
    describe "App/AsrConfig — what a save writes back"
        [ test "the document states active and profiles, and nothing else" <|
            \_ ->
                AS.encode (docOf [ profile "p1" ])
                    |> topKeys
                    |> Expect.equal [ "active", "profiles" ]
        , test "a profile states all seven fields — an omitted one is DELETED from the file" <|
            \_ ->
                AS.encode (docOf [ profile "p1" ])
                    |> profileKeys
                    |> Expect.equal
                        [ "api_key"
                        , "id"
                        , "language"
                        , "model"
                        , "name"
                        , "protocol"
                        , "url"
                        ]
        , test "every value survives encode → reply → decode" <|
            \_ ->
                let
                    p1 =
                        profile "p1"

                    p2 =
                        profile "p2"

                    doc =
                        docOf
                            [ p1
                            , { p2 | protocol = "step_audio", language = "zh", apiKey = "", model = "stepaudio-2.5-asr" }
                            ]

                    adopted =
                        AS.decodeReply (replyOf True doc "") |> Maybe.map AS.document
                in
                Expect.equal (Just doc) adopted
        , test "a profile missing a field is refused whole, not half-adopted" <|
            \_ ->
                -- Deliberate strictness. The backend decodes asr.conf into a typed
                -- struct and re-serialises every field, so a key going missing
                -- means the shape changed — guessing through it would write the
                -- guess back over the user's file.
                let
                    raw =
                        E.object
                            [ ( "ok", E.bool True )
                            , ( "active", E.string "p1" )
                            , ( "profiles", E.list identity [ E.object [ ( "id", E.string "p1" ) ] ] )
                            , ( "error", E.string "" )
                            ]
                in
                Expect.equal Nothing (AS.decodeReply raw)
        ]



-- ─── open / close ──────────────────────────────────────────────────

lifecycleTests : Test
lifecycleTests =
    let
        blank =
            AS.emptyEditor
    in
    describe "App/AsrConfig — opening and closing"
        [ test "open shows the list, marks it loading, and asks for the file" <|
            \_ ->
                let
                    ( ed, actions ) =
                        AS.open
                in
                Expect.all
                    [ \e -> Expect.equal True e.show
                    , \e -> Expect.equal True e.loading
                    , \e -> Expect.equal False e.inForm
                    , \_ -> Expect.equal [ "Get" ] (effectKinds actions)
                    ]
                    ed
        , test "close refuses while a sync is in flight" <|
            \_ ->
                let
                    wedged =
                        { blank | show = True, syncing = True }
                in
                AS.close wedged |> Expect.equal wedged
        , test "close refuses from inside the form, edits and all" <|
            \_ ->
                { blank | show = True, inForm = True, url = "half-typed" }
                    |> AS.close
                    |> .url
                    |> Expect.equal "half-typed"
        , test "close from the list clears the whole editor" <|
            \_ ->
                { blank | show = True, error = Just "stale", confirmDelete = Just "p1" }
                    |> AS.close
                    |> Expect.equal AS.emptyEditor
        ]



-- ─── the form ──────────────────────────────────────────────────────

formTests : Test
formTests =
    let
        board =
            docOf [ profile "p1", profile "p2" ]

        blank =
            AS.emptyEditor
    in
    describe "App/AsrConfig — the form"
        [ test "add opens a NEW profile, so a save appends" <|
            \_ ->
                Expect.all
                    [ \e -> Expect.equal True e.inForm
                    , \e -> Expect.equal Nothing e.editingId
                    , \e -> Expect.equal AS.defaultProtocol e.protocol
                    ]
                    AS.add
        , test "edit pre-fills every field from the profile" <|
            \_ ->
                AS.edit "p2" board blank
                    |> Expect.all
                        [ \e -> Expect.equal (Just "p2") e.editingId
                        , \e -> Expect.equal "Local p2" e.name
                        , \e -> Expect.equal "key-p2" e.apiKey
                        , \e -> Expect.equal "http://127.0.0.1:8080/v1/audio/transcriptions" e.url
                        ]
        , test "edit of an id the file does not have changes nothing" <|
            \_ ->
                AS.edit "gone" board blank |> Expect.equal blank
        , test "back returns to the list and drops the unsaved edits" <|
            \_ ->
                AS.edit "p1" board blank
                    |> AS.setName "rewritten"
                    |> (\_ -> AS.back)
                    |> Expect.all
                        [ \e -> Expect.equal True e.show
                        , \e -> Expect.equal False e.inForm
                        , \e -> Expect.equal Nothing e.editingId
                        , \e -> Expect.equal "" e.name
                        ]
        , test "typing in a field clears the error line" <|
            \_ ->
                { blank | error = Just "bad url" } |> AS.setName "x" |> .error |> Expect.equal Nothing
        ]



-- ─── active and delete ─────────────────────────────────────────────

listTests : Test
listTests =
    let
        board =
            docOf [ profile "p1", profile "p2" ]

        blank =
            AS.emptyEditor
    in
    describe "App/AsrConfig — the active profile and deletion"
        [ test "setActive writes the new active but does not claim it locally" <|
            \_ ->
                -- The document is adopted from the reply, so a failed write cannot
                -- leave the UI pointing at a profile the backend will not use.
                let
                    ( ed, actions ) =
                        AS.setActive "p2" board blank
                in
                Expect.all
                    [ \_ -> Expect.equal True ed.syncing
                    , \_ -> Expect.equal (Just "p2") (writtenActive actions)
                    , \_ -> Expect.equal "p1" board.active
                    ]
                    ()
        , test "delete arms the confirm; the same row again disarms it" <|
            \_ ->
                let
                    armed =
                        AS.delete "p1" blank

                    disarmed =
                        AS.delete "p1" armed

                    other =
                        AS.delete "p2" armed
                in
                Expect.all
                    [ \_ -> Expect.equal (Just "p1") armed.confirmDelete
                    , \_ -> Expect.equal Nothing disarmed.confirmDelete
                    , \_ -> Expect.equal (Just "p2") other.confirmDelete
                    ]
                    ()
        , test "deleteConfirm with nothing armed writes NOTHING" <|
            \_ ->
                -- The arm is reachable from a keyboard path too, so the guard has
                -- to live in the transition, not at the call site.
                Expect.equal [] (AS.deleteConfirm board blank |> Tuple.second)
        , test "deleteConfirm drops that profile and keeps the rest, in order" <|
            \_ ->
                let
                    armed =
                        { blank | confirmDelete = Just "p1" }

                    ( ed, actions ) =
                        AS.deleteConfirm board armed
                in
                Expect.all
                    [ \e -> Expect.equal True e.syncing
                    , \e -> Expect.equal Nothing e.confirmDelete
                    , \_ -> Expect.equal (Just [ "p2" ]) (writtenProfileIds actions)
                    , \_ -> Expect.equal (Just "p1") (writtenActive actions)
                    ]
                    ed
        , test "deleteCancel disarms without writing" <|
            \_ ->
                let
                    armed =
                        { blank | confirmDelete = Just "p1" }
                in
                AS.deleteCancel armed
                    |> AS.deleteConfirm board
                    |> Tuple.second
                    |> Expect.equal []
        ]



-- ─── save ──────────────────────────────────────────────────────────

saveTests : Test
saveTests =
    let
        board =
            docOf [ profile "p1", profile "p2" ]

        blank =
            AS.emptyEditor

        form fields =
            fields blank

        typed =
            form
                (\e ->
                    { e
                        | show = True
                        , inForm = True
                        , name = "  Renamed  "
                        , url = "  https://api.example.com/v1/audio/transcriptions  "
                        , apiKey = "  k  "
                        , model = "  m  "
                        , language = "  zh  "
                    }
                )
    in
    describe "App/AsrConfig — saving"
        [ test "an empty url is refused with a message, and writes nothing" <|
            \_ ->
                let
                    ( ed, actions ) =
                        AS.save board { blank | url = "   " }
                in
                Expect.all
                    [ \e -> Expect.equal True (String.contains "Endpoint URL" (Maybe.withDefault "" e.error))
                    , \_ -> Expect.equal [] actions
                    , \e -> Expect.equal False e.syncing
                    ]
                    ed
        , test "a new profile is appended with an empty id, which the backend fills in" <|
            \_ ->
                let
                    ( _, actions ) =
                        AS.save board { blank | url = "http://h/v1/audio/transcriptions" }
                in
                Expect.all
                    [ \_ -> Expect.equal (Just [ "p1", "p2", "" ]) (writtenProfileIds actions)
                    , \_ -> Expect.equal (Just "p1") (writtenActive actions)
                    ]
                    ()
        , test "an existing profile is replaced in place, order kept" <|
            \_ ->
                let
                    ( _, actions ) =
                        AS.save board { typed | editingId = Just "p1" }
                in
                Expect.equal (Just [ "p1", "p2" ]) (writtenProfileIds actions)
        , test "every field is trimmed on the way out" <|
            \_ ->
                let
                    ( _, actions ) =
                        AS.save board { typed | editingId = Just "p1" }
                in
                Expect.all
                    [ \_ -> Expect.equal (Just "Renamed") (writtenFirst "name" actions)
                    , \_ -> Expect.equal (Just "https://api.example.com/v1/audio/transcriptions") (writtenFirst "url" actions)
                    , \_ -> Expect.equal (Just "k") (writtenFirst "api_key" actions)
                    , \_ -> Expect.equal (Just "m") (writtenFirst "model" actions)
                    , \_ -> Expect.equal (Just "zh") (writtenFirst "language" actions)
                    ]
                    ()
        , test "a save marks the editor syncing, which is what blocks closing" <|
            \_ ->
                let
                    ( ed, actions ) =
                        AS.save board { typed | editingId = Just "p1" }
                in
                Expect.all
                    [ \e -> Expect.equal True e.syncing
                    , \e -> Expect.equal Nothing e.error
                    , \_ -> Expect.equal True (syncOf actions /= Nothing)
                    ]
                    ed
        , test "the write carries the whole list, not a patch" <|
            \_ ->
                -- `sync_asr_config` replaces the file: a payload with only the
                -- edited row would delete the others.
                let
                    ( _, actions ) =
                        AS.save board { typed | editingId = Just "p1" }
                in
                Expect.equal 2 (actions |> syncOf |> Maybe.andThen (\s -> D.decodeString (D.field "profiles" (D.list D.value)) s |> Result.toMaybe) |> Maybe.map List.length |> Maybe.withDefault 0)
        ]



-- ─── adopting replies ──────────────────────────────────────────────

adoptTests : Test
adoptTests =
    let
        board =
            docOf [ profile "p1" ]

        blank =
            let
                e =
                    AS.emptyEditor
            in
            { e | show = True, loading = True }
    in
    describe "App/AsrConfig — adopting a reply"
        [ test "a good read replaces the document and clears loading" <|
            \_ ->
                let
                    reply =
                        AS.decodeReply (replyOf True (docOf [ profile "p1", profile "p2" ]) "")
                            |> Maybe.withDefault { ok = False, active = "", profiles = [], error = "fixture" }

                    ( doc, ed ) =
                        AS.adoptGet reply board blank
                in
                Expect.all
                    [ \_ -> Expect.equal 2 (List.length doc.profiles)
                    , \e -> Expect.equal False e.loading
                    , \e -> Expect.equal Nothing e.error
                    ]
                    ed
        , test "a failed read keeps the document, shows the error, and stops loading" <|
            \_ ->
                let
                    reply =
                        { ok = False, active = "", profiles = [], error = "boom" }

                    ( doc, ed ) =
                        AS.adoptGet reply board blank
                in
                Expect.all
                    [ \_ -> Expect.equal board doc
                    , \e -> Expect.equal (Just "boom") e.error
                    , \e -> Expect.equal False e.loading
                    ]
                    ed
        , test "a good write lands on the list and adopts the id the backend generated" <|
            \_ ->
                let
                    p1 =
                        profile "p1"

                    saved =
                        docOf [ { p1 | id = "gen-7" } ]

                    reply =
                        AS.decodeReply (replyOf True saved "")
                            |> Maybe.withDefault { ok = False, active = "", profiles = [], error = "fixture" }

                    formEd =
                        { blank | loading = False, inForm = True, syncing = True }

                    ( doc, ed ) =
                        AS.adoptSync reply board formEd
                in
                Expect.all
                    [ \_ -> Expect.equal [ "gen-7" ] (List.map .id doc.profiles)
                    , \e -> Expect.equal False e.inForm
                    , \e -> Expect.equal True e.show
                    ]
                    ed
        , test "a failed write unsticks syncing so the overlay can close again" <|
            \_ ->
                let
                    reply =
                        { ok = False, active = "", profiles = [], error = "disk full" }

                    formEd =
                        { blank | syncing = True, inForm = True }

                    ( doc, ed ) =
                        AS.adoptSync reply board formEd
                in
                Expect.all
                    [ \_ -> Expect.equal board doc
                    , \e -> Expect.equal False e.syncing
                    , \e -> Expect.equal (Just "disk full") e.error
                    ]
                    ed
        ]
