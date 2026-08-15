module AsrConfigTest exposing (tests)

{-| Pins the ASR protocol display names: the profile list rows and the
edit-form dropdown must show the SAME labels (one source of truth), and
an unknown protocol value (e.g. a hand-edited asr.conf) must be shown
verbatim instead of being silently mislabeled as "transcriptions".
-}

import Expect
import Overlay.AsrConfig as AC
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Overlay/AsrConfig protocolDisplayName"
        [ test "transcriptions → OpenAI-compatible multipart upload" <|
            \_ ->
                AC.protocolDisplayName "transcriptions"
                    |> Expect.equal "OpenAI /audio/transcriptions (multipart upload)"
        , test "chat_completions → MiMo-style JSON + api-key" <|
            \_ ->
                AC.protocolDisplayName "chat_completions"
                    |> Expect.equal "Chat completions (MiMo-style, JSON + api-key)"
        , test "step_audio → StepFun StepAudio SSE + Bearer" <|
            \_ ->
                AC.protocolDisplayName "step_audio"
                    |> Expect.equal "StepAudio (StepFun, SSE + Bearer auth)"
        , test "unknown protocol value is shown verbatim, not as transcriptions" <|
            \_ ->
                AC.protocolDisplayName "typo_protocol"
                    |> Expect.equal "typo_protocol (unknown protocol)"
        ]
