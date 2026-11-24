module ModelConfigTest exposing (suite)

{-| The `model.conf` round trip.

AlayaFace writes the entire model list to model.conf, so every key it does
not carry is a key it deletes from the user's config file. The bug these
tests pin is silent and destructive: edit one field, Save, and unrelated
fields — `reasoning_field`, `serial_tool_calls`, `reasoning_0/1/2` —
disappear, and the symptom is "the REASONING window never appears" or "tool
calls overlapped again", with no error anywhere.

Five invariants, none of which held before Session.ModelConfig existed:

  1. every key `model_list` sends is decoded and re-encoded;
  2. editing one field leaves every other field untouched;
  3. a key AlayaFace has never heard of still comes back out;
  4. every modelled key has a control in the editor;
  5. the keys AlayaCore's `validateModel` requires cannot be saved empty —
     `scripts/check-model-schema.sh` compares that set against the core, in both
     directions, so neither a missing refusal nor an over-strict one stays
     invisible.
-}

import Dict exposing (Dict)
import Expect
import Json.Decode as D
import Session.ModelConfig as MC
import Session.Types as T
import Test exposing (..)


{-| A full `model_list` entry as AlayaCore emits it (`protocol.ModelInfo`),
including one key AlayaFace does not model (`quantization`), standing in for
whatever AlayaCore adds next.
-}
fullEntry : String
fullEntry =
    """{ "id": 7
    , "name": "vLLM DeepSeek"
    , "protocol_type": "openai"
    , "base_url": "http://127.0.0.1:8000/v1"
    , "api_key": "none"
    , "model_name": "deepseek-r1"
    , "context_limit": 163840
    , "max_tokens": 8192
    , "reasoning_field": "reasoning"
    , "reasoning_0": { "thinking": { "type": "disabled" } }
    , "reasoning_2": { "thinking": { "type": "enabled" }, "effort": "max" }
    , "serial_tool_calls": true
    , "input_modalities": ["text", "image"]
    , "quantization": "awq"
    }"""


minimalEntry : String
minimalEntry =
    """{ "id": 1, "name": "m", "protocol_type": "openai"
    , "base_url": "http://x/v1", "api_key": "k", "model_name": "m" }"""


decodeEntry : String -> T.ModelInfo
decodeEntry text =
    case D.decodeString MC.modelInfoDecoder text of
        Ok info ->
            info

        Err err ->
            Debug.todo ("modelInfoDecoder rejected its own fixture: " ++ D.errorToString err)


entry : T.ModelInfo
entry =
    decodeEntry fullEntry


{-| A model that declares it takes NO media: `[]`, on the wire and in the
file. Not the same entry as `plainEntry`, which declares nothing at all and
therefore lets the protocol decide — the difference is the thing
`input_modalities` exists to express. -}
noMediaEntry : T.ModelInfo
noMediaEntry =
    decodeEntry
        """{ "id": 4, "name": "text-only", "protocol_type": "openai", "base_url": "http://x/v1",
            "api_key": "k", "model_name": "m", "input_modalities": [],
            "serial_tool_calls": false }"""


{-| The wire spells "not declared" as `null` (the core's json tag has no
`omitempty` for exactly this reason), so the client has to read it. -}
nullModalitiesEntry : T.ModelInfo
nullModalitiesEntry =
    decodeEntry
        """{ "id": 5, "name": "undeclared", "protocol_type": "openai", "base_url": "http://x/v1",
            "api_key": "k", "model_name": "m", "input_modalities": null,
            "serial_tool_calls": false }"""


{-| An entry as an older core / a hand-written model.conf leaves it: only
the required keys, plus the serial flag AlayaCore always states. -}
plainEntry : T.ModelInfo
plainEntry =
    decodeEntry
        """{ "id": 3, "name": "plain", "protocol_type": "openai", "base_url": "http://x/v1",
            "api_key": "k", "model_name": "m", "context_limit": 8192, "max_tokens": 2048,
            "serial_tool_calls": false }"""


{-| A fresh draft. Named rather than written `MC.emptyDraft` because Elm's
parser only accepts a plain lowercase name as a record-update base.
-}
blank : T.ModelDraft
blank =
    MC.emptyDraft


{-| The smallest draft that IS savable: `blank` plus the two text fields
AlayaCore's `validateModel` requires. Per-field tests start here so that the
problem list they assert contains only the field under test — starting from
`blank` would mix in "base_url is required" and every assertion would be about
two things at once.
-}
clean : T.ModelDraft
clean =
    { blank | baseUrl = "https://api.example.com/v1", modelName = "gpt-4o" }


minimal : T.ModelInfo
minimal =
    decodeEntry minimalEntry


{-| The `model.conf` block for one item, as key → the value text as written
(quotes included for strings), so a test can ask "is this key stated at all,
and with what value?" -}
confObject : T.ModelInfo -> Dict String String
confObject m =
    parseConfBlock (MC.encodeModel m)


{-| Split one `model.conf` block into its key/value lines.

The first `": "` is the separator: a key never contains one, and the colons a
JSON value carries come after it. Values keep their quotes, which is what lets
an assertion read like the file (`Just "\"reasoning\""`).
-}
parseConfBlock : String -> Dict String String
parseConfBlock text =
    text
        |> String.split "\n"
        |> List.filterMap
            (\line ->
                case String.indexes ": " line |> List.head of
                    Just i ->
                        Just ( String.left i line, String.dropLeft (i + 2) line )

                    Nothing ->
                        Nothing
            )
        |> Dict.fromList


{-| The three provider-JSON blocks: the only modelled keys that are absent
from the block when unset (see `encodeModel`). -}
reasoningBlocks : List String
reasoningBlocks =
    [ "reasoning_0", "reasoning_1", "reasoning_2" ]


stated : String -> T.ModelInfo -> Maybe String
stated key m =
    Dict.get key (confObject m)


suite : Test
suite =
    describe "Session.ModelConfig"
        [ describe "model_list -> item"
            [ test "reasoning_field is decoded" <|
                \_ -> Expect.equal "reasoning" entry.reasoningField
            , test "serial_tool_calls is decoded as a bool" <|
                \_ -> Expect.equal True entry.serialToolCalls
            , test "a reasoning_N block is decoded as provider JSON text" <|
                \_ ->
                    Expect.equal "{\"thinking\":{\"type\":\"enabled\"},\"effort\":\"max\"}"
                        entry.reasoning2
            , test "an unset reasoning_N is the empty string" <|
                \_ -> Expect.equal "" entry.reasoning1
            , test "the fields that predate this change still decode" <|
                \_ ->
                    Expect.all
                        [ \m -> Expect.equal 7 m.id
                        , \m -> Expect.equal "vLLM DeepSeek" m.name
                        , \m -> Expect.equal "openai" m.protocolType
                        , \m -> Expect.equal "http://127.0.0.1:8000/v1" m.baseUrl
                        , \m -> Expect.equal "none" m.apiKey
                        , \m -> Expect.equal "deepseek-r1" m.modelName
                        , \m -> Expect.equal 163840 m.contextLimit
                        , \m -> Expect.equal 8192 m.maxTokens
                        ]
                        entry
            , test "input_modalities is decoded as the JSON array it travels as" <|
                \_ -> Expect.equal "[\"text\",\"image\"]" entry.inputModalities
            , test "…and it is no longer carried as an unknown key" <|
                \_ -> Expect.equal [ "quantization" ] (Dict.keys entry.extras)
            ]
        , describe "an entry from before the fields existed (older core, hand-written model.conf)"
            [ test "no serial_tool_calls means concurrent — AlayaCore's historical behavior" <|
                \_ -> Expect.equal False minimal.serialToolCalls
            , test "no reasoning_field means AlayaCore's provider default" <|
                \_ -> Expect.equal "" minimal.reasoningField
            , test "no reasoning blocks means unset, and nothing is invented for them on the way out" <|
                \_ ->
                    minimal
                        |> confObject
                        |> Dict.filter (\key _ -> List.member key reasoningBlocks)
                        |> Dict.keys
                        |> Expect.equal []
            , test "no input_modalities means not declared, not \"no media\"" <|
                \_ -> Expect.equal "" minimal.inputModalities
            , test "the wire's null means the same thing, and does not become []" <|
                \_ -> Expect.equal "" nullModalitiesEntry.inputModalities
            , test "an empty declaration survives the wire as an empty declaration" <|
                \_ -> Expect.equal "[]" noMediaEntry.inputModalities
            ]
        , describe "item -> model.conf"
            [ test "every modelled key that is written is stated, never left to a default" <|
                \_ ->
                    let
                        unset =
                            List.filter (\key -> String.isEmpty (blockText key entry)) reasoningBlocks

                        -- `id` is runtime state (`config:"-"`), never a line.
                        mustBeStated =
                            List.filter (\key -> key /= "id" && not (List.member key unset))
                                MC.modeledKeys
                    in
                    List.filterMap (\key -> if Dict.member key (confObject entry) then Nothing else Just key) mustBeStated
                        |> Expect.equal []
            , test "values are the ones model_list sent" <|
                \_ -> Expect.equal (Just "\"reasoning\"") (stated "reasoning_field" entry)
            , test "a reasoning_N block comes back as JSON, not as a JSON string" <|
                \_ ->
                    Expect.equal (Just "{\"thinking\":{\"type\":\"disabled\"}}")
                        (stated "reasoning_0" entry)
            , test "serial_tool_calls is written only when true, as AlayaCore omits a false one" <|
                \_ ->
                    Expect.equal
                        ( Dict.member "serial_tool_calls" (confObject { entry | serialToolCalls = False })
                        , stated "serial_tool_calls" entry
                        )
                        ( False, Just "true" )
            , test "an empty reasoning_N is omitted, which is how a block gets cleared" <|
                \_ ->
                    { entry | reasoning0 = "" }
                        |> confObject
                        |> Dict.member "reasoning_0"
                        |> Expect.equal False
            , test "the unknown key is written back verbatim" <|
                \_ -> Expect.equal (Just "\"awq\"") (stated "quantization" entry)
            , test "an item untouched in the editor encodes identically (no phantom edit)" <|
                \_ ->
                    Expect.equal
                        (MC.encodeModel entry)
                        (entry |> MC.draftFromModel |> MC.modelFromDraft |> MC.encodeModel)
            ]
        , describe "the file format (AlayaCore's config.FormatKeyValue)"
            [ test "an empty list is an empty file, as AlayaCore writes it" <|
                \_ -> Expect.equal "" (MC.encodeModels [])
            , test "entries are separated by a `---` line and the file ends with one newline" <|
                \_ ->
                    let
                        text =
                            MC.encodeModels [ entry, plainEntry ]
                    in
                    Expect.equal
                        ( 2, True, False )
                        ( List.length (String.split "\n---\n" text)
                        , String.endsWith "\n" text
                        , String.endsWith "\n\n" text
                        )
            , test "a string is double-quoted and escaped the way the core's parser reads it" <|
                \_ ->
                    Expect.equal (Just "\"a\\\"b\\\\c\\nd\\re\"")
                        (stated "name" { entry | name = "a\"b\\c\nd\re" })
            , test "a zero limit is omitted, because 0 is the documented default" <|
                \_ ->
                    Expect.equal
                        ( False, False, True )
                        ( Dict.member "context_limit" (confObject { entry | contextLimit = 0 })
                        , Dict.member "max_tokens" (confObject { entry | maxTokens = 0 })
                        , Dict.member "context_limit" (confObject entry)
                        )
            , test "an undeclared input_modalities writes no line, which the core reads as nil" <|
                \_ -> Expect.equal Nothing (stated "input_modalities" plainEntry)
            , test "…but an empty declaration (`[]`) IS written, because absent and empty differ" <|
                \_ ->
                    -- The whole point of the field. Dropping the line would
                    -- tell AlayaCore "not declared, the protocol decides" and
                    -- turn a text-only model into one that takes every medium
                    -- the wire can carry — on an edit that never mentioned it.
                    Expect.equal (Just "[]") (stated "input_modalities" noMediaEntry)
            , test "the declaration is written the way AlayaCore's own writer spells it" <|
                \_ -> Expect.equal (Just "[\"text\",\"image\"]") (stated "input_modalities" entry)
            ]
        , describe "the bug this change fixed: edit one field, lose the others"
            [ test "renaming a model keeps reasoning_field" <|
                \_ ->
                    Expect.equal (Just "\"reasoning\"")
                        (entry |> rename |> MC.modelFromDraft |> stated "reasoning_field")
            , test "renaming a model keeps serial_tool_calls" <|
                \_ ->
                    Expect.equal (Just "true")
                        (entry |> rename |> MC.modelFromDraft |> stated "serial_tool_calls")
            , test "renaming a model keeps the provider JSON" <|
                \_ ->
                    Expect.equal (Just "{\"thinking\":{\"type\":\"enabled\"},\"effort\":\"max\"}")
                        (entry |> rename |> MC.modelFromDraft |> stated "reasoning_2")
            , test "renaming a model keeps a key AlayaFace knows nothing about" <|
                \_ ->
                    Expect.equal (Just "\"awq\"")
                        (entry |> rename |> MC.modelFromDraft |> stated "quantization")
            , test "…and the edit itself lands" <|
                \_ ->
                    Expect.equal (Just "\"Renamed\"")
                        (entry |> rename |> MC.modelFromDraft |> stated "name")
            , test "switching the tool-call mode is what reaches the file" <|
                \_ ->
                    entry
                        |> MC.draftFromModel
                        |> MC.updateDraftField "serial_tool_calls" "false"
                        |> MC.modelFromDraft
                        |> stated "serial_tool_calls"
                        -- Omitted, which is how AlayaCore writes `false`
                        -- (`config:"serial_tool_calls,omitempty"`): reading it
                        -- back as absent is reading it back as false.
                        |> Expect.equal Nothing
            , test "editing any other field keeps the media declaration" <|
                \_ ->
                    Expect.equal (Just "[\"text\",\"image\"]")
                        (entry |> rename |> MC.modelFromDraft |> stated "input_modalities")
            , test "…including an empty one, which must not be widened to \"not declared\"" <|
                \_ ->
                    -- The destructive case this field exists for: one Edit+Save
                    -- on an unrelated field, and a text-only model starts
                    -- accepting images because the line disappeared.
                    Expect.equal (Just "[]")
                        (noMediaEntry |> MC.draftFromModel |> MC.updateDraftField "name" "renamed" |> MC.modelFromDraft |> stated "input_modalities")
            , test "declaring modalities is what reaches the file" <|
                \_ ->
                    entry
                        |> MC.draftFromModel
                        |> MC.updateDraftField "input_modalities" "[\"text\",\"audio\"]"
                        |> MC.modelFromDraft
                        |> stated "input_modalities"
                        |> Expect.equal (Just "[\"text\",\"audio\"]")
            , test "clearing the declaration is how \"not declared\" comes back" <|
                \_ ->
                    entry
                        |> MC.draftFromModel
                        |> MC.updateDraftField "input_modalities" ""
                        |> MC.modelFromDraft
                        |> stated "input_modalities"
                        |> Expect.equal Nothing
            , test "typing a reasoning key is what reaches the wire" <|
                \_ ->
                    entry
                        |> MC.draftFromModel
                        |> MC.updateDraftField "reasoning_field" "reasoning_content"
                        |> MC.modelFromDraft
                        |> stated "reasoning_field"
                        |> Expect.equal (Just "\"reasoning_content\"")
            ]
        , describe "the list-row digest"
            [ test "it names every field that is set, including the carried key" <|
                \_ ->
                    Expect.equal
                        "openai · ctx 163840 · out 8192 · reasoning:reasoning · json 2 · serial tools · media: text,image · +1 more"
                        (MC.summaryOf { entry | contextLimit = 163840, maxTokens = 8192, serialToolCalls = True })
            , test "a plain entry says only its protocol" <|
                \_ -> Expect.equal "openai · ctx 8192 · out 2048" (MC.summaryOf plainEntry)
            , test "a declared-empty model reads \"no media\", not the same as undeclared" <|
                \_ ->
                    Expect.equal
                        ( "openai · media: none", "openai" )
                        ( MC.summaryOf noMediaEntry, MC.summaryOf plainEntry |> String.split " · " |> List.head |> Maybe.withDefault "" )
            , test "the API key never reaches a list row" <|
                \_ ->
                    Expect.equal False (String.contains "supersecret" (MC.summaryOf { entry | apiKey = "supersecret" }))
            , test "an un-modelled key is at least counted, so the row does not lie about the entry" <|
                \_ ->
                    Expect.equal "openai · +1 more"
                        (MC.summaryOf
                            { entry
                                | contextLimit = 0
                                , maxTokens = 0
                                , reasoningField = ""
                                , reasoning0 = ""
                                , reasoning1 = ""
                                , reasoning2 = ""
                                , serialToolCalls = False
                                , inputModalities = ""
                            }
                        )
            ]
        , describe "what a row is called (displayOf)"
            [ test "a named entry uses its name" <|
                \_ -> Expect.equal "vLLM DeepSeek" (MC.displayOf { entry | name = "vLLM DeepSeek", modelName = "model-9" })
            , test "…but a blank name does not buy a blank row" <|
                \_ ->
                    -- AlayaCore does not require `name`, so an entry can legally
                    -- have none — and a list titled by it shows an empty row that
                    -- is still selectable. `model_name` is the next handle that
                    -- actually identifies an endpoint.
                    Expect.equal "model-9" (MC.displayOf { entry | name = "", modelName = "model-9" })
            , test "whitespace is a blank name, because the encoder says so" <|
                \_ ->
                    -- `modelFromDraft` trims, so a name of "   " is stored as ""
                    -- and would otherwise render the empty row this exists to
                    -- prevent.
                    Expect.equal "model-9" (MC.displayOf { entry | name = " \u{00a0} ", modelName = "model-9" })
            , test "an entry with neither still says which one it is" <|
                \_ ->
                    -- Never blank, because a blank row cannot be told apart from
                    -- the other blank row; the id is the only thing left and it
                    -- is what AlayaCore assigns.
                    Expect.equal "model 7" (MC.displayOf { entry | name = "", modelName = "" })
            , test "the digest is unaffected, so the two never duplicate each other" <|
                \_ ->
                    -- `displayOf` falls back to `model_name`, and `summaryOf`
                    -- does NOT mention it — if it did, a nameless entry would
                    -- show the same string twice on one row.
                    Expect.equal False (String.contains "model-9" (MC.summaryOf { entry | name = "", modelName = "model-9" }))
            ]
        , describe "UI coverage"
            [ test "the editor's fields plus id are exactly the modelled keys" <|
                \_ -> Expect.equal MC.modeledKeys ("id" :: List.map .key MC.fields)
            , test "no key is modelled twice" <|
                \_ ->
                    let
                        keys =
                            List.map .key MC.fields
                    in
                    Expect.equal (List.length keys)
                        (keys |> List.map (\k -> ( k, () )) |> Dict.fromList |> Dict.size)
            , test "every field reads and writes its own draft slot" <|
                \_ ->
                    List.filter (\f -> f.get (f.set "probe" MC.emptyDraft) /= "probe") MC.fields
                        |> List.map .key
                        |> Expect.equal []
            , test "an unknown key edits nothing" <|
                \_ ->
                    Expect.equal MC.emptyDraft
                        (MC.updateDraftField "reasoning_9" "x" MC.emptyDraft)
            , test "a brand-new model is NOT savable until the required fields are filled" <|
                \_ ->
                    -- This assertion used to read "a brand-new model is savable",
                    -- and that was the bug: an entry with no base_url or
                    -- model_name is what the form shipped, and saving one is how
                    -- a model disappears. `syncFromContent` skips entries that
                    -- fail `validateModel`, then `writeConfigFile` persists the
                    -- survivors — so the entry is gone from the user's model.conf
                    -- BEFORE the CONFIG_MODEL_INVALID reply explains why. The refusal
                    -- has to come from the client, at Save time.
                    Expect.equal [ "base_url", "model_name" ]
                        (MC.draftProblems MC.emptyDraft |> List.map Tuple.first)
            , test "…and filling exactly those two makes it savable" <|
                \_ -> Expect.equal [] (MC.draftProblems clean)
            , test "the required-field message says what is at stake" <|
                \_ ->
                    -- "Required" alone does not explain why a field the user may
                    -- want to leave blank is blocking a button; the consequence
                    -- (losing the whole entry) is the part that earns the refusal.
                    case MC.draftProblems { clean | baseUrl = "   " } of
                        [ ( key, message ) ] ->
                            Expect.all
                                [ \() -> Expect.equal "base_url" key
                                , \() -> Expect.equal True (String.contains "model.conf" message)
                                , \() -> Expect.equal True (String.contains "Base URL" message)
                                ]
                                ()

                        other ->
                            Expect.fail ("expected one problem, got " ++ String.fromInt (List.length other))
            , test "whitespace-only counts as empty, because the encoder makes it so" <|
                \_ ->
                    -- The chain, not the first link: AlayaCore's check is
                    -- `m.BaseURL == ""`, so " " would pass IT — but
                    -- `modelFromDraft` trims every text field before encoding,
                    -- so what actually reaches the core is "". Refusing only the
                    -- literally-empty string would therefore leave this exact
                    -- hole: the user saves " ", the entry is trimmed to nothing,
                    -- skipped, and deleted from model.conf.
                    Expect.equal [ "model_name" ]
                        (MC.draftProblems { clean | modelName = " \u{00a0} " } |> List.map Tuple.first)
            , test "name is NOT required, because the core does not require it" <|
                \_ ->
                    -- The table mirrors `validateModel`, it does not outdo it:
                    -- a nameless entry works, so blocking its save would be
                    -- inventing a rule and would strand the user (they could not
                    -- fix a base URL without also naming the model). `displayOf`
                    -- is the answer to a blank name, not a refusal.
                    Expect.equal [] (MC.draftProblems { clean | name = "" })
            ]
        , describe "a draft the codec cannot encode must not save"
            [ test "unparsable provider JSON is reported against its own field" <|
                \_ ->
                    Expect.equal [ "reasoning_1" ]
                        (MC.draftProblems { clean | reasoning1 = "{\"thinking\":" }
                            |> List.map Tuple.first
                        )
            , test "…and the message stays a single readable line naming the reason" <|
                \_ ->
                    case MC.draftProblems { clean | reasoning1 = "{\"thinking\":" } of
                        [ ( _, message ) ] ->
                            Expect.all
                                [ \m -> Expect.equal 1 (List.length (String.split "\n" m))
                                , \m -> Expect.equal True (String.endsWith "Unexpected end of JSON input)" m)
                                ]
                                message

                        other ->
                            Expect.fail ("expected exactly one problem, got " ++ String.fromInt (List.length other))
            , test "…and the value survives to be fixed rather than being dropped" <|
                \_ ->
                    Expect.equal "{\"thinking\":"
                        (MC.emptyDraft
                            |> MC.updateDraftField "reasoning_1" "{\"thinking\":"
                            |> MC.modelFromDraft
                            |> .reasoning1
                        )
            , test "a non-numeric token limit is refused, not clamped to 0 (0 means unlimited)" <|
                \_ ->
                    Expect.equal [ "context_limit" ]
                        (MC.draftProblems { clean | contextLimit = "128k" }
                            |> List.map Tuple.first
                        )
            , test "clearing a provider-JSON block on purpose is allowed" <|
                \_ -> Expect.equal [] (MC.draftProblems { clean | reasoning0 = "  " })
            , test "an empty reasoning_field is the provider default, not an error" <|
                \_ -> Expect.equal [] (MC.draftProblems { clean | reasoningField = "" })
            , test "a bare null block collapses to unset (model.conf cannot hold it)" <|
                \_ ->
                    Expect.equal ""
                        (MC.emptyDraft
                            |> MC.updateDraftField "reasoning_0" "null"
                            |> MC.modelFromDraft
                            |> .reasoning0
                        )
            , test "provider JSON is not restricted to objects" <|
                \_ -> Expect.equal [] (MC.draftProblems { clean | reasoning2 = "[1,2]" })
            , test "a modality AlayaCore does not know is refused, naming the value and the vocabulary" <|
                \_ ->
                    -- The usual misses are synonyms (`vision` for `image`,
                    -- `pdf` for `document`), so the message has to show which
                    -- word is wrong — and that an unknown one skips the entry.
                    case MC.draftProblems { clean | inputModalities = "[\"text\",\"vision\"]" } of
                        [ ( key, message ) ] ->
                            Expect.all
                                [ \() -> Expect.equal "input_modalities" key
                                , \() -> Expect.equal True (String.contains "\"vision\"" message)
                                , \() -> Expect.equal True (String.contains "image" message)
                                ]
                                ()

                        other ->
                            Expect.fail ("expected exactly one problem, got " ++ String.fromInt (List.length other))
            , test "modalities that are not JSON at all are refused (the core cannot even parse them)" <|
                \_ ->
                    Expect.equal [ "input_modalities" ]
                        (MC.draftProblems { clean | inputModalities = "[text, image]" }
                            |> List.map Tuple.first
                        )
            , test "a non-string element is refused, because the core unmarshals into []string" <|
                \_ ->
                    Expect.equal [ "input_modalities" ]
                        (MC.draftProblems { clean | inputModalities = "[1,2]" }
                            |> List.map Tuple.first
                        )
            , test "an empty declaration is legal — it means \"no media\", not \"unfinished\"" <|
                \_ -> Expect.equal [] (MC.draftProblems { clean | inputModalities = "[]" })
            , test "duplicates are not refused, because validateModel does not refuse them" <|
                \_ ->
                    -- Mirror the core, do not outdo it: FitInputModalities builds
                    -- a set from the list, so this saves a model the core
                    -- accepts. Refusing it would strand an entry over a
                    -- spelling difference with no behavioral effect.
                    Expect.equal [] (MC.draftProblems { clean | inputModalities = "[\"text\",\"text\"]" })
            , test "the declaration is canonicalized the way the core writes it" <|
                \_ ->
                    Expect.equal "[\"text\",\"image\"]"
                        (MC.emptyDraft
                            |> MC.updateDraftField "input_modalities" "[ \"text\" , \"image\" ]"
                            |> MC.modelFromDraft
                            |> .inputModalities
                        )
            , test "a bare null declaration collapses to undeclared (the core reads it as nil)" <|
                \_ ->
                    Expect.equal ""
                        (MC.emptyDraft
                            |> MC.updateDraftField "input_modalities" "null"
                            |> MC.modelFromDraft
                            |> .inputModalities
                        )
            , test "the tool-call mode accepts only what its control offers" <|
                \_ ->
                    Expect.equal [ "serial_tool_calls" ]
                        (MC.draftProblems { clean | serialToolCalls = "maybe" }
                            |> List.map Tuple.first
                        )
            ]
        ]


blockText : String -> T.ModelInfo -> String
blockText key m =
    case key of
        "reasoning_0" ->
            m.reasoning0

        "reasoning_1" ->
            m.reasoning1

        "reasoning_2" ->
            m.reasoning2

        _ ->
            ""


rename : T.ModelInfo -> T.ModelDraft
rename m =
    MC.draftFromModel m |> MC.updateDraftField "name" "Renamed"
