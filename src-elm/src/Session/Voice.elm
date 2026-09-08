module Session.Voice exposing
    ( Action(..)
    , AsrOutcome(..)
    , micToggle
    , micStart
    , micStop
    , cancelAsr
    , rawToggle
    , captureStopped
    , voiceError
    , rawError
    , asrResult
    , insertTranscript
    )

{-| Per-session voice/ASR recording state transitions (P-series).

The four recording flags on SessionState (voiceActive / asrBusy /
asrDiscard / rawRecording) encode one small state machine, but its
transitions used to be re-implemented inline in ten App/Update message
arms — each with its own copy of the flag resets, eligibility checks
and error texts. This module owns the transitions once, purely:

  * voiceActive = the mic is recording (ASR)
  * asrBusy     = a transcription is in flight (the mic button becomes
                  a cancel until the asr_transcribe result arrives)
  * asrDiscard  = the user cancelled the pending transcription; its
                  result must be dropped when it shows up
  * rawRecording = the raw-audio button is recording; on stop the WAV
                  is sent to AlayaCore as a UA frame

Transitions come back as an `Action` (which JS-side port the caller
should fire) or an `AsrOutcome` (what the caller should do with the
transcript / error). App/Update keeps the model-level bookkeeping that
these flags do not cover (pendingVoiceInsert, push-to-talk create
attribution) and maps actions to ports.
-}

import Session.Types as T


{-| What the caller should do after a transition. Actions map 1:1 to
ports (voiceStart / voiceStop / rawAudioStart / rawAudioStop); `None`
means nothing changed.
-}
type Action
    = None
    | Start
    -- ^ ASR recording started — fire voiceStart.
    | Stop
    -- ^ ASR recording stopped — fire voiceStop (transcribes).
    | RawStart
    -- ^ Raw recording started — fire rawAudioStart.
    | RawStop
    -- ^ Raw recording stopped — fire rawAudioStop (encodes + sends UA).


{-| ASR result handling outcome (asrResult).
-}
type AsrOutcome
    = AsrDiscarded
    -- ^ The transcription belonged to a cancelled session: clear the
    --   discard flag and do nothing else (the result is dropped).
    | AsrEmpty
    -- ^ Recognized nothing: surface "No speech recognized".
    | AsrText String
    -- ^ Transcript ready: the caller stores it as pendingVoiceInsert
    --   and asks JS for the caret position.
    | AsrFailed String
    -- ^ Transcription error: surface the message.


{-| Mic-button click (VoiceInput): transcribing → ignore; recording →
stop (transcribe); idle → start.
-}
micToggle : T.SessionState -> ( T.SessionState, Action )
micToggle s =
    if s.asrBusy then
        ( s, None )

    else if s.voiceActive then
        ( { s | voiceActive = False, asrBusy = True }, Stop )

    else
        ( { s | voiceActive = True }, Start )


{-| Start ASR recording (mic button / push-to-talk on an existing
session, after the caller's availability checks).
-}
micStart : T.SessionState -> T.SessionState
micStart s =
    { s | voiceActive = True }


{-| Stop ASR recording and transcribe (mic toggle / push-to-talk
release). Mirrors the stop branch of micToggle.
-}
micStop : T.SessionState -> T.SessionState
micStop s =
    { s | voiceActive = False, asrBusy = True }


{-| Cancel a pending transcription (CancelAsr): mark the session so the
in-flight result is dropped (asrDiscard). The backend call cannot be
aborted mid-flight — the discard is checked when AsrResult arrives.
-}
cancelAsr : T.SessionState -> T.SessionState
cancelAsr s =
    { s | voiceActive = False, asrBusy = False, asrDiscard = True }


{-| Raw-audio button click (RawAudioInput): ASR recording/transcribing
→ ignore (mutual exclusion — the UI disables the raw button there);
recording → stop; idle → start.
-}
rawToggle : T.SessionState -> ( T.SessionState, Action )
rawToggle s =
    if s.asrBusy || s.voiceActive then
        ( s, None )

    else if s.rawRecording then
        ( { s | rawRecording = False }, RawStop )

    else
        ( { s | rawRecording = True }, RawStart )


{-| The JS capture timer hit the cap and auto-stopped a recorder
(CaptureAutoStop). Sync the flags so buttons/input unlock; the finish
path (ASR transcribe / raw encode+send) reports back through the usual
ports. kind "asr" → the ASR recorder stopped; anything else → raw.
-}
captureStopped : String -> T.SessionState -> T.SessionState
captureStopped kind s =
    if kind == "asr" then
        { s | voiceActive = False, asrBusy = True }

    else
        { s | rawRecording = False }


{-| ASR mic failure (VoiceError): release every recording flag; the
caller surfaces the message and clears any push-to-talk session link.
-}
voiceError : T.SessionState -> T.SessionState
voiceError s =
    { s | voiceActive = False, asrBusy = False, asrDiscard = False }


{-| Raw-audio failure (RawAudioError): release the raw recorder; the
caller surfaces the message.
-}
rawError : T.SessionState -> T.SessionState
rawError s =
    { s | rawRecording = False }


{-| Transcription finished (AsrResult). The discard check comes FIRST —
a result for a cancelled session is dropped silently, whatever its
ok/error flags say.
-}
asrResult : Bool -> String -> String -> T.SessionState -> ( T.SessionState, AsrOutcome )
asrResult ok text error s =
    if s.asrDiscard then
        ( { s | asrDiscard = False, asrBusy = False, voiceActive = False }, AsrDiscarded )

    else if ok then
        if String.isEmpty text then
            ( { s | asrBusy = False, voiceActive = False }, AsrEmpty )

        else
            ( { s | asrBusy = False, voiceActive = False }, AsrText text )

    else
        ( { s | asrBusy = False, voiceActive = False }, AsrFailed error )


{-| Caret position for a pending transcript (CursorPosResult): insert
the text at the caret and return the new caret offset (place it AFTER
the insert so the user can hit Enter right away).
-}
insertTranscript : T.SessionState -> Int -> String -> ( T.SessionState, Int )
insertTranscript s pos text =
    let
        before =
            String.left pos s.input

        after =
            String.dropLeft pos s.input
    in
    ( { s | input = before ++ text ++ after, asrDiscard = False }
    , pos + String.length text
    )
