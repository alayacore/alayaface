module PlanDetectTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Plan.Detect as D


tests : Test
tests =
    describe "Plan.Detect.extractPlanJson"
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
