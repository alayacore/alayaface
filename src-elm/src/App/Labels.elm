module App.Labels exposing
    ( foldListing
    , titleFor
    , titleTooltip
    , rowName
    , rowTooltip
    , targetCaption
    , filteredRows
    , openRename
    , closeRename
    , renameInput
    , commitRename
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

## The one read path (INV-G1)

Four accessors read `sessionLabels` and nothing else may: `titleFor` (a window's
bar), `titleTooltip`, `rowName` (a Session Manager row) and `openRename`'s
prefill. Two of them disagree about the fallback ON PURPOSE — a window falls back
to its seat number, a list row falls back to its id prefix (SD-G15) — which is
exactly why they must sit in one file: a screen is not allowed a private idea of
what a session is called. The `Session <n>` construction lives here and
`scripts/check-layout-invariants.sh` (section 5) fails any other module that
builds it, along with any other read of the map and any second caller of the
write port.

The list rules live here too (`filteredRows`), because "which rows does this
filter keep" is a question about names.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import App.Types exposing (Model, Msg(..))
import Ports
import Session.Labels as L
import Session.Selector as Sel


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


{-| The NAME a window is called (SD-G14): the session's own name if it has one,
otherwise the seat number the app has always shown. The ` — <model>` half is the
caller's (the view), because which model a window is talking to is load-bearing
while debugging and must survive a name being set or cleared.

The fallback is `Session <n>`, and `n` comes from `sessionNums`, which
`Main.elm` restarts at 1 per page load — so an unnamed session's title is NOT a
stable handle. That is the whole reason this feature exists (SD-G12 derives a
name instead of asking the user to build one), and it is why `titleTooltip`
always carries the identity.
-}
titleFor : Model -> String -> String
titleFor model id =
    Maybe.withDefault (seatOf model id) (Dict.get id model.sessionLabels)


{-| The full name for a tooltip: the name verbatim (a truncated one in the bar is
never a lost one) plus the session id, which is the only stable handle for an
unnamed session.
-}
titleTooltip : Model -> String -> String
titleTooltip model id =
    titleFor model id ++ "\n" ++ id


seatOf : Model -> String -> String
seatOf model id =
    "Session "
        ++ String.fromInt
            (Maybe.withDefault 0 (Dict.get id model.sessionNums))


{-| The NAME a Session Manager row shows. Two differences from `titleFor`, both
of them the design's (SD-G15):

  * an unnamed session falls back to its **8-character id**, not to `Session <n>`.
    A seat number is reassigned by the next page load, so it cannot help you find
    a session again — which is the only thing a list of closed sessions is for.
    A differing hex prefix at least discriminates between rows.
  * so the two accessors disagree on purpose, and both live HERE: one screen is
    not allowed a private idea of what a session is called (INV-G1).

Used by the row, the filter, the sort and the rename editor's title — four
callers, one rule.
-}
rowName : Model -> String -> String
rowName model id =
    Maybe.withDefault (String.left 8 id) (Dict.get id model.sessionLabels)


{-| The identity line inside the rename editor: WHICH session this box is about.

Neither of the two name accessors can serve here. `rowName`/`titleFor` would
print the name the user is in the middle of replacing — and for a session that
has none, the very string they are being asked to change. So this is the raw
identity prefix, which no rename can alter.

It lives here rather than in the view because this module owns what a session is
called (INV-G1) — and the check that enforces it caught this exact line being
built in `App/View.elm` while it was being written. `App/Labels` is where a
reader looks for every string a session can be shown by.
-}
targetCaption : String -> String
targetCaption sessionId =
    "Renaming " ++ String.left 8 sessionId


{-| A row's tooltip: the name it shows plus the identity behind it. The id is
always there because a NAME is the thing most likely to be ambiguous — two
sessions can be called the same thing, and the hex is the only tiebreaker.
-}
rowTooltip : Model -> String -> String
rowTooltip model id =
    rowName model id ++ "\n" ++ id


{-| The manager's list after the filter box has had its say.

Blank term → the list untouched, which is the backends' order (modification time).
Non-blank → name-matched, then sorted by name: an alphabetised result is the
point of typing three letters, and leaving it in mtime order would make the
filter feel like it had shuffled the board.

Matching goes through `Session.Selector.filterItems`, the function the model
selector already uses — trimming, lower-casing and "empty term means everything"
are its behaviour, not a re-derivation of it (INV-G1's argument applies to list
rules too: a second implementation is a second opinion). It had one, in
`Overlay/Selector.elm`, byte-identical; that copy is gone and the module imports
the original, which is why this is the third caller of ONE rule rather than the
third caller of two rules that happen to agree today.

The id is part of the key, so a user who knows the hex prefix and does not know
the name is not filtered out of finding their own session.
-}
filteredRows : Model -> String -> (item -> String) -> List item -> List item
filteredRows model term idOf items =
    let
        key =
            \item -> rowName model (idOf item) ++ " " ++ idOf item

        sorted =
            Sel.filterItems key items term
                |> List.sortBy (\item -> String.toLower (key item))
    in
    if String.trim term == "" then
        items

    else
        sorted


{-| Open the rename editor for one session (INV-G1: the prefill reads the name
map, so it belongs in this module). Prefilled with the name if it has one and
blank if not — NOT with the row's fallback, or renaming a session you never
named would quietly name it `1a2b3c4d`.
-}
openRename : String -> Model -> Model
openRename sessionId model =
    { model
        | labelEditor =
            L.open sessionId (Maybe.withDefault "" (Dict.get sessionId model.sessionLabels))
    }


closeRename : Model -> Model
closeRename model =
    { model | labelEditor = L.close model.labelEditor }


renameInput : String -> Model -> Model
renameInput text model =
    { model | labelEditor = L.input text model.labelEditor }


{-| Commit the rename editor: Save, Enter, or a blur. The rules are
`Session.Labels.commit`'s (this function only decides what the outcome costs);
this is the second of the design's two write triggers, and `withLabelSave` below
keeps it the same single port call as the first.

Clearing is the interesting one. A blank field is a request to REMOVE the name,
so the model must lose the entry rather than store `""`: `titleFor` reads
presence, and a `Just ""` would render a title bar with nothing in it — the one
outcome worse than a seat number. The port still fires, because the file has to
go away on disk too (the backend deletes it, SD-G15's no-tombstone rule).
-}
commitRename : String -> Model -> ( Model, Cmd Msg )
commitRename sessionsDir model =
    let
        target =
            model.labelEditor.targetId

        ( editor, outcome ) =
            L.commit model.labelEditor

        m1 =
            { model | labelEditor = editor }
    in
    case outcome of
        L.Reject _ ->
            ( m1, Cmd.none )

        L.Named label ->
            withLabelSave sessionsDir target label ( m1, Cmd.none )

        L.Blank ->
            withLabelSave sessionsDir target { text = "", auto = False } ( m1, Cmd.none )
                |> (\( m2, cmd ) -> ( forget target m2, cmd ))


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

A failure is logged always, and SHOWN when the manager is open. That is the
design's split (a failed rename belongs in `sessionManagerError`, a failed
auto-label must not interrupt a send), and one boolean decides between them
because a rename can only be started from the manager and the manager covers the
board, so no send is in flight while it is up. The reply carries the identity
this write was for (the bridge echoes it — `transport.js`), so the message names
the session rather than saying "a name failed": with thirty rows on screen, an
unattributed failure is the mis-attribution SD-G16 exists to prevent, just
narrower.
-}
onSyncResult : E.Value -> Model -> ( Model, Cmd Msg )
onSyncResult raw model =
    case D.decodeValue syncDecoder raw |> Result.toMaybe of
        Just { ok, error, sessionId } ->
            if ok then
                ( model, Cmd.none )

            else if model.showSessionManager then
                ( { model
                    | sessionManagerError =
                        Just
                            ("Could not save the name of "
                                ++ rowName model sessionId
                                ++ ": "
                                ++ error
                            )
                  }
                , Ports.logWarn ("could not save the session name: " ++ error)
                )

            else
                ( model, Ports.logWarn ("could not save the session name: " ++ error) )

        Nothing ->
            ( model, Cmd.none )


syncDecoder : D.Decoder { ok : Bool, error : String, sessionId : String }
syncDecoder =
    D.map3 (\ok error sessionId -> { ok = ok, error = error, sessionId = sessionId })
        (D.field "ok" D.bool)
        (D.maybe (D.field "error" D.string) |> D.map (Maybe.withDefault ""))
        -- Absent on a reply from a bridge older than the rename editor, and
        -- harmless then: the id is only used to name the session in the message.
        (D.maybe (D.field "sessionId" D.string) |> D.map (Maybe.withDefault ""))
