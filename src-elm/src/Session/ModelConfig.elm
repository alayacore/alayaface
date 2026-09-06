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
    )

{-| AlayaCore's `model.conf` schema: the one place in AlayaFace that knows
which keys a model entry has, and how each is decoded, encoded and edited.

Why one module for all three: `:model_sync` REPLACES the whole list and
AlayaCore rewrites `model.conf` from what comes back (`model_manager.go`
`syncFromContent` -> `writeConfigFile`). AlayaFace therefore cannot know a
model entry partially — every key it does not carry is a key it deletes
from the user's config file, silently. That is a destructive round trip:
the model keeps answering, `reasoning_field` is gone, the REASONING window
never appears again, and nothing anywhere reports it.

So these must agree, and ModelConfigTest asserts that they do:

  * `fields`               — every key gets a control in Overlay.ModelEditor,
    so nothing is saved while being invisible to the user;
  * `modelInfoDecoder` /
    `encodeModel`          — every key survives `model_list` -> `model_sync`;
  * `modeledKeys`          — the keys above; anything outside them is
    carried verbatim in `ModelInfo.extras`, so a key AlayaCore adds later
    survives an AlayaFace edit instead of vanishing until someone
    remembers to update this file.

The limit of that: `extras` protects a key AlayaCore knows and this client
build does not yet. A key NEITHER knows cannot be preserved — AlayaCore
parses the payload into its own struct and writes model.conf from that, so
it drops the line itself. AlayaFace must not invent a config line the core
cannot parse.

Mirror of AlayaCore's `protocol.ModelInfo` (the `:model_list` payload) and
`agent.modelConfig` (model.conf). A missing capability is never a reason to
modify AlayaCore: it is a config line, and this module is where AlayaFace
carries them.
-}

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
      -- (value, label): `value` is what the draft stores and what
      -- model.conf gets; `label` is what the row shows.
    | Choice (List ( String, String ))


type alias Field =
    { key : String
    , label : String
    , kind : FieldKind
    , placeholder : String
    , hint : String
    , get : ModelDraft -> String
    , set : String -> ModelDraft -> ModelDraft
    }


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
    , choice "protocol_type" "Protocol Type" "Wire protocol of the endpoint."
        [ ( "openai", "openai" )
        , ( "anthropic", "anthropic" )
        ]
        .protocolType
        (\v d -> { d | protocolType = v })
    , field "base_url" Text "Base URL" "https://api.openai.com/v1"
        "API server URL the entry talks to."
        .baseUrl
        (\v d -> { d | baseUrl = v })
    , field "api_key" Text "API Key" "sk-..."
        ""
        .apiKey
        (\v d -> { d | apiKey = v })
    , field "model_name" Text "Model Name" "gpt-4o"
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
    ]


field : String -> FieldKind -> String -> String -> String -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
field key kind label placeholderText hint get set =
    { key = key
    , label = label
    , kind = kind
    , placeholder = placeholderText
    , hint = hint
    , get = get
    , set = set
    }


choice : String -> String -> String -> List ( String, String ) -> (ModelDraft -> String) -> (String -> ModelDraft -> ModelDraft) -> Field
choice key label hint options get set =
    field key (Choice options) label "" hint get set


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


-- VALIDATION


{-| Per-field reasons a draft must not be saved, as (field key, message).

Only `Json` and `Number` can fail: `encodeModel` cannot represent
unparsable provider JSON or a non-numeric token limit without inventing a
value, and inventing one is precisely the silent data loss this module
exists to prevent. `Overlay.ModelEditor` shows these against the offending
field and disables Save; `App.SelectorKit.editSave` refuses on them too, so
neither end can be bypassed.

Empty text is never a problem — every optional field is empty by default,
meaning "not configured", which is what a brand-new entry starts with.
-}
draftProblems : ModelDraft -> List ( String, String )
draftProblems draft =
    let
        problem f =
            case f.kind of
                Json ->
                    jsonProblem f (f.get draft)

                Number ->
                    numberProblem f (f.get draft)

                Choice options ->
                    if List.member (String.trim (f.get draft)) (List.map Tuple.first options) then
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


{-| One-line digest of what an entry is configured to do, for the model
list rows. Every field the row shows is one the editor can set, so a user
can see at a glance which entries use a non-default reasoning key or run
their tool calls serially, without opening twelve forms to find out.

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
    , if Dict.isEmpty m.extras then
        Nothing

      else
        Just ("+" ++ String.fromInt (Dict.size m.extras) ++ " more")
    ]
        |> List.filterMap identity
        |> String.join " · "


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
        |> andMap extrasDecoder


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap =
    D.map2 (|>)


optional : D.Decoder a -> a -> String -> D.Decoder a
optional decoder default key =
    D.maybe (D.field key decoder) |> D.map (Maybe.withDefault default)


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


-- CODEC: ITEM -> JSON (the :model_sync payload)


encodeModels : List ModelInfo -> String
encodeModels models =
    E.encode 0 (E.list encodeModel models)


{-| Every modeled key is always written; `model_sync` replaces the list, so
an omitted key is a deleted line.

The one exception is the raw `reasoning_N` blocks: an empty one would land
in model.conf as an empty value where AlayaCore's own writer omits the key,
so an empty block stays absent — which is also how the user clears one.

`serial_tool_calls` is always sent, matching AlayaCore, whose json tag drops
`omitempty` for exactly this reason.
-}
encodeModel : ModelInfo -> E.Value
encodeModel m =
    E.object
        ([ ( "id", E.int m.id )
         , ( "name", E.string m.name )
         , ( "protocol_type", E.string m.protocolType )
         , ( "base_url", E.string m.baseUrl )
         , ( "api_key", E.string m.apiKey )
         , ( "model_name", E.string m.modelName )
         , ( "context_limit", E.int m.contextLimit )
         , ( "max_tokens", E.int m.maxTokens )
         , ( "reasoning_field", E.string m.reasoningField )
         , ( "serial_tool_calls", E.bool m.serialToolCalls )
         ]
            ++ List.filterMap jsonPair
                [ ( "reasoning_0", m.reasoning0 )
                , ( "reasoning_1", m.reasoning1 )
                , ( "reasoning_2", m.reasoning2 )
                ]
            ++ List.filterMap jsonPair (Dict.toList m.extras)
        )


{-| Re-attach a field that travels as raw JSON: a `reasoning_N` block or a
carried-through extra. Empty or unparsable text yields nothing — unparsable
text cannot reach here from a saved draft (see `draftProblems`), and
`extras` text comes from `E.encode`, so it always parses.
-}
jsonPair : ( String, String ) -> Maybe ( String, E.Value )
jsonPair ( key, text ) =
    if String.isEmpty (String.trim text) then
        Nothing

    else
        Result.toMaybe (D.decodeString D.value text) |> Maybe.map (\value -> ( key, value ))
