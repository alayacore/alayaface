module App.SettingsConfig exposing
    ( Editor, Payload, Action(..)
    , emptyEditor
    , open, close
    , setToolConfirm, setBuiltinTools, setSystemPrompt, setReasoningLevel
    , save, adoptList, adoptSync
    )

{-| The per-preset settings editor: `~/.alayaface/presets/<preset>/settings.conf`
(`tool_confirm`, `builtin_tools`, `system_prompt`, `reasoning_level`).

== Why this one is a different hazard from the others

`sync_global_settings` **merges**: both backends take the payload and apply only
the keys present in it, leaving the rest of the file as it was (Go
`handlers/settings.go` says so in as many words — "a partial sync must not wipe
e.g. system_prompt"). That is the opposite of `sync_asr_config`, `sync_ui_config`
and `model_sync`, which *replace* the file, so a key this client does not model is
a key deleted from the user's config.

Two consequences, both easy to get wrong from the outside:

  - A key hand-added to settings.conf SURVIVES a save here. No byte-exact key-list
    pin is needed for this file, and adding one would be misleading.
  - This editor nevertheless sends all four fields on every save (`Payload`), which
    means a field this module does not model cannot be *preserved* by an old client
    either — merge protects the file, not the round trip. Do not read the merge
    semantics as permission to drop a field from the payload: the effective value
    of a preset is what the next read returns, and a stale editor would write a
    stale value back over a change made elsewhere.

The editor is a single overlay reused for every preset: `Editor.preset` says which
one it is showing, and `open` replaces the whole editor rather than clearing fields
one by one, so a preset's values can never leak into another preset's form.

Pure by the rule in `docs/update-slices.md`: `App.Types` types a `Model` field with
`Editor`, so this module cannot import `App.Types`. Effects leave as `Action` data;
`App.Update`'s `applySettingsAction` is the only mapper to ports.
-}

import Json.Decode as D
import Json.Encode as E


{-| The overlay's view state. `preset` is the preset being edited; `loading` /
`syncing` are why `close` refuses.
-}
type alias Editor =
    { show : Bool
    , loading : Bool
    , syncing : Bool
    , toolConfirm : String
    , builtinTools : String
    , systemPrompt : String
    , reasoningLevel : Int
    , error : Maybe String
    , preset : String
    }


emptyEditor : Editor
emptyEditor =
    { show = False
    , loading = False
    , syncing = False
    , toolConfirm = ""
    , builtinTools = ""
    , systemPrompt = ""
    , reasoningLevel = 1
    , error = Nothing
    , preset = ""
    }


{-| What a save sends. All four fields, every time — see the module comment.
-}
type alias Payload =
    { preset : String
    , toolConfirm : String
    , builtinTools : String
    , systemPrompt : String
    , reasoningLevel : Int
    }


{-| Effects as data. `Focus` and `PlaceCursor` are the two halves of "the caret
lands in the first field after the values arrive" — they are actions rather than
direct port calls so a test can see that a good read moves the caret and a failed
one does not.
-}
type Action
    = Read String
    | Sync Payload
    | Focus String
    | PlaceCursor String


{-| The id of the editor's first field. One constant, because `focusAfterDelay` and
`set_cursor_pos` must name the same element or the caret lands nowhere.
-}
firstFieldId : String
firstFieldId =
    "settings-tool-confirm"


{-| Open the editor for a preset: empty form, marked loading, and a read.

`loading` starts true because the fields shown before the read answers are not the
preset's values — an empty form would read as "this preset has no system prompt".
The caret is NOT placed here; nothing is in the fields yet. It goes in with the
reply (`adoptList`), which is the order the original arms had.
-}
open : String -> ( Editor, List Action )
open preset =
    ( { emptyEditor | show = True, loading = True, preset = preset }, [ Read preset ] )


{-| Close, refusing while a sync is in flight.
-}
close : Editor -> Editor
close ed =
    if ed.syncing then
        ed

    else
        emptyEditor


{-| Field edits. Each clears the error line: a message about the previous attempt
must not sit under a value that may just have fixed it.
-}
setToolConfirm : String -> Editor -> Editor
setToolConfirm val ed =
    { ed | toolConfirm = val, error = Nothing }


setBuiltinTools : String -> Editor -> Editor
setBuiltinTools val ed =
    { ed | builtinTools = val, error = Nothing }


setSystemPrompt : String -> Editor -> Editor
setSystemPrompt val ed =
    { ed | systemPrompt = val, error = Nothing }


setReasoningLevel : Int -> Editor -> Editor
setReasoningLevel lvl ed =
    { ed | reasoningLevel = lvl, error = Nothing }


payload : Editor -> Payload
payload ed =
    { preset = ed.preset
    , toolConfirm = ed.toolConfirm
    , builtinTools = ed.builtinTools
    , systemPrompt = ed.systemPrompt
    , reasoningLevel = ed.reasoningLevel
    }


{-| Save. There is no client-side validation here on purpose: every field has a
backend normalizer (`normalize_tool_confirm`, `normalize_reasoning_level`) that
both backends share, and a second opinion in the client is how the two drift. The
error the user sees comes from the reply (`adoptSync`).
-}
save : Editor -> ( Editor, List Action )
save ed =
    ( { ed | syncing = True, error = Nothing }, [ Sync (payload ed) ] )


listReplyDecoder : D.Decoder { ok : Bool, toolConfirm : String, builtinTools : String, systemPrompt : String, reasoningLevel : Int, error : String }
listReplyDecoder =
    D.map6
        (\ok toolConfirm builtinTools systemPrompt reasoningLevel error ->
            { ok = ok
            , toolConfirm = toolConfirm
            , builtinTools = builtinTools
            , systemPrompt = systemPrompt
            , reasoningLevel = reasoningLevel
            , error = error
            }
        )
        (D.field "ok" D.bool)
        (D.field "tool_confirm" D.string)
        (D.field "builtin_tools" D.string)
        (D.field "system_prompt" D.string)
        (D.field "reasoning_level" D.int)
        (D.field "error" D.string)


{-| A `sync_global_settings` reply: the effective values, which may differ from
what was sent (the backend normalizes).
-}
syncReplyDecoder : D.Decoder { ok : Bool, error : String }
syncReplyDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)


{-| Adopt a read. On success the fields become the file's values and the caret is
placed; on failure the editor keeps whatever it had, so the user can still see and
fix a half-filled form. `Nothing` = not a reply at all, and then nothing at all
happens (a stuck `loading` is honest; invented values are not).
-}
adoptList : E.Value -> Editor -> Maybe ( Editor, List Action )
adoptList raw ed =
    case D.decodeValue listReplyDecoder raw |> Result.toMaybe of
        Just res ->
            if res.ok then
                Just
                    ( { ed
                        | loading = False
                        , toolConfirm = res.toolConfirm
                        , builtinTools = res.builtinTools
                        , systemPrompt = res.systemPrompt
                        , reasoningLevel = res.reasoningLevel
                        , error = Nothing
                      }
                    , [ Focus firstFieldId, PlaceCursor firstFieldId ]
                    )

            else
                Just ( { ed | loading = False, error = Just res.error }, [] )

        Nothing ->
            Nothing


{-| Adopt a save. Success closes the overlay (the file is written and the editor
has nothing further to show); failure unsticks `syncing` so the overlay can be
closed again.
-}
adoptSync : E.Value -> Editor -> Maybe Editor
adoptSync raw ed =
    case D.decodeValue syncReplyDecoder raw |> Result.toMaybe of
        Just res ->
            if res.ok then
                Just emptyEditor

            else
                Just { ed | syncing = False, error = Just res.error }

        Nothing ->
            Nothing
