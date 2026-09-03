module AsrConfigTest exposing (defaultModelTests, tests)

{-| Pins the ASR protocol display names: the profile list rows and the
edit-form dropdown must show the SAME labels (one source of truth), and
an unknown protocol value (e.g. a hand-edited asr.conf) must be shown
verbatim instead of being silently mislabeled as "transcriptions".
-}

import App.Types as AT
import App.Update
import Expect
import Overlay.AsrConfig as AC
import Test exposing (Test, describe, test)
import TestHelpers


tests : Test
tests =
    describe "Overlay/AsrConfig protocolDisplayName"
        [ test "transcriptions → OpenAI-compatible multipart upload" <|
            \_ ->
                AC.protocolDisplayName "transcriptions"
                    |> Expect.equal "OpenAI /audio/transcriptions (multipart upload)"
        , test "chat_completions → OpenAI standard chat completions" <|
            \_ ->
                AC.protocolDisplayName "chat_completions"
                    |> Expect.equal "OpenAI /chat/completions (JSON + api-key)"
        , test "step_audio → StepFun StepAudio raw PCM + SSE" <|
            \_ ->
                AC.protocolDisplayName "step_audio"
                    |> Expect.equal "StepAudio (StepFun, raw PCM + SSE)"
        , test "unknown protocol value is shown verbatim, not as transcriptions" <|
            \_ ->
                AC.protocolDisplayName "typo_protocol"
                    |> Expect.equal "typo_protocol (unknown protocol)"
        ]


{-| The protocol-specific model default. A StepAudio profile left at the
transcriptions default made StepFun transcribe with a whisper model id;
the backend only applies its own default when the field is EMPTY, so the
form has to carry the per-protocol value (see App/Update's SetAsrProtocol).
-}
defaultModelTests : Test
defaultModelTests =
    describe "Overlay/AsrConfig defaultModel"
        [ test "step_audio defaults to the StepFun ASR model" <|
            \_ ->
                AC.defaultModel "step_audio" |> Expect.equal "stepaudio-2.5-asr"
        , test "transcriptions and chat_completions default to whisper-1" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal "whisper-1" (AC.defaultModel "transcriptions")
                    , \_ -> Expect.equal "whisper-1" (AC.defaultModel "chat_completions")
                    ]
                    ()
        , test "switching protocol swaps a still-default model" <|
            \_ ->
                let
                    ( m, _ ) =
                        App.Update.update (AT.SetAsrProtocol "step_audio") (modelWithModel "whisper-1")
                in
                Expect.all
                    [ \mm -> Expect.equal "stepaudio-2.5-asr" mm.asrConfigEditor.model
                    , \mm -> Expect.equal "step_audio" mm.asrConfigEditor.protocol
                    ]
                    m
        , test "a model the user typed is never clobbered" <|
            \_ ->
                let
                    ( m, _ ) =
                        App.Update.update (AT.SetAsrProtocol "step_audio") (modelWithModel "my-asr")
                in
                Expect.equal "my-asr" m.asrConfigEditor.model
        ]


{-| The ASR edit form open on a profile with the given model id. (Elm's
parser wants a plain name as a record-update base, so the model is built
through these helpers rather than updated inline.)
-}
modelWithModel : String -> AT.Model
modelWithModel modelId =
    withEditor (editorWithModel modelId)


withEditor : AT.AsrConfigEditor -> AT.Model
withEditor editor =
    let
        blank =
            TestHelpers.initModelWithSession
    in
    { blank | asrConfigEditor = editor }


editorWithModel : String -> AT.AsrConfigEditor
editorWithModel modelId =
    let
        empty =
            AT.emptyAsrConfigEditor
    in
    { empty
        | show = True
        , inForm = True
        , protocol = "transcriptions"
        , model = modelId
    }
