module App.GlobalConfig exposing
    ( Document, Editor, Action(..)
    , emptyDocument, emptyEditor, defaultRecursionLimit
    , open, close, setInput, save
    , adoptGet, adoptSync
    )

{-| The cross-preset settings overlay: `~/.alayaface/global.conf`.

One field today — `recursionLimit`, the Plan Mode depth cap (a plan deeper than
this gets no plan system prompt in its node sessions, which is how the model stops
delegating). It applies to EVERY preset, unlike the per-preset
`App.SettingsConfig`, which is why the two are separate modules and separate
overlays.

== The hazard, stated twice because it is easy to miss

`sync_global_config` **replaces** the file: both backends decode the payload into
their typed struct and write that struct back, so any key present in the user's
`global.conf` but absent from the struct is DELETED. That is the `model.conf` /
`ui.conf` / `asr.conf` class of bug, not the merge semantics of `settings.conf`.
Adding a key to `global.conf` therefore means changing all three implementations
together — Go's `GlobalConfig`, Rust's `GlobalConfig`, and `Document` below — or
the first save from the client that does not model it erases it.

The default, `8`, is the same triple: `DefaultRecursionLimit` (Go),
`DEFAULT_RECURSION_LIMIT` (Rust) and `defaultRecursionLimit` (here).
`scripts/check-backend-parity.sh` compares all three — a divergence is otherwise
quiet, and the symptom is a client showing a number the backend replaces on the
next save.

Validation stays minimal and mirrors the backend's normalizer rather than inventing
a policy: a value below 1 falls back to the default there, so the client refuses
the same inputs with its own message instead of letting a "0" silently become 8.

Pure by the rule in `docs/update-slices.md` (a `Model` field is typed by this
module, so no `App.Types` import). Effects leave as `Action` data;
`App.Update`'s `applyGlobalAction` is the only mapper to ports.
-}

import Json.Decode as D
import Json.Encode as E


{-| The whole document. See the module comment before adding a field.
-}
type alias Document =
    { recursionLimit : Int }


{-| The default plan-recursion depth. Triply defined; see the module comment.
-}
defaultRecursionLimit : Int
defaultRecursionLimit =
    8


emptyDocument : Document
emptyDocument =
    { recursionLimit = defaultRecursionLimit }


{-| The overlay's view state. The limit is edited as TEXT (`input`) because the
whole point is to be able to tell the user that "eight" is not a number rather
than silently sending 0 and letting the backend turn it into the default.
-}
type alias Editor =
    { show : Bool
    , loading : Bool
    , syncing : Bool
    , input : String
    , error : Maybe String
    }


emptyEditor : Editor
emptyEditor =
    { show = False
    , loading = False
    , syncing = False
    , input = ""
    , error = Nothing
    }


{-| Effects as data. `Sync Int` carries a validated limit, so the arm that maps it
cannot send an unchecked value.
-}
type Action
    = Get
    | Sync Int


{-| Open the overlay: marked loading, and a read of the file.
-}
open : ( Editor, List Action )
open =
    ( { emptyEditor | show = True, loading = True }, [ Get ] )


{-| Close, refusing while a sync is in flight (the reply would arrive over a
discarded overlay).
-}
close : Editor -> Editor
close ed =
    if ed.syncing then
        ed

    else
        emptyEditor


{-| Editing the field clears the error line.
-}
setInput : String -> Editor -> Editor
setInput val ed =
    { ed | input = val, error = Nothing }


{-| Validate and save. Two distinct messages, because the two failures are
different questions: "that is not a number" and "that number is out of range".
Both refuse with no write — the backend would normalize either one into the
default, which is a silent change to a value the user just typed.
-}
save : Editor -> ( Editor, List Action )
save ed =
    case String.toInt (String.trim ed.input) of
        Nothing ->
            ( { ed | error = Just "Recursion limit must be a positive integer" }, [] )

        Just n ->
            if n < 1 then
                ( { ed | error = Just "Recursion limit must be >= 1" }, [] )

            else
                ( { ed | syncing = True, error = Nothing }, [ Sync n ] )


getReplyDecoder : D.Decoder { ok : Bool, recursionLimit : Int, error : String }
getReplyDecoder =
    D.map3
        (\ok recursionLimit error -> { ok = ok, recursionLimit = recursionLimit, error = error })
        (D.field "ok" D.bool)
        (D.field "recursion_limit" D.int)
        (D.field "error" D.string)


{-| `get_global_config` and `sync_global_config` answer with the same shape (the
effective document plus ok/error), so one decoder serves both arms.
-}
syncReplyDecoder : D.Decoder { ok : Bool, recursionLimit : Int, error : String }
syncReplyDecoder =
    getReplyDecoder


{-| Adopt a read. The raw backend value and the editor's text are both set so the
form shows what the file actually says — including when that is the default the
backend fell back to.
-}
adoptGet : E.Value -> ( Document, Editor ) -> Maybe ( Document, Editor )
adoptGet raw ( doc, ed ) =
    case D.decodeValue getReplyDecoder raw |> Result.toMaybe of
        Just res ->
            if res.ok then
                Just
                    ( { doc | recursionLimit = res.recursionLimit }
                    , { ed | loading = False, input = String.fromInt res.recursionLimit, error = Nothing }
                    )

            else
                Just ( doc, { ed | loading = False, error = Just res.error } )

        Nothing ->
            Nothing


{-| Adopt a save. Success closes the overlay and adopts the EFFECTIVE limit, which
is what makes a normalization visible instead of surprising the user later.
-}
adoptSync : E.Value -> ( Document, Editor ) -> Maybe ( Document, Editor )
adoptSync raw ( doc, ed ) =
    case D.decodeValue syncReplyDecoder raw |> Result.toMaybe of
        Just res ->
            if res.ok then
                Just ( { doc | recursionLimit = res.recursionLimit }, emptyEditor )

            else
                Just ( doc, { ed | syncing = False, error = Just res.error } )

        Nothing ->
            Nothing
