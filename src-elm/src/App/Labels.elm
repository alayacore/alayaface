module App.Labels exposing
    ( foldListing
    , autoNameOnFirstPrompt
    , withLabelSave
    , forget
    , forgetAll
    , onSyncResult
    )

{-| The client half of the session label (G-series,
`docs/session-identity.md`): what a listing means, when a write is worth making,
and what happens when the write comes back.

`Session/Labels.elm` owns the DOCUMENT; this module owns the POLICY, because it is
the half that reads `Model`. Two modules rather than one is the same split F3 made
into `App/UiConfig` + `App/UiLayout` — and the same rule that forced it applies
here if the Model ever grows a field whose type comes from the document module:
`App.Types` would then import that module, which could never import `App.Types`
back (AGENTS.md's cycle rule). Today the Model carries just the NAME (see
`App.Types.sessionLabels` for why), so the split is a choice; it is the choice the
repo already made, which is the point of making it.

## The three rules this module exists to keep straight

  * **A listing fills gaps, it does not overwrite.** `foldListing` prefers what
    this process already believes (SD-G6/G7). A refresh that lands while a save
    is in flight would otherwise resurrect the name the user just changed, and
    "I renamed it and it went back" is the kind of bug no test of the final
    model would catch.
  * **A name the user chose is never replaced by a derived one.** That guard
    lives HERE, in the one function that can produce an auto save
    (`autoNameOnFirstPrompt`), not in the callers — SD-G8 is a rule about writes,
    so it belongs where writes are made.
  * **A save happens at the end of an interaction, never during one** — the F3
    write policy (SD16) applied to a name: the auto write hangs off the send,
    and G2's editor commits on Enter/Save, not per keystroke.

## What is deliberately NOT here

No `titleFor` yet: the title bar keeps building `"Session <n>"` until G2, and an
accessor with no caller is how dead state gets born (F4.1 deleted exactly that —
a field written by nobody and read by nobody, plus its port and both transports).
G2 adds it together with `scripts/check-layout-invariants.sh`'s read-path
section, so the accessor and its enforcement arrive in the same commit.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import App.Types exposing (Model, Msg(..))
import Ports
import Session.Labels as L


{-| Fold a `list_session_dirs` reply into what this process believes.

`listed` comes from disk, `known` from earlier reads and this process's own
writes; `Dict.union known listed` keeps `known` on a conflict, which is the
precedence stated above. Entries this listing does not mention are kept: the
listing covers top-level sessions with a `session.alaya`, and a session created
five seconds ago may legitimately be missing from a listing taken before it.
-}
foldListing : List E.Value -> Model -> Model
foldListing listed model =
    let
        parsed =
            listed
                |> List.filterMap entryOf
                |> Dict.fromList
    in
    { model | sessionLabels = Dict.union model.sessionLabels parsed }


{-| One listing item → (identity, name), or Nothing when it carries no usable
name. A session with no name is not an error and not an entry: the fallback
chain in the view decides what to show (SD-G9), and storing an empty string would
put "no name" and "a name we could not read" in the same slot.

The reply carries the NAME (a string the backend already read from the document),
so this is a projection, not a document decode — the usability rules are shared
with the document reader via `Labels.usableText`, which is how "the title bar
shows what the manager shows" stays true across the three implementations.
-}
entryOf : E.Value -> Maybe ( String, String )
entryOf value =
    case D.decodeValue itemDecoder value |> Result.toMaybe of
        Just ( id, name ) ->
            Maybe.map (\usable -> ( id, usable )) name

        Nothing ->
            Nothing


itemDecoder : D.Decoder ( String, Maybe String )
itemDecoder =
    D.map2 Tuple.pair
        (D.field "id" D.string)
        (D.field "label" D.string
            |> D.maybe
            -- A missing or non-string `label` is Nothing; a present one still
            -- has to pass the shared usability rule (blank / over-cap are not
            -- names). Both branches end as `Maybe String`.
            |> D.map (Maybe.andThen L.usableText)
        )


{-| Derive and store a name from the first prompt of a session that has none
(SD-G8/G12). Idempotent by construction: once an entry exists — derived or
chosen — this writes nothing, so a second send in the same session cannot
overwrite the first name, and a user's rename can never be clobbered by a later
auto derivation.

`context.isNodeSession` is the SD-G15 gate: a plan node session has no name of
its own (its label path would also be wrong, since node dirs are nested under
the plan). The caller resolves that from `model.planNodeSessions` and passes it
in, because this module must not re-derive facts the dispatcher already has.
-}
autoNameOnFirstPrompt :
    { sessionsDir : String
    , sessionId : String
    , prompt : String
    , isNodeSession : Bool
    }
    -> (Model, Cmd Msg)
    -> (Model, Cmd Msg)
autoNameOnFirstPrompt context ( model, cmd ) =
    if context.isNodeSession then
        ( model, cmd )

    else
        case Dict.get context.sessionId model.sessionLabels of
            Just _ ->
                ( model, cmd )

            Nothing ->
                case L.autoFromPrompt context.prompt of
                    Just label ->
                        withLabelSave context.sessionsDir context.sessionId label ( model, cmd )

                    Nothing ->
                        ( model, cmd )


{-| THE only producer of a `sync_session_label` command, so "when is a name
written" is one grep (the `withUiSave` discipline, SD16/G2's INV-G2).

It also updates the local belief in the same step (with the NAME only — the
document's `auto` flag has no reader in the model, and storing it would be
carrying a field nobody asks): the write and the model must not disagree while
the reply is in flight, or a manager refresh would be the only thing that can
undo it. A blank label is a real request — it is how G2 clears a name — and it
reaches the document unchanged (the backend removes the file for a blank,
SD-G15).
-}
withLabelSave : String -> String -> L.Label -> (Model, Cmd Msg) -> (Model, Cmd Msg)
withLabelSave sessionsDir sessionId label ( model, cmd ) =
    ( { model | sessionLabels = Dict.insert sessionId label.text model.sessionLabels }
    , Cmd.batch
        [ cmd
        , Ports.syncSessionLabel
            { sessionId = sessionId
            , document = E.encode 2 (L.encode label)
            }
        ]
    )


{-| Forget a session this process no longer has. Nothing on disk needs pruning
(the label went with the directory), so this only stops the map from outliving
the identity — the same reason `uiLayout` is pruned on delete.
-}
forget : String -> Model -> Model
forget sessionId model =
    { model | sessionLabels = Dict.remove sessionId model.sessionLabels }


{-| The delete cascade's form: deleting a session takes its plans and their node
sessions with it (`collectCloseSetFromSession`), and every one of those
identities dies on disk. Passing the whole set, rather than calling `forget` at
five call sites, is the same choice `UiLayout.prune` makes — one list, one place.
-}
forgetAll : List String -> Model -> Model
forgetAll ids model =
    List.foldl forget model ids


{-| The reply of a label save. `ok` needs no follow-up: the model was already
updated by `withLabelSave`, and re-reading the file to confirm the bytes would
be a second source of truth for a value we just wrote.

A failure is reported and dropped (design: an auto-label failure must not
interrupt a send; G2 shows a rename failure in the manager's error row from its
own call site). Logging is the only thing that happens here — the write is
fire-and-forget otherwise, and a silent failure is how a name ends up missing
with nobody able to say why.
-}
onSyncResult : E.Value -> Model -> (Model, Cmd Msg)
onSyncResult raw model =
    case D.decodeValue syncDecoder raw |> Result.toMaybe of
        Just { ok, error } ->
            if ok then
                ( model, Cmd.none )

            else
                ( model, Ports.logWarn ("could not save the session name: " ++ error) )

        Nothing ->
            ( model, Cmd.none )


syncDecoder : D.Decoder { ok : Bool, error : String }
syncDecoder =
    D.map2 (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.maybe (D.field "error" D.string) |> D.map (Maybe.withDefault ""))
