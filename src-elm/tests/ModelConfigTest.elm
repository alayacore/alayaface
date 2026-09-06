module ModelConfigTest exposing (suite)

{-| The `model.conf` round trip.

AlayaCore's `:model_sync` replaces the entire model list and rewrites
model.conf from what it receives, so every key AlayaFace does not carry is
a key it deletes from the user's config file. The bug these tests pin is
silent and destructive: edit one field, Save, and unrelated fields —
`reasoning_field`, `serial_tool_calls`, `reasoning_0/1/2` — disappear, and
the symptom is "the REASONING window never appears" or "tool calls overlapped
again", with no error anywhere.

Four invariants, none of which held before Session.ModelConfig existed:

  1. every key `model_list` sends is decoded and re-encoded;
  2. editing one field leaves every other field untouched;
  3. a key AlayaFace has never heard of still comes back out;
  4. every modelled key has a control in the editor.
-}

import Dict exposing (Dict)
import Expect
import Json.Decode as D
import Json.Encode as E
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


minimal : T.ModelInfo
minimal =
    decodeEntry minimalEntry


{-| The `:model_sync` payload for one item, as a dict of raw JSON values, so
a test can ask "is this key stated at all, and with what value?" -}
syncObject : T.ModelInfo -> Dict String E.Value
syncObject m =
    case D.decodeString (D.dict D.value) (E.encode 0 (MC.encodeModel m)) of
        Ok dict ->
            dict

        Err _ ->
            Debug.todo "encodeModel produced JSON that will not decode"


{-| The three provider-JSON blocks: the only modelled keys that are absent
from the :model_sync payload when unset (see `encodeModel`). -}
reasoningBlocks : List String
reasoningBlocks =
    [ "reasoning_0", "reasoning_1", "reasoning_2" ]


stated : String -> T.ModelInfo -> Maybe String
stated key m =
    Dict.get key (syncObject m) |> Maybe.map (E.encode 0)


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
            , test "a key AlayaFace does not model is carried, not dropped" <|
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
                        |> syncObject
                        |> Dict.filter (\key _ -> List.member key reasoningBlocks)
                        |> Dict.keys
                        |> Expect.equal []
            ]
        , describe "item -> :model_sync"
            [ test "every modelled key is stated, never left to a default — bar an unset JSON block" <|
                \_ ->
                    let
                        unset =
                            List.filter (\key -> String.isEmpty (blockText key entry)) reasoningBlocks

                        mustBeStated =
                            List.filter (\key -> not (List.member key unset)) MC.modeledKeys
                    in
                    List.filterMap (\key -> if Dict.member key (syncObject entry) then Nothing else Just key) mustBeStated
                        |> Expect.equal []
            , test "values are the ones model_list sent" <|
                \_ -> Expect.equal (Just "\"reasoning\"") (stated "reasoning_field" entry)
            , test "a reasoning_N block comes back as JSON, not as a JSON string" <|
                \_ ->
                    Expect.equal (Just "{\"thinking\":{\"type\":\"disabled\"}}")
                        (stated "reasoning_0" entry)
            , test "serial_tool_calls is stated even when false, as AlayaCore states it" <|
                \_ -> Expect.equal (Just "false") (stated "serial_tool_calls" { entry | serialToolCalls = False })
            , test "an empty reasoning_N is omitted, which is how a block gets cleared" <|
                \_ ->
                    { entry | reasoning0 = "" }
                        |> syncObject
                        |> Dict.member "reasoning_0"
                        |> Expect.equal False
            , test "the unknown key is written back verbatim" <|
                \_ -> Expect.equal (Just "\"awq\"") (stated "quantization" entry)
            , test "an item untouched in the editor encodes identically (no phantom edit)" <|
                \_ ->
                    Expect.equal
                        (E.encode 0 (MC.encodeModel entry))
                        (entry |> MC.draftFromModel |> MC.modelFromDraft |> MC.encodeModel |> E.encode 0)
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
            , test "switching the tool-call mode is what reaches the wire" <|
                \_ ->
                    entry
                        |> MC.draftFromModel
                        |> MC.updateDraftField "serial_tool_calls" "false"
                        |> MC.modelFromDraft
                        |> stated "serial_tool_calls"
                        |> Expect.equal (Just "false")
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
                        "openai · ctx 163840 · out 8192 · reasoning:reasoning · json 2 · serial tools · +1 more"
                        (MC.summaryOf { entry | contextLimit = 163840, maxTokens = 8192, serialToolCalls = True })
            , test "a plain entry says only its protocol" <|
                \_ -> Expect.equal "openai · ctx 8192 · out 2048" (MC.summaryOf plainEntry)
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
                            }
                        )
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
            , test "a brand-new model is savable" <|
                \_ -> Expect.equal [] (MC.draftProblems MC.emptyDraft)
            ]
        , describe "a draft the codec cannot encode must not save"
            [ test "unparsable provider JSON is reported against its own field" <|
                \_ ->
                    Expect.equal [ "reasoning_1" ]
                        (MC.draftProblems { blank | reasoning1 = "{\"thinking\":" }
                            |> List.map Tuple.first
                        )
            , test "…and the message stays a single readable line naming the reason" <|
                \_ ->
                    case MC.draftProblems { blank | reasoning1 = "{\"thinking\":" } of
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
                        (MC.draftProblems { blank | contextLimit = "128k" }
                            |> List.map Tuple.first
                        )
            , test "clearing a provider-JSON block on purpose is allowed" <|
                \_ -> Expect.equal [] (MC.draftProblems { blank | reasoning0 = "  " })
            , test "an empty reasoning_field is the provider default, not an error" <|
                \_ -> Expect.equal [] (MC.draftProblems { blank | reasoningField = "" })
            , test "a bare null block collapses to unset (model.conf cannot hold it)" <|
                \_ ->
                    Expect.equal ""
                        (MC.emptyDraft
                            |> MC.updateDraftField "reasoning_0" "null"
                            |> MC.modelFromDraft
                            |> .reasoning0
                        )
            , test "provider JSON is not restricted to objects" <|
                \_ -> Expect.equal [] (MC.draftProblems { blank | reasoning2 = "[1,2]" })
            , test "the tool-call mode accepts only what its control offers" <|
                \_ ->
                    Expect.equal [ "serial_tool_calls" ]
                        (MC.draftProblems { blank | serialToolCalls = "maybe" }
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
