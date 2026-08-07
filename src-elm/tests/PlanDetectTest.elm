module PlanDetectTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Plan.Detect as D


tests : Test
tests =
    describe "Plan.Detect"
        [ describe "extractPlanJson"
            [ test "extracts a fenced json block" <|
                \_ ->
                    let
                        text =
                            """Here is the plan:

```json
{"name": "x", "tasks": []}
```
"""
                    in
                    Expect.equal (Just "{\"name\": \"x\", \"tasks\": []}") (D.extractPlanJson text)
            , test "returns Nothing without fences" <|
                \_ ->
                    Expect.equal Nothing (D.extractPlanJson "plain text no fences")
            , test "returns Nothing for unclosed fence" <|
                \_ ->
                    Expect.equal Nothing (D.extractPlanJson "```json\n{\"name\": \"x\"}")
            , test "skips non-json fences, finds the json one" <|
                \_ ->
                    let
                        text =
                            """```text
some code
```
```json
{"a": 1}
```
"""
                    in
                    Expect.equal (Just "{\"a\": 1}") (D.extractPlanJson text)
            , test "takes the first json fence pair" <|
                \_ ->
                    let
                        text =
                            """```json
{"first": true}
```
```json
{"second": true}
```
"""
                    in
                    Expect.equal (Just "{\"first\": true}") (D.extractPlanJson text)
            , test "handles JSON with embedded newlines" <|
                \_ ->
                    let
                        text =
                            """Plan:
```json
{
  "name": "x",
  "tasks": [
    { "id": "a", "title": "A", "prompt": "do a" }
  ]
}
```
"""
                    in
                    case D.extractPlanJson text of
                        Just raw ->
                            Expect.equal True (String.contains "\n" raw)

                        Nothing ->
                            Expect.fail "no extraction"
            , test "case-insensitive language tag" <|
                \_ ->
                    let
                        text =
                            "```JSON\n{\"x\": 1}\n```"
                    in
                    Expect.equal (Just "{\"x\": 1}") (D.extractPlanJson text)
            , test "tolerates trailing spaces on the fence line" <|
                \_ ->
                    let
                        text =
                            "```json   \n{\"x\": 1}\n```"
                    in
                    Expect.equal (Just "{\"x\": 1}") (D.extractPlanJson text)
            , test "handles CRLF line endings" <|
                \_ ->
                    let
                        text =
                            "```json\r\n{\"x\": 1}\r\n```\r\n"
                    in
                    Expect.equal (Just "{\"x\": 1}") (D.extractPlanJson text)
            , test "returns Nothing for empty block" <|
                \_ ->
                    Expect.equal Nothing (D.extractPlanJson "```json\n   \n```")
            , test "trims surrounding whitespace" <|
                \_ ->
                    let
                        text =
                            "```json\n  {\"x\": 1}  \n```"
                    in
                    Expect.equal (Just "{\"x\": 1}") (D.extractPlanJson text)
            ]
        , describe "hasPlanTypeMarker"
            [ test "true for the exact marker" <|
                \_ ->
                    Expect.equal True
                        (D.hasPlanTypeMarker """{ "type": "alayaface-plan", "name": "x", "tasks": [] }""")
            , test "false for a plain json block without the marker" <|
                \_ ->
                    Expect.equal False
                        (D.hasPlanTypeMarker """{ "name": "x", "tasks": [] }""")
            , test "false for a wrong marker value" <|
                \_ ->
                    Expect.equal False
                        (D.hasPlanTypeMarker """{ "type": "something-else", "name": "x" }""")
            , test "false for invalid json" <|
                \_ ->
                    Expect.equal False (D.hasPlanTypeMarker "not json at all")
            , test "false for a json array / non-object" <|
                \_ ->
                    Expect.equal False (D.hasPlanTypeMarker "[1, 2, 3]")
            , test "true even when the document is invalid JSON (raw newline in a string)" <|
                \_ ->
                    -- A model writing real line breaks inside a string makes
                    -- the document unparseable; the marker must still be
                    -- recognized so the framework repairs or reports the
                    -- error instead of silently dropping the plan message.
                    Expect.equal True
                        (D.hasPlanTypeMarker "{\"type\": \"alayaface-plan\", \"prompt\": \"line1\nline2\"}")
            , test "tolerates whitespace around the colon" <|
                \_ ->
                    Expect.equal True
                        (D.hasPlanTypeMarker """{ "type"  :  "alayaface-plan" }""")
            , test "a prose mention without the key:value pair does not count" <|
                \_ ->
                    Expect.equal False (D.hasPlanTypeMarker """the type is "alayaface-plan" here""")
            ]
        ]
