module Session.Labels exposing
    ( Label
    , version
    , maxLabelChars
    , autoLabelChars
    , decode
    , encode
    , keys
    , usableText
    , normalise
    , autoFromPrompt
    , storedPath
    , Editor
    , emptyEditor
    , open
    , close
    , input
    , Commit(..)
    , commit
    )

{-| The schema of `session.label.json` — one session's user-visible name
(G-series, `docs/session-identity.md`).

## Why this module owns the whole schema

`sync_session_label` REPLACES the file, so a field this module does not model is
a field deleted from the user's file on the next save. That is the `model.conf`
trap AGENTS.md records, and it is why `App/UiConfig.elm` and
`App/AsrConfig.elm` exist for their documents. There is deliberately **no
`extras` carry-out here**: `asr.conf` has none either, and for the same reason —
every implementation agrees on exactly these three keys, so a key one build does
not know is a bug to catch in a test, not data to smuggle through a `Dict`.
`tests/LabelsTest.elm` pins the serialised key list for that reason.

## Why there is no model-aware half doing the same job

`App/Labels.elm` is the policy (what the listing means, when a write is worth
making); this module is the document. The split is forced, not stylistic:
`App.Types.Model` has a `sessionLabels : Dict String Label` field, so
`App.Types` imports this module and this module can never import `App.Types`
back (AGENTS.md's cycle rule — the same one that made F3 into two modules).

## What is NOT stored

The session's preset, its model, its plan, its geometry. `session.spawn.json`
holds the capability envelope (backend-owned), `ui.conf` holds where the window
was (and gets evicted). A label document that grows fields with different write
triggers and lifetimes becomes a second `settings.conf`; SD-G5 is the rule that
keeps it from doing that.

-}

import Json.Decode as D
import Json.Encode as E


{-| The document version this build writes. NOT a parity scalar: the backends
never read `v` (they must not, or an older backend could refuse a newer
client's file), so only this file knows the number. A future reader can tell
"an older shape" from "corrupt" with it, which is the only job it has.
-}
version : Int
version =
    1


{-| Upper bound on a stored name, in CHARACTERS. Triplicated on purpose and
compared by `scripts/check-backend-parity.sh`: Rust `MAX_LABEL_CHARS`, Go
`MaxLabelChars`. Both backends enforce it too — the client refusing is not
enough, because a hand-edited or older-client file reaches the readers directly.

THE UNIT HAS A CAVEAT worth knowing before you "fix" it: Elm's `String.length`
counts UTF-16 code units, while Go counts runes and Rust counts `chars()`. For
the astral plane (emoji) they differ — `"😀"` is 1 character there and 2 here —
so this client can refuse a 120-emoji name the backends would accept. The
direction is the safe one: the strictest writer is the client's, so the
divergence costs a user an error message on their own input, never a name the
store keeps and the UI will not show.
-}
maxLabelChars : Int
maxLabelChars =
    120


{-| How long an AUTO-derived name is. Client-only on purpose: nothing on disk
records it, and the backends never see a name they did not get verbatim, so this
number cannot drift out of sync with anyone. It is a decision about what a
summary IS, not a limit on storage (that is `maxLabelChars`).
-}
autoLabelChars : Int
autoLabelChars =
    60


{-| A session's name. `auto` says who chose the words: `True` = derived from
the first prompt and therefore replaceable, `False` = the user's own text, which
nothing in the app may overwrite (SD-G8).
-}
type alias Label =
    { text : String
    , auto : Bool
    }


{-| The exact keys `encode` writes, in order. `tests/LabelsTest.elm` asserts the
serialised object has this list, so adding a field means updating the test and
saying why.
-}
keys : List String
keys =
    [ "v", "label", "auto" ]


{-| Read a stored document. Lenient and DROPS (SD-G9): `Nothing` means "show the
fallback", never "the user has a problem". The rules match both backends'
readers exactly — a name the client shows but the manager cannot (or the other
way round) is the same class of bug as the `label: null` divergence the shared
fixture caught, just on the third implementation.
-}
decode : E.Value -> Maybe Label
decode raw =
    case D.decodeValue labelDecoder raw |> Result.toMaybe of
        Just label ->
            Maybe.map (\text -> { label | text = text }) (usableText label.text)

        Nothing ->
            Nothing


labelDecoder : D.Decoder Label
labelDecoder =
    D.map2 Label
        (D.field "label" D.string)
        (D.maybe (D.field "auto" D.bool) |> D.map (Maybe.withDefault False))


{-| Is this string a name the UI may show? One rule, used by both readers:

  * `decode` — a document this client read from disk;
  * `App.Labels.foldListing` — the `label` field of a `list_session_dirs` reply,
    which a backend produced from that same document.

Sharing it is the point. If the two diverged, the same session would be named in
its window title and nameless in the manager (or the reverse), which is the exact
class of bug `label_cases.json` exists to prevent between Go and Rust — the
client is the third implementation, and a test cannot be run cross-language here.

Returns the text VERBATIM (SD-G9's second half): trimming decides *presence*,
never the bytes shown.
-}
usableText : String -> Maybe String
usableText text =
    if String.trim text == "" || String.length text > maxLabelChars then
        Nothing

    else
        Just text


{-| Write the document. Field order is `keys`; the backend stores these bytes
verbatim, so this IS the file.
-}
encode : Label -> E.Value
encode label =
    E.object
        [ ( "v", E.int version )
        , ( "label", E.string label.text )
        , ( "auto", E.bool label.auto )
        ]


{-| Collapse a multi-line text into something a title bar can hold: every run of
whitespace (newlines, tabs, repeated spaces) becomes one space, and the ends go.
`String.words` + `String.join " "` is that rule in one line, and it is idempotent
— `normalise >> normalise == normalise` — because it is applied to text the user
is editing, and a function that changes its own output would make the editor
dirty the moment it opens.

This is the WRITER'S normalisation. Readers never apply it to what they return
(SD-G9's verbatim half): a reader that repairs values is a second writer.
-}
normalise : String -> String
normalise text =
    text
        |> String.words
        |> String.join " "


{-| Derive a name from what the user typed first (SD-G8/G12). `Nothing` when
there is nothing to derive from, so the caller writes nothing rather than saving
an empty name that would then look like a user's choice.

Cut at a word boundary when a whole word fits past the midpoint, otherwise hard,
and mark it with an ellipsis so a truncated name does not read like the user's
own words.
-}
autoFromPrompt : String -> Maybe Label
autoFromPrompt prompt =
    let
        text =
            normalise prompt

        limit =
            autoLabelChars

        tooLong =
            String.length text > limit
    in
    if text == "" then
        Nothing

    else if not tooLong then
        Just { text = text, auto = True }

    else
        Just { text = truncateAt limit text ++ "…", auto = True }


truncateAt : Int -> String -> String
truncateAt limit text =
    let
        head =
            String.left limit text

        -- Prefer losing a partial word at the end, but not most of the name:
        -- a 10-character label cut at its first word boundary would be worse
        -- than the hard cut, so the boundary has to be past half the limit.
        -- (Elm 0.19 has no lastIndexOf; `String.indices " "` gives the
        -- positions and `List.maximum` is the last one.)
        boundary =
            String.indices " " head |> List.maximum
    in
    case boundary of
        Just i ->
            if i > limit // 2 then
                String.left i head

            else
                head

        Nothing ->
            head


{-| The rename editor's view state (G2, `docs/session-identity.md` "Rename
editor"). A GLOBAL overlay — one at a time, its own record in the Model — the
same shape as `App.Presets.Manager` and the config editors, which is why it
carries a `targetId` rather than living per-session (INV-G5: it must NOT join
`App.Windows.sessionIsWaiting`, whose counter means "a prompt is waiting on this
window").

`input` holds the raw keystrokes, `error` a refusal from the last commit attempt
(`""` = none). Neither is normalised while typing: `normalise` collapses runs of
whitespace, and applying it to a field the user is editing would eat the space
they just typed to start the next word — the editor would fight the keyboard.
Normalising happens once, at commit.
-}
type alias Editor =
    { show : Bool
    , targetId : String
    , input : String
    , error : String
    }


emptyEditor : Editor
emptyEditor =
    { show = False
    , targetId = ""
    , input = ""
    , error = ""
    }


{-| Open it for one session, prefilled with the name it is currently called by
(`current`, resolved by the caller — this module cannot read the Model, and
prefilling from `sessionLabels` is `App.Labels`' job).

Prefilled with the CURRENT name rather than blank so that editing a name means
changing a word in it, and so the difference between "rename" and "clear" is
visible: emptying the field and committing clears the name (SD-G15's fallback
comes back), which a blank-on-open editor cannot express.
-}
open : String -> String -> Editor
open targetId current =
    { show = True
    , targetId = targetId
    , input = current
    , error = ""
    }


close : Editor -> Editor
close _ =
    emptyEditor


{-| A keystroke. The refusal from a failed commit goes away as soon as the user
types again — it described the text that is no longer in the field, and leaving
it up would be a stale warning about a sentence they have already fixed.
-}
input : String -> Editor -> Editor
input text ed =
    { ed | input = text, error = "" }


{-| What committing amounts to — DATA, never a command. `App/Labels.elm` turns
`Named` into one `withLabelSave` and `Blank` into a save plus a forgotten entry;
`App/Update.elm` is the only place a port is named (the F-series rule this file
follows by returning values instead of effects).
-}
type Commit
    = Reject String
    | Named Label
    | Blank


{-| Save / Enter / blur. Three outcomes, and the two interesting ones are
adjacent:

  * **too long** → `Reject` with a message naming the limit and the actual count.
    REFUSE, do not truncate: silently eating the end of a name the user typed is
    the same lie as a reader that repairs values (SD-G9), and they would only
    find out by reading the title bar later.
  * **blank** → `Blank`, a real request. Clearing a name is the only way back to
    the fallback, and the backend removes the file for a blank rather than
    writing a tombstone.
  * **anything else** → `Named`, always with `auto = False` (SD-G8: from now on
    these are the user's words and no later derivation may replace them).

Every accepted name is `normalise`d first, so a pasted multi-line prompt becomes
one line the title bar can hold.

There is deliberately no "unchanged, skip the write" case: the model stores only
the NAME and not its `auto` flag, so a commit cannot tell "same text, typed by
hand now" from "same text, derived". The first of those is a real change (the
name stops being replaceable), so a redundant one-file write is the honest price
of getting it right.
-}
commit : Editor -> ( Editor, Commit )
commit ed =
    let
        text =
            normalise ed.input
    in
    if text == "" then
        ( emptyEditor, Blank )

    else if String.length text > maxLabelChars then
        let
            message =
                "A name is at most "
                    ++ String.fromInt maxLabelChars
                    ++ " characters; this one is "
                    ++ String.fromInt (String.length text)
                    ++ "."
        in
        ( { ed | error = message }, Reject message )

    else
        ( emptyEditor, Named { text = text, auto = False } )


{-| Where the document lives: the identity's ROOT directory, never the work copy
(SD-G1). `sessionsDir` comes in as an argument because this module may not read
the Model — the cycle rule again, and the same reason `App/UiConfig.elm` takes
its inputs instead of looking them up.
-}
storedPath : String -> String -> String
storedPath sessionsDir sessionId =
    sessionsDir ++ "/" ++ sessionId ++ "/" ++ fileName


fileName : String
fileName =
    "session.label.json"
