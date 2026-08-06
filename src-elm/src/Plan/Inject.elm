module Plan.Inject exposing (injectOutputs)

{-| Output injection for node prompts.

A downstream task can reference an upstream task's result with a
template: `{{<taskId>.output}}`. When the downstream node's session is
created (which only happens after all its dependencies succeeded), the
template is replaced with the upstream task's recorded output (its final
assistant answer).

    injectOutputs (Dict.fromList [ ( "t1", "sold 100 units" ) ])
        "Summarize: {{t1.output}}"
    --> "Summarize: sold 100 units"

Rules:
  - Template syntax is exact: `{{` + taskId + `.output}}` (no spaces).
  - A referenced task with no recorded output (or an unknown id) is
    replaced with `missingOutputMarker` so the model never sees a raw
    template.
  - `{{` without a matching `.output}}` is left untouched (could be
    literal braces in the prompt).
-}

import Dict exposing (Dict)


{-| Replacement text when a referenced task has no usable output.
-}
missingOutputMarker : String -> String
missingOutputMarker taskId =
    "（上游任务 " ++ taskId ++ " 没有可用输出记录）"


{-| Replace every `{{<id>.output}}` in the prompt with that task's
recorded output.
-}
injectOutputs : Dict String String -> String -> String
injectOutputs outputs text =
    injectHelp outputs text ""


injectHelp : Dict String String -> String -> String -> String
injectHelp outputs rest acc =
    case String.indexes "{{" rest |> List.head of
        Nothing ->
            acc ++ rest

        Just openIdx ->
            let
                before =
                    String.left openIdx rest

                afterOpen =
                    String.dropLeft (openIdx + 2) rest
            in
            case String.indexes ".output}}" afterOpen |> List.head of
                Nothing ->
                    -- A "{{" with no matching ".output}}" — leave the
                    -- rest untouched (literal braces, not a template).
                    acc ++ rest

                Just closeIdx ->
                    let
                        taskId =
                            String.left closeIdx afterOpen

                        afterClose =
                            String.dropLeft (closeIdx + String.length ".output}}") afterOpen

                        replacement =
                            case Dict.get taskId outputs of
                                Just out ->
                                    if String.isEmpty out then
                                        missingOutputMarker taskId

                                    else
                                        out

                                Nothing ->
                                    missingOutputMarker taskId
                    in
                    injectHelp outputs afterClose (acc ++ before ++ replacement)
