module App.AsrConfig exposing
    ( Profile, Document, Editor, Action(..)
    , emptyDocument, emptyEditor
    , Reply, decodeReply, encode, encodeString, document
    , defaultProtocol, protocolDisplayName, defaultModel
    , open, close, add, edit, back
    , setActive, delete, deleteConfirm, deleteCancel
    , setName, setProtocol, setUrl, setApiKey, setModel, setLanguage
    , save, adoptGet, adoptSync
    , find
    )

{-| The ASR profile store: `~/.alayaface/asr.conf`, its editor state, and every
transition that overlay makes.

This is the third config-document module, and it exists for the same reason as
`Session.ModelConfig` (`model.conf`) and `App.UiConfig` (`ui.conf`):
`sync_asr_config` REPLACES the file, so whatever this module does not encode does
not merely go missing from the form — it is deleted from the user's config on the
next save. The field list below is therefore load-bearing in both directions, and
it is the whole reason `decodeReply` and `encode` live here rather than beside the
case arms that use them.


== Which half of the hazard this closes

`model.conf` and `ui.conf` each have an escape hatch for keys this build does not
model (`ModelConfig` carries every field AlayaCore publishes; `UiConfig` round
trips unknown *top-level* keys through `Document.extras`). `asr.conf` has none:
all three implementations agree on exactly seven per-profile fields and two
document fields, so a field added on one side is deleted by the other. That is
what `scripts/check-backend-parity.sh` watches for the protocol names and the
per-protocol default model — and what it does NOT watch for the field list, which
is why the table is stated here in one place instead of spread over a decoder, an
encoder and two backends.

The decode is strict (`D.field`, no defaults) and that is deliberate: the backend
decodes into a typed struct and re-serialises every field, so a reply missing one
is a shape change and not something to guess through. The arms that cannot decode
leave the model alone, which is why `loading`/`syncing` are only ever cleared by
a reply that parsed — see the note on `decodeReply`.


== Shape

Pure by the rule in AGENTS.md: it never imports `App.Types`, so `Model`'s
`asrConfig` / `asrConfigEditor` fields may be typed by this module without a
cycle. Effects are returned as `Action` data, and `App.Update` is the only place
that turns one into a port call.
-}

import Json.Decode as D
import Json.Encode as E


-- ─── The document ──────────────────────────────────────────────────

{-| One ASR endpoint profile. Seven fields, and all seven are written back on
every save — see the module comment before adding or removing one.
-}
type alias Profile =
    { id : String

    -- Display name shown in the ASR config list.
    , name : String

    -- Wire protocol; see `defaultProtocol` and `protocolDisplayName`.
    , protocol : String

    -- FULL endpoint address, used verbatim (nothing is appended).
    , url : String

    -- API key. Empty means no auth header, which local endpoints usually want.
    , apiKey : String

    -- Model id passed to the endpoint; empty means the backend's own default.
    , model : String

    -- Transcription language hint, "auto" when unset.
    , language : String
    }


{-| The whole file: which profile `asr_transcribe` uses, and the profiles.
-}
type alias Document =
    { active : String
    , profiles : List Profile
    }


emptyDocument : Document
emptyDocument =
    { active = ""
    , profiles = []
    }


{-| The overlay's view state: a profile LIST (entered from the system menu) or
the add/edit FORM. `editingId = Nothing` in the form means a new profile.

`syncing` is why `close` refuses: a write in flight would otherwise be answered
by a reply nobody is listening to any more.
-}
type alias Editor =
    { show : Bool
    , loading : Bool
    , syncing : Bool
    , inForm : Bool
    , editingId : Maybe String
    , confirmDelete : Maybe String
    , name : String
    , protocol : String
    , url : String
    , apiKey : String
    , model : String
    , language : String
    , error : Maybe String
    }


emptyEditor : Editor
emptyEditor =
    { show = False
    , loading = False
    , syncing = False
    , inForm = False
    , editingId = Nothing
    , confirmDelete = Nothing
    , name = ""
    , protocol = defaultProtocol
    , url = ""
    , apiKey = ""
    , model = defaultModel defaultProtocol
    , language = "auto"
    , error = Nothing
    }


{-| What a transition wants from the outside world. Data, not commands: the
ports stay in `App.Update`, which is the only module that can send them.
-}
type Action
    = Get
    | Sync String



-- ─── The protocol vocabulary ───────────────────────────────────────

{-| The protocol a fresh profile starts on, and the one the backend assumes when
a file leaves the field empty.
-}
defaultProtocol : String
defaultProtocol =
    "transcriptions"


{-| Human label for a protocol value, used by both the list rows and the
edit-form dropdown (one source of truth). Unknown values (e.g. a hand-edited
asr.conf) are shown verbatim instead of being silently mislabeled as
"transcriptions".
-}
protocolDisplayName : String -> String
protocolDisplayName protocol =
    case protocol of
        "chat_completions" ->
            "OpenAI /chat/completions (JSON + api-key)"

        "step_audio" ->
            "StepAudio (StepFun, raw PCM + SSE)"

        "transcriptions" ->
            "OpenAI /audio/transcriptions (multipart upload)"

        other ->
            other ++ " (unknown protocol)"


{-| The model id the backend applies when the model field is left empty, per wire
protocol (mirrors Go's `DefaultAsrModel` / Rust's `default_asr_model`). The edit
form swaps this in when the protocol changes, so picking StepAudio does not keep
sending a whisper model id to StepFun — the backend default alone cannot fix that,
because the form prefills "whisper-1" (non-empty) and normalization keeps explicit
values.

`scripts/check-backend-parity.sh` compares this table between the two backends but
NOT against here, so a third change is a manual one: all three must move together.
-}
defaultModel : String -> String
defaultModel protocol =
    case protocol of
        "step_audio" ->
            "stepaudio-2.5-asr"

        _ ->
            "whisper-1"



-- ─── The schema: read and write the whole file ─────────────────────

{-| A `get_asr_config` / `sync_asr_config` reply. Both commands answer with the
same shape, which is why one decoder serves both arms — the transport layer
synthesises all four keys on success AND on failure, so the strict decode below is
about the backend changing shape, not about a network error.
-}
type alias Reply =
    { ok : Bool
    , active : String
    , profiles : List Profile
    , error : String
    }


profileDecoder : D.Decoder Profile
profileDecoder =
    D.map7 Profile
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "protocol" D.string)
        (D.field "url" D.string)
        (D.field "api_key" D.string)
        (D.field "model" D.string)
        (D.field "language" D.string)


replyDecoder : D.Decoder Reply
replyDecoder =
    D.map4
        (\ok active profiles error ->
            { ok = ok, active = active, profiles = profiles, error = error }
        )
        (D.field "ok" D.bool)
        (D.field "active" D.string)
        (D.field "profiles" (D.list profileDecoder))
        (D.field "error" D.string)


{-| Decode one of the two config replies. `Nothing` means the body was not a
reply at all, and the caller must then leave the model — and its `loading` /
`syncing` flags — exactly as they are.
-}
decodeReply : E.Value -> Maybe Reply
decodeReply raw =
    D.decodeValue replyDecoder raw |> Result.toMaybe


profileEncoder : Profile -> E.Value
profileEncoder p =
    E.object
        [ ( "id", E.string p.id )
        , ( "name", E.string p.name )
        , ( "protocol", E.string p.protocol )
        , ( "url", E.string p.url )
        , ( "api_key", E.string p.apiKey )
        , ( "model", E.string p.model )
        , ( "language", E.string p.language )
        ]


{-| Encode the full document for `sync_asr_config`. The command replaces the
file, so this is the complete schema and not a patch.
-}
encode : Document -> E.Value
encode doc =
    E.object
        [ ( "active", E.string doc.active )
        , ( "profiles", E.list profileEncoder doc.profiles )
        ]


{-| The JSON string a `Sync` action carries. Kept private to the transitions so
no caller can send a document it assembled itself.
-}
encodeString : Document -> String
encodeString doc =
    E.encode 0 (encode doc)


{-| A reply as a document, for the arms that adopt it.
-}
document : Reply -> Document
document r =
    { active = r.active
    , profiles = r.profiles
    }


{-| Look a profile up by id. The id is generated by the backend when a new profile
is saved with an empty one, which is why `save` sends `id = ""` and the list is
re-adopted from the reply rather than appended locally.
-}
find : String -> List Profile -> Maybe Profile
find profileId profiles =
    List.filter (\p -> p.id == profileId) profiles |> List.head



-- ─── Transitions ───────────────────────────────────────────────────
--
-- Each one is the whole decision made by one `App.Update` case arm. They take
-- what they read (usually the document, sometimes only the editor) and return
-- what changed plus the effects wanted, so the arm that calls them is an
-- assignment, not a branch.


{-| Open the overlay from the system menu: list view, and a read of the file to
fill it.
-}
open : ( Editor, List Action )
open =
    ( { emptyEditor | show = True, loading = True }, [ Get ] )


{-| Close the overlay. Two refusals, both deliberate: never while a write is in
flight, and never from the form (the form's Back button is what returns to the
list, so a close there would discard edits the user has not been asked about).

Returns the editor unchanged when refusing, which is what lets the arm stay a
one-liner.
-}
close : Editor -> Editor
close ed =
    if ed.syncing || ed.inForm then
        ed

    else
        emptyEditor


{-| The form for a NEW profile.
-}
add : Editor
add =
    { emptyEditor | show = True, inForm = True, editingId = Nothing }


{-| The form pre-filled from an existing profile. An unknown id (the file changed
under the click) leaves the editor alone.
-}
edit : String -> Document -> Editor -> Editor
edit profileId doc ed =
    case find profileId doc.profiles of
        Just p ->
            { emptyEditor
                | show = True
                , inForm = True
                , editingId = Just p.id
                , name = p.name
                , protocol = p.protocol
                , url = p.url
                , apiKey = p.apiKey
                , model = p.model
                , language = p.language
            }

        Nothing ->
            ed


{-| Form → list. Unsaved edits are discarded, and the list view is still shown.
-}
back : Editor
back =
    { emptyEditor | show = True }


{-| Switch which profile transcription uses. The active id is written through the
file, not kept locally, so a failed write cannot leave the UI claiming a profile
is active that the backend will not use.
-}
setActive : String -> Document -> Editor -> ( Editor, List Action )
setActive profileId doc ed =
    ( { ed | syncing = True, error = Nothing }
    , [ Sync (encodeString { doc | active = profileId }) ]
    )


{-| First click on a row's Delete arms the confirm; the same click again disarms
it. Two steps because the row is also the list's only Delete affordance, and a
mis-click on a config file should not be irreversible.
-}
delete : String -> Editor -> Editor
delete profileId ed =
    { ed
        | confirmDelete =
            if ed.confirmDelete == Just profileId then
                Nothing

            else
                Just profileId
    }


{-| The armed confirm, pressed: drop the profile and write the remaining list.
Without a pending confirm this writes nothing — the arm is reachable from a
keyboard path as well as a click, so the guard belongs here and not at the call
site.
-}
deleteConfirm : Document -> Editor -> ( Editor, List Action )
deleteConfirm doc ed =
    case ed.confirmDelete of
        Just profileId ->
            ( { ed | syncing = True, confirmDelete = Nothing, error = Nothing }
            , [ Sync (encodeString { doc | profiles = List.filter (\p -> p.id /= profileId) doc.profiles }) ]
            )

        Nothing ->
            ( ed, [] )


deleteCancel : Editor -> Editor
deleteCancel ed =
    { ed | confirmDelete = Nothing }


{-| The six form fields. Each clears the error line: an error that outlives the
keystroke that would have fixed it reads as though the new value is also bad.
-}
setName : String -> Editor -> Editor
setName val ed =
    { ed | name = val, error = Nothing }


{-| Changing the protocol swaps the model id, but only while the field still
holds a default (or is empty). The model id is protocol-specific and the backend
applies its own default only when the field is EMPTY — so switching a prefilled
form to StepAudio used to keep sending "whisper-1" to StepFun. A model the user
typed themselves is left alone.
-}
setProtocol : String -> Editor -> Editor
setProtocol val ed =
    let
        untouched =
            String.trim ed.model == ""
                || List.member (String.trim ed.model) [ defaultModel "transcriptions", defaultModel "step_audio" ]
    in
    { ed
        | protocol = val
        , model =
            if untouched then
                defaultModel val

            else
                ed.model
        , error = Nothing
    }


setUrl : String -> Editor -> Editor
setUrl val ed =
    { ed | url = val, error = Nothing }


setApiKey : String -> Editor -> Editor
setApiKey val ed =
    { ed | apiKey = val, error = Nothing }


setModel : String -> Editor -> Editor
setModel val ed =
    { ed | model = val, error = Nothing }


setLanguage : String -> Editor -> Editor
setLanguage val ed =
    { ed | language = val, error = Nothing }


{-| Validate the form and write it: update the profile with this id, or append.

The url is the only required field, and the message spells out what "full address"
means here, because the field takes a complete endpoint and a bare host is the
mistake that produces a confusing failure two hops away.
-}
save : Document -> Editor -> ( Editor, List Action )
save doc ed =
    if String.isEmpty (String.trim ed.url) then
        ( { ed | error = Just "Endpoint URL is required (full address, e.g. http://127.0.0.1:8080/v1/audio/transcriptions)" }
        , []
        )

    else
        let
            draft =
                { id = Maybe.withDefault "" ed.editingId
                , name = String.trim ed.name
                , protocol = String.trim ed.protocol
                , url = String.trim ed.url
                , apiKey = String.trim ed.apiKey
                , model = String.trim ed.model
                , language = String.trim ed.language
                }

            profiles =
                case ed.editingId of
                    Just profileId ->
                        List.map (\p -> if p.id == profileId then draft else p) doc.profiles

                    Nothing ->
                        doc.profiles ++ [ draft ]
        in
        ( { ed | syncing = True, error = Nothing }
        , [ Sync (encodeString { doc | profiles = profiles }) ]
        )


{-| Adopt a `get_asr_config` reply. On failure the document is left alone — the
list a user is looking at is better than an empty one that could not be read.
-}
adoptGet : Reply -> Document -> Editor -> ( Document, Editor )
adoptGet r doc ed =
    if r.ok then
        ( document r, { ed | loading = False, error = Nothing } )

    else
        ( doc, { ed | loading = False, error = Just r.error } )


{-| Adopt a `sync_asr_config` reply. Success lands on the list view (the write is
done, and the reply carries the id the backend generated for a new profile), so
the form state is replaced rather than cleared field by field.
-}
adoptSync : Reply -> Document -> Editor -> ( Document, Editor )
adoptSync r doc ed =
    if r.ok then
        ( document r, back )

    else
        ( doc, { ed | syncing = False, error = Just r.error } )
