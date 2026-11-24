module Session.ModelConfig exposing
    ( Field
    , FieldKind(..)
    , fields
    , emptyDraft
    , draftFromModel
    , modelFromDraft
    , updateDraftField
    , draftProblems
    , modelInfoDecoder
    , encodeModels
    , encodeModel
    , modeledKeys
    , summaryOf
    , displayOf
    )

{-| AlayaCore's `model.conf` schema: the one place in AlayaFace that knows
which keys a model entry has, and how each is decoded, encoded and edited.

Why one module for all three: AlayaFace writes `model.conf` as a whole file
(since v19 there is no wire command that carries a model list any more), and
AlayaCore reads the file back, so an entry this module cannot express is a
line it deletes from the user's config. That is a destructive round trip:
the model keeps answering, `reasoning_field` is gone, the REASONING window
never appears again, and nothing anywhere reports it.

So these must agree, and ModelConfigTest asserts that they do:

  * `fields`               — every key gets a control in Overlay.ModelEditor,
    so nothing is saved while being invisible to the user;
  * `Field.required`       — which of those keys AlayaCore refuses an entry
    without. Saving one empty DELETES the entry (see `draftProblems`), so this
    is the second way this module can lose a model by knowing too little, and
    `scripts/check-model-schema.sh` compares the set against `validateModel` in
    both directions;
  * `modelInfoDecoder` /
    `encodeModel`          — every key survives `model_list` -> `model.conf`;
  * `modeledKeys`          — the keys above; anything outside them is
    carried verbatim in `ModelInfo.extras`, so a key AlayaCore adds later
    survives an AlayaFace edit instead of vanishing until someone
    remembers to update this file.

The limit of that: `extras` protects a key AlayaCore knows and this client
build does not yet. A key NEITHER knows cannot be preserved — AlayaCore reads
`model.conf` into its own struct, so it drops the line itself. AlayaFace must
not invent a config line the core cannot parse.

Mirror of AlayaCore's `protocol.ModelInfo` (the `:model_list` payload) and
`agent.modelConfig` (model.conf). A missing capability is never a reason to
modify AlayaCore: it is a config line, and this module is where AlayaFace
carries them.
-}

import Conf
import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Session.Types exposing (ModelDraft, ModelInfo)


-- SCHEMA


{-| How a field is edited, and what its draft text means. -}
type FieldKind
    = Text
    | Number
      -- Raw provider JSON (the `reasoning_N` request-body blocks).
    | Json
      -- A JSON array of names from a closed vocabulary — `input_modalities`.
      -- Distinct from `Json` because its emptiness MEANS something (no value
      -- = not declared, `[]` = declared empty) and its contents are values
      -- AlayaCore will refuse the entry over, so "it parses" is not enough.
    | Modalities
      -- (value, label): `value` is what the draft stores and what
      -- model.conf gets; `label` is what the row shows.
    | Choice (List ( String, String ))


type alias Field =
    { key : String
    , label : String
    , kind : FieldKind
    , placeholder : String
    , hint : String
      -- Does AlayaCore's `validateModel` refuse an entry whose value is empty?
      -- It is data rather than a special case in `draftProblems` because the
      -- consequence is per-field and severe: the file is replaced whole, and
      -- `parseModelConfig` skips entries that fail validation, so a saved entry
      -- missing one of these loads as absent and the CONFIG_MODEL_INVALID reply
      -- is the only explanation. The backend verifies the candidate before
      -- committing it (and rolls a live session back on refusal), but refusing
      -- at Save is what keeps the form from handing the user that error at all.
      --
      -- Mirrored from `model_manager.go:validateModel` (the three are
      -- `protocol_type`, `base_url`, `model_name`). `name` is NOT required
      -- there, and this table does not invent a stricter rule than the core:
      -- a nameless entry is still a working entry, so `displayOf` exists to
      -- keep it visible in a list instead.
    , required : Bool
    , get : ModelDraft -> String
    , set : String -> ModelDraft -> ModelDraft
    }


{-| The values `input_modalities` accepts, exactly spelled and case-sensitive.

A copy of AlayaCore's `protocol.PlaneKinds(protocol.PlaneUser)`
(`internal/protocol/kinds.go`): the five content kinds a user message may
carry, which is also the set `validateModel` checks against, so a value outside
it makes the core SKIP the entry. There is no sixth: `reasoning` is an
assistant-side output kind and not an input at all.

This list is the one thing here the schema check cannot see — it diffs key
NAMES, not value vocabularies — so it exists once, with its source named, and
`modalitiesProblem` is the only reader.
-}
modalityVocabulary : List String
modalityVocabulary =
    [ "text", "image", "video", "audio", "document" ]


{-| The model.conf keys AlayaFace models and edits, in display order.

`id` is absent on purpose: AlayaCore assigns it at runtime (`config:"-"`),
so it is neither a config line nor an input.
-}
fields : List Field
fields =
    [ field "name" Text "Name" "MyModel"
        "Display name; must be unique in the list."
        .name
        (\v d -> { d | name = v })
    , requiredChoice "protocol_type" "Protocol Type" "Wire protocol of the endpoint."
        [ ( "openai", "openai" )
        , ( "anthropic", "anthropic" )
        ]
        .protocolType
        (\v d -> { d | protocolType = v })
    , requiredField "base_url" Text "Base URL" "https://api.openai.com/v1"
        "API server URL the entry talks to."
        .baseUrl
        (\v d -> { d | baseUrl = v })
    , field "api_key" Text "API Key" "sk-..."
        ""
        .apiKey
        (\v d -> { d | apiKey = v })
    , requiredField "model_name" Text "Model Name" "gpt-4o"
        "Model identifier sent to the API."
        .modelName
        (\v d -> { d | modelName = v })
    , field "context_limit" Number "Context Limit" "0"
        "Maximum context in tokens; 0 = unlimited."
        .contextLimit
        (\v d -> { d | contextLimit = v })
    , field "max_tokens" Number "Max Tokens" "0"
        "Maximum output tokens; 0 = provider default."
        .maxTokens
        (\v d -> { d | maxTokens = v })
    , field "reasoning_field" Text "Reasoning Field" "reasoning_content"
        "Response key carrying reasoning text — OpenAI protocol only. Empty = reasoning_content (DeepSeek, GLM, MiniMax, Qwen); use reasoning for vLLM and OpenRouter."
        .reasoningField
        (\v d -> { d | reasoningField = v })
    , field "reasoning_0" Json "Reasoning JSON · Off"
        "e.g. {\"thinking\":{\"type\":\"disabled\"}}"
        "Provider JSON merged into the request body at reasoning level Off. Empty = send nothing."
        .reasoning0
        (\v d -> { d | reasoning0 = v })
    , field "reasoning_1" Json "Reasoning JSON · Balanced"
        "e.g. {\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"high\"}"
        "Same, at level Balanced."
        .reasoning1
        (\v d -> { d | reasoning1 = v })
    , field "reasoning_2" Json "Reasoning JSON · Deep"
        "e.g. {\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"max\"}"
        "Same, at level Deep."
        .reasoning2
        (\v d -> { d | reasoning2 = v })
    , choice "serial_tool_calls" "Tool Calls"
        "Serial is for models and servers with no notion of parallel tool calls. For an OpenAI endpoint it also asks the server not to parallelize."
        [ ( "false", "Concurrent (default)" )
        , ( "true", "Serial — one at a time, in order" )
        ]
        .serialToolCalls
        (\v d -> { d | serialToolCalls = v })
    , modalities "input_modalities" "Input Modalities" "[\"text\",\"image\"]"
        ("Media this model accepts, as a JSON array from "
            ++ String.join ", " modalityVocabulary
            ++ ". Empty = not declared, so the protocol decides; [] = no media, which reads the same as [\"text\"]."
        )
        .inputModalities
        (\v d -> { d | inputModalities = v })
    ]


field : String -> FieldKind -> String -> String -> String -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
field key kind label placeholderText hint get set =
    { key = key
    , label = label
    , kind = kind
    , placeholder = placeholderText
    , hint = hint
    , required = False
    , get = get
    , set = set
    }


{-| A `field` whose emptiness makes AlayaCore drop the whole entry. See
`Field.required`.

The `let` is not ceremony: `{ field a b c | required = True }` is a parse error
in Elm (`docs/update-slices.md` records it), because the record-update syntax
needs a variable, not an application.
-}
requiredField : String -> FieldKind -> String -> String -> String -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
requiredField key kind label placeholderText hint get set =
    let
        f =
            field key kind label placeholderText hint get set
    in
    { f | required = True }


choice : String -> String -> String -> List ( String, String ) -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
choice key label hint options get set =
    field key (Choice options) label "" hint get set


{-| The `input_modalities` control. Not a `choice`: the value is a SET, it may
be empty in two different ways (undeclared and `[]`), and the file spells it as
a JSON array, so it is edited as that text.

The name deliberately does not begin with `required`: `validateModel` does not
require the key, and a name the schema check reads as "the core requires this"
would refuse saves the core accepts.
-}
modalities : String -> String -> String -> String -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
modalities key label placeholderText hint get set =
    field key Modalities label placeholderText hint get set


{-| A `choice` whose key AlayaCore requires. Separate from `choice` because the
two facts are independent: `serial_tool_calls` is a control that can never hold
an empty value AND is optional in `model.conf` (absent = false), so "the control
cannot be blank" must not be read as "the core requires it" — that
conflation would refuse saves the core accepts.

The naming is load-bearing, not stylistic: `scripts/check-model-schema.sh`
treats any helper in `fields` whose name begins with `required` as the client
saying "AlayaCore requires this key", and compares that set against
`validateModel`.
-}
requiredChoice : String -> String -> String -> List ( String, String ) -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
requiredChoice key label hint options get set =
    let
        f =
            choice key label hint options get set
    in
    { f | required = True }


{-| Keys AlayaFace models — the complement of what `extras` carries. -}
modeledKeys : List String
modeledKeys =
    "id" :: List.map .key fields


{-| Drafts carry text; the key is the model.conf name. An unknown key is
ignored rather than invented: the schema is closed here, not in the view.
-}
updateDraftField : String -> String -> ModelDraft -> ModelDraft
updateDraftField key value draft =
    case List.filter (\f -> f.key == key) fields |> List.head of
        Just f ->
            f.set value draft

        Nothing ->
            draft


emptyDraft : ModelDraft
emptyDraft =
    { id = 0
    , name = ""
    , protocolType = "openai"
    , baseUrl = ""
    , apiKey = ""
    , modelName = ""
    , contextLimit = "0"
    , maxTokens = "0"
    , reasoningField = ""
    , reasoning0 = ""
    , reasoning1 = ""
    , reasoning2 = ""
    , serialToolCalls = "false"
    , inputModalities = ""
    , extras = Dict.empty
    }


-- ITEM <-> DRAFT


draftFromModel : ModelInfo -> ModelDraft
draftFromModel m =
    { id = m.id
    , name = m.name
    , protocolType = m.protocolType
    , baseUrl = m.baseUrl
    , apiKey = m.apiKey
    , modelName = m.modelName
    , contextLimit = String.fromInt m.contextLimit
    , maxTokens = String.fromInt m.maxTokens
    , reasoningField = m.reasoningField
    , reasoning0 = m.reasoning0
    , reasoning1 = m.reasoning1
    , reasoning2 = m.reasoning2
    , serialToolCalls = boolText m.serialToolCalls
    , inputModalities = m.inputModalities
    , extras = m.extras
    }


modelFromDraft : ModelDraft -> ModelInfo
modelFromDraft d =
    { id = d.id
    , name = String.trim d.name
    , protocolType = String.trim d.protocolType
    , baseUrl = String.trim d.baseUrl
    , apiKey = d.apiKey
    , modelName = String.trim d.modelName
    , contextLimit = numberOrZero d.contextLimit
    , maxTokens = numberOrZero d.maxTokens
    , reasoningField = String.trim d.reasoningField
    , reasoning0 = canonicalJson d.reasoning0
    , reasoning1 = canonicalJson d.reasoning1
    , reasoning2 = canonicalJson d.reasoning2
    , serialToolCalls = textBool d.serialToolCalls
    , inputModalities = canonicalModalities d.inputModalities
    , extras = d.extras
    }


boolText : Bool -> String
boolText value =
    if value then
        "true"

    else
        "false"


{-| Draft text -> Bool. Anything other than the exact "true" the Choice
control writes is false, which is AlayaCore's own absent-value default. -}
textBool : String -> Bool
textBool text =
    String.trim text == "true"


numberOrZero : String -> Int
numberOrZero text =
    String.trim text |> String.toInt |> Maybe.withDefault 0


{-| Canonicalize a `reasoning_N` block.

Key order and whitespace are the user's business, so parsable text is
re-emitted compactly. Unparsable text is kept as typed, which is not a
loophole: `draftProblems` blocks the save, so the only way it reaches an
item is a caller that ignored its own problems list — and echoing it back
is what lets the user see and fix it rather than lose it.
-}
canonicalJson : String -> String
canonicalJson text =
    let
        trimmed =
            String.trim text
    in
    case D.decodeString D.value trimmed of
        Ok value ->
            let
                encoded =
                    E.encode 0 value
            in
            -- model.conf has no way to say "a null block"; "" is AlayaCore's
            -- own "not configured", so a bare null collapses to it.
            if encoded == "null" then
                ""

            else
                encoded

        Err _ ->
            trimmed


{-| Canonicalize an `input_modalities` declaration.

Three shapes, and the difference between the first two is the whole point:

  * `""` — not declared. AlayaCore reads a missing line as nil, which means
    "the protocol decides", and that is what every model.conf written before
    this option means;
  * `"[]"` — declared, and empty: no media. Written back as `[]`, because
    leaving the line out would change the model from "takes no media" to "not
    declared" — a restriction widened, silently, by an unrelated edit;
  * `["text","image"]` — declared. Re-emitted compactly so the file matches
    what AlayaCore's own `json.Marshal` writes (`["text","image"]`, no
    spaces).

`null` collapses to `""` for the same reason `canonicalJson` collapses a null
block: the core reads `null` as nil, so it is the same "not declared", spelled
the same way afterwards. Unparsable text is kept as typed — `draftProblems`
blocks the save, and echoing it back is what lets the user see and fix it.
-}
canonicalModalities : String -> String
canonicalModalities text =
    let
        trimmed =
            String.trim text
    in
    case D.decodeString (D.nullable (D.list D.string)) trimmed of
        Ok Nothing ->
            ""

        Ok (Just kinds) ->
            E.encode 0 (E.list E.string kinds)

        Err _ ->
            trimmed


-- VALIDATION


{-| Per-field reasons a draft must not be saved, as (field key, message).

Two rules, and the second is the one that saves data:

  * **a required field must not be empty** (`Field.required`). Saving one is
    how a model gets deleted: `syncFromContent` skips entries that fail
    `validateModel` and `writeConfigFile` then persists the survivors, so the
    entry is gone from `model.conf` before the CONFIG_MODEL_INVALID reply arrives to
    explain why. The refusal says that in the user's terms, because "required"
    alone does not explain why a field they might want to leave blank is
    blocking a button.
  * **`Json` and `Number` values must parse**: `encodeModel` cannot represent
    unparsable provider JSON or a non-numeric token limit without inventing a
    value, and inventing one is precisely the silent data loss this module
    exists to prevent. `Choice` refuses anything outside its options, which is
    also how an empty `protocol_type` is caught.

`Overlay.ModelEditor` shows these against the offending field and disables
Save; `App.SelectorKit.editSave` refuses on them too, so neither end can be
bypassed.

Other empty text is never a problem — every optional field is empty by default,
meaning "not configured", which is what a brand-new entry starts with.
-}
draftProblems : ModelDraft -> List ( String, String )
draftProblems draft =
    let
        problem f =
            let
                value =
                    f.get draft
            in
            if f.required && String.trim value == "" then
                Just ( f.key, f.label ++ " is required — without it AlayaCore drops this model from model.conf when the list is saved." )

            else
                case f.kind of
                    Json ->
                        jsonProblem f value

                    Modalities ->
                        modalitiesProblem f value

                    Number ->
                        numberProblem f value

                    Choice options ->
                        if List.member (String.trim value) (List.map Tuple.first options) then
                            Nothing

                        else
                            Just ( f.key, f.label ++ " must be one of the listed values." )

                    Text ->
                        Nothing
    in
    List.filterMap problem fields


jsonProblem : Field -> String -> Maybe ( String, String )
jsonProblem f text =
    let
        trimmed =
            String.trim text
    in
    if trimmed == "" || trimmed == "null" then
        Nothing

    else
        case D.decodeString D.value trimmed of
            Ok _ ->
                Nothing

            Err err ->
                Just ( f.key, f.label ++ " is not valid JSON (" ++ jsonReason err ++ ")" )


{-| Why a `input_modalities` declaration would not survive AlayaCore's own
check, reported before Save instead of after the entry is gone.

Mirrors `validateModel`, and deliberately does not outdo it:

  * the value must be a JSON array of STRINGS — the core unmarshals it into
    `[]string`, and a value it cannot read is one of the FATAL parse keys, so
    the entry is skipped rather than loaded with a default;
  * every string must be in `modalityVocabulary` — the core skips the entry on
    an unknown one ("unknown input_modalities value \"vision\" ...");
  * an empty array is legal and means "no media"; `\"\"` (no declaration at
    all) is legal too, and means the protocol decides;
  * duplicates are NOT refused: `FitInputModalities` builds a set from the
    list, so `[\"text\",\"text\"]` is accepted by the core and refusing it here
    would block a save the core takes.

The message quotes the offending values and the accepted set, because the
usual misses are synonyms — `vision` for `image`, `pdf`/`file` for
`document` — and "invalid" alone leaves the user guessing which word is wrong.
-}
modalitiesProblem : Field -> String -> Maybe ( String, String )
modalitiesProblem f text =
    let
        trimmed =
            String.trim text
    in
    if trimmed == "" || trimmed == "null" then
        Nothing

    else
        case D.decodeString (D.list D.string) trimmed of
            Err _ ->
                Just
                    ( f.key
                    , f.label
                        ++ " must be a JSON array of names, e.g. [\"text\",\"image\"] — "
                        ++ String.join ", " modalityVocabulary
                        ++ "."
                    )

            Ok kinds ->
                let
                    unknown =
                        List.filter (\kind -> not (List.member kind modalityVocabulary)) kinds
                in
                if List.isEmpty unknown then
                    Nothing

                else
                    Just
                        ( f.key
                        , f.label
                            ++ " does not accept "
                            ++ String.join ", " (List.map (\k -> "\"" ++ k ++ "\"") unknown)
                            ++ " — expected some of "
                            ++ String.join ", " modalityVocabulary
                            ++ ". The entry is skipped entirely when AlayaCore rejects it."
                        )


{-| The one line of an elm/json decode failure worth showing. The full
`errorToString` output re-quotes the offending text and adds a heading,
which in a field-width line buries the reason ("Unexpected end of JSON
input") under a paragraph the user can already see in their own textarea.
-}
jsonReason : D.Error -> String
jsonReason err =
    err
        |> D.errorToString
        |> String.split "\n"
        |> List.map String.trim
        |> List.filter (\line -> not (String.isEmpty line) && not (String.startsWith "\"" line) && not (String.endsWith ":" line))
        |> List.reverse
        |> List.head
        |> Maybe.withDefault "cannot parse"


numberProblem : Field -> String -> Maybe ( String, String )
numberProblem f text =
    let
        trimmed =
            String.trim text
    in
    if trimmed == "" || String.toInt trimmed /= Nothing then
        Nothing

    else
        Just ( f.key, f.label ++ " must be a whole number of tokens (0 = default), not \"" ++ trimmed ++ "\"." )


{-| What a model entry is CALLED in a list.

`name` is what the user gave it, and AlayaCore does not require one — an entry
hand-written into `model.conf` (or created by an older client) can have a blank
`name` and still work perfectly. The lists title their rows with `name`, so a
blank one renders an empty row: present, selectable, and impossible to tell
apart from the other empty row. `model_name` is the next-best handle because it
is the string that actually identifies the endpoint, and the numeric `id` is the
last resort so a row is never blank.

This is a DISPLAY rule, deliberately not a validation rule: refusing to save a
nameless model would block editing its base URL over a field the core does not
even require. Naming it is the user's call; hiding it is not.
-}
displayOf : ModelInfo -> String
displayOf m =
    if String.trim m.name /= "" then
        m.name

    else if String.trim m.modelName /= "" then
        m.modelName

    else
        "model " ++ String.fromInt m.id


{-| One-line digest of what an entry is configured to do, for the model
list rows. Every field the row shows is one the editor can set, so a user
can see at a glance which entries use a non-default reasoning key or run
their tool calls serially, or declare no media at all, without opening
a form for every entry to find out.

Deliberately excludes `api_key` (a summary rendered in a list is not a
place for secrets) and the raw blocks' contents (too long) — it counts
them instead.
-}
summaryOf : ModelInfo -> String
summaryOf m =
    [ Just m.protocolType
    , if m.contextLimit > 0 then
        Just ("ctx " ++ String.fromInt m.contextLimit)

      else
        Nothing
    , if m.maxTokens > 0 then
        Just ("out " ++ String.fromInt m.maxTokens)

      else
        Nothing
    , if String.isEmpty m.reasoningField then
        Nothing

      else
        Just ("reasoning:" ++ m.reasoningField)
    , case List.length (List.filter (not << String.isEmpty) [ m.reasoning0, m.reasoning1, m.reasoning2 ]) of
        0 ->
            Nothing

        n ->
            Just ("json " ++ String.fromInt n)
    , if m.serialToolCalls then
        Just "serial tools"

      else
        Nothing
    , modalitiesDigest m.inputModalities
    , if Dict.isEmpty m.extras then
        Nothing

      else
        Just ("+" ++ String.fromInt (Dict.size m.extras) ++ " more")
    ]
        |> List.filterMap identity
        |> String.join " · "


{-| The media declaration for the list row, and the one place `[]` earns its
own words: "media: none" and "media: text,image" are what the user needs to
tell apart, and an undeclared entry says nothing at all (the protocol decides,
which is not a setting this row can get wrong).
-}
modalitiesDigest : String -> Maybe String
modalitiesDigest text =
    case D.decodeString (D.list D.string) text of
        Ok [] ->
            Just "media: none"

        Ok kinds ->
            Just ("media: " ++ String.join "," kinds)

        Err _ ->
            Nothing


-- CODEC: model_list JSON -> ITEM


{-| Decode one `model_list` entry.

Absent optional keys take AlayaCore's zero values, which is what every
model.conf written before them means: numbers 0, `reasoning_field` ""
(whose provider default is `reasoning_content`), `serial_tool_calls` false
(concurrent execution).
-}
modelInfoDecoder : D.Decoder ModelInfo
modelInfoDecoder =
    D.succeed ModelInfo
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "name" D.string)
        |> andMap (D.field "protocol_type" D.string)
        |> andMap (D.field "base_url" D.string)
        |> andMap (D.field "api_key" D.string)
        |> andMap (D.field "model_name" D.string)
        |> andMap (optional D.int 0 "context_limit")
        |> andMap (optional D.int 0 "max_tokens")
        |> andMap (optional D.string "" "reasoning_field")
        |> andMap (jsonBlock "reasoning_0")
        |> andMap (jsonBlock "reasoning_1")
        |> andMap (jsonBlock "reasoning_2")
        |> andMap (optional D.bool False "serial_tool_calls")
        |> andMap modalitiesDecoder
        |> andMap extrasDecoder


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap =
    D.map2 (|>)


optional : D.Decoder a -> a -> String -> D.Decoder a
optional decoder default key =
    D.maybe (D.field key decoder) |> D.map (Maybe.withDefault default)


{-| `input_modalities`, the one optional key whose EMPTY value is a
declaration rather than an absence.

AlayaCore sends `null` for "not declared" and `[]` for "declared, no media",
with no `omitempty` precisely so the two cannot be confused on the wire
(`TestInputModalitiesAbsentAndEmptyStayApart` pins that on its side). Both are
kept apart here, as JSON array text in the draft, because the file this module
writes is what decides which of them the core reads back: collapsing `[]` to
"" would widen a text-only model to one that accepts every medium the protocol
can carry — silently, on an edit that never mentioned the field.

The `maybe` is inherited from `optional` above: a missing key decodes as "not
declared" instead of failing the whole model list.
-}
modalitiesDecoder : D.Decoder String
modalitiesDecoder =
    D.maybe (D.field "input_modalities" (D.nullable (D.list D.string)))
        |> D.map
            (\declared ->
                case declared of
                    Just (Just kinds) ->
                        E.encode 0 (E.list E.string kinds)

                    Just Nothing ->
                        ""

                    Nothing ->
                        ""
            )


{-| A `reasoning_N` block is raw provider JSON on the wire (AlayaCore types
it `json.RawMessage`); the editor edits it as text. -}
jsonBlock : String -> D.Decoder String
jsonBlock key =
    D.maybe (D.field key D.value)
        |> D.map
            (\maybeValue ->
                case maybeValue of
                    Just value ->
                        canonicalJson (E.encode 0 value)

                    Nothing ->
                        ""
            )


{-| Keys AlayaCore sent that this schema does not model, kept as encoded
JSON *text*.

Text rather than `E.Value` because `Session.Selector.isDirty` is
`working /= original`: opaque JSON in the record would participate in that
comparison for every untouched model. `extras` never renders, so the
representation is invisible to the user either way — and either way the
point stands: a key AlayaCore adds tomorrow survives an AlayaFace edit
tomorrow instead of being deleted from model.conf until someone notices.
-}
extrasDecoder : D.Decoder (Dict String String)
extrasDecoder =
    D.dict D.value
        |> D.map
            (\raw ->
                raw
                    |> Dict.filter (\key _ -> not (List.member key modeledKeys))
                    |> Dict.map (\_ value -> E.encode 0 value)
            )


-- CODEC: ITEM -> model.conf TEXT
--
-- This module writes the file AlayaCore reads, and since v19 it is the ONLY
-- writer: the wire has no model-list write path left (`:model_sync` was
-- removed), so the editor's Save is `write this text` + `:model_load`.
--
-- The format is AlayaCore's `config.FormatKeyValue`: one `key: value` line per
-- field, blocks separated by a `---` line, strings double-quoted and escaped.
-- The field order below follows `agent.modelConfig`'s struct order so a saved
-- file looks like the one AlayaCore itself would write.


encodeModels : List ModelInfo -> String
encodeModels models =
    case models of
        [] ->
            -- An empty file, byte for byte what AlayaCore's `formatModelList`
            -- returns for an empty list.
            ""

        _ ->
            String.join "\n---\n" (List.map encodeModel models) ++ "\n"


{-| One entry as a `model.conf` block (no trailing newline).

Every modeled key is written, because the file REPLACES the list: an omitted
key is a deleted line. The exceptions are the ones AlayaCore's own writer
omits (`omitempty`), so an unchanged entry round-trips byte for byte:

  * `context_limit` / `max_tokens` when 0 (0 is the documented default);
  * an empty `reasoning_N`, which is also how the user clears one;
  * `reasoning_field` when empty (the provider default);
  * `serial_tool_calls` when false;
  * `input_modalities` when UNDECLARED — but an empty declaration (`[]`) IS
    written, because `omitempty` upstream cannot express it and dropping the
    line would turn "takes no media" into "not declared".

`id` is never written — AlayaCore assigns it at runtime (`config:"-"`).
-}
encodeModel : ModelInfo -> String
encodeModel m =
    String.join "\n"
        (List.filterMap identity
            [ Just (Conf.stringLine "name" m.name)
            , Just (Conf.stringLine "protocol_type" m.protocolType)
            , Just (Conf.stringLine "base_url" m.baseUrl)
            , Just (Conf.stringLine "api_key" m.apiKey)
            , Just (Conf.stringLine "model_name" m.modelName)
            , intLine "context_limit" m.contextLimit
            , intLine "max_tokens" m.maxTokens
            ]
            ++ List.filterMap (\( key, text ) -> Conf.rawLine key text)
                [ ( "reasoning_0", m.reasoning0 )
                , ( "reasoning_1", m.reasoning1 )
                , ( "reasoning_2", m.reasoning2 )
                ]
            ++ (if String.isEmpty m.reasoningField then
                    []

                else
                    [ Conf.stringLine "reasoning_field" m.reasoningField ]
               )
            ++ (if m.serialToolCalls then
                    [ "serial_tool_calls: true" ]

                else
                    []
               )
            -- `input_modalities` is written only when DECLARED, and `[]` is a
            -- declaration: AlayaCore reads a missing line as "not declared, the
            -- protocol decides" and `[]` as "no media". Writing one for the
            -- other silently widens a text-only model, which is why this goes
            -- through `rawLine`'s array branch rather than `omitempty`.
            ++ List.filterMap (\( key, text ) -> Conf.rawLine key text)
                [ ( "input_modalities", m.inputModalities ) ]
            -- Keys this build does not model are carried verbatim in `extras`;
            -- a key NEITHER side knows cannot be preserved, because AlayaCore
            -- drops it when it parses the file.
            ++ List.filterMap (\( key, text ) -> Conf.rawLine key text) (Dict.toList m.extras)
        )


intLine : String -> Int -> Maybe String
intLine key value =
    if value == 0 then
        Nothing

    else
        Just (key ++ ": " ++ String.fromInt value)
