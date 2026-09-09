module App.UiLayout exposing
    ( decodeGet
    , decodeSyncResult
    , markLoaded
    , applyLoaded
    , syncUiLayout
    , withUiSave
    , attachPendingSolo
    , prune
    )

{-| The client half of the layout store (F3): the fold between the live board
and `ui.conf`.

`App/UiConfig.elm` owns the SCHEMA (what a document is); this module owns the
POLICY (what the document says about the current board, and what may be trusted
when reading one back). Together they are the whole reason a restart can put
windows back:

  * `applyLoaded` — the read at startup. Everything from the file goes through a
    validation here or in `App/Windows` (`storedRect`, `storedScale`,
    `storedOffset`); nothing unvalidated reaches the Model.
  * `absorb` — fold the live board into the store, touching only the rects that
    actually moved. Called by `syncUiLayout`, never on its own.
  * `syncUiLayout` / `withUiSave` — THE ONLY PRODUCER of a `sync_ui_config`
    payload, and the single spelling of "an interaction just ended, remember the
    board". One function can build a document, which is what keeps SD16's list
    of write triggers from becoming six slightly different savers.
  * `prune` — drop memory of an identity that is GONE (a deleted session, a
    removed plan subtree). Closing a window does NOT prune: that identity may be
    reopened, and its rect is the whole point (SD15).
  * the `uiLoaded` gate — no write happens at all until the startup read has
    ANSWERED. A client that never saw the file must not be allowed to replace
    it: an empty store published as a document is a deleted layout with no trace
    (`markLoaded` is called by both successful outcomes, including "no file").

## What is deliberately not written here

The write TRIGGERS (pointerup, create, close, solo, session close, the zoom idle
tick) live in `App/Update.elm`, which owns when an interaction has ended, and the
ports live there too — this module is pure so the policy can be elm-tested
without a runtime (INV6). The rule it exists to enforce is simple: a save
happens at the END of an interaction, never during one.

## Two solos, and which one this module may touch

`Model.soloWin` is the live presentation state, readable only through
`App/Windows.soloKey` (INV2b/INV3). `Model.uiSoloPending` is a RESTORE INTENT
that came from the file naming a window that does not exist yet. This module
never reads the former directly, and the gate that keeps it that way is
`scripts/check-layout-invariants.sh`.

## What this fold does NOT solve

`sync_ui_config` replaces the file, and two clients on one HOME (the Go server
is reachable over SSH/LAN, and AGENTS.md's `clientId` exists precisely because
tabs coexist) each write the WHOLE document they believe in. So the last write
wins and the other tab's rects are lost — no merge, no per-window patch, no
lock. That is inherited from SD15's "geometry only, one document" choice, not
overlooked: merging two boards' window positions would need a notion of which
client the user is looking through, and the resulting file could describe a
board neither tab has. The cost is bounded and symmetric — a clobbered tab still
has its own board on screen and rewrites the file on its next interaction end.
If F3's successor ever adds per-client keys, THIS paragraph is the constraint it
has to satisfy, and `UiConfig`'s top-level `extras` are the escape hatch.

## The field this module must not forget

`uiExtras`: `sync_ui_config` replaces the file, so a top-level key this build
does not model has to travel back out untouched, or an older AlayaFace deletes a
newer one's work — the `model.conf` hazard AGENTS.md records twice. Per-window
keys cannot be carried (see `App/UiConfig`'s header), which is why a new per-
window field is a schema change in this module and not an accident waiting to
happen.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import App.Types exposing (Model, Msg)
import App.UiConfig as UC
import App.Windows as Win
import Ports


{-| The `get_ui_config` envelope: `{ ok, version, config, error }`, where
`config` is the stored document verbatim or `null` when there is no file.

`Err` means the read FAILED (backend refused, transport down) — the caller logs
that, because a layout that is never written is a bug the user sees only at the
next restart. `Ok Nothing` means "there is no document", which is not a failure
and must not be logged as one. The document itself is decoded leniently by
`UiConfig.decode`; a body that is not an object at all is `Ok Nothing` too,
because there is nothing here worth salvaging and the placement rules are always
available.
-}
decodeGet : E.Value -> Result String (Maybe UC.Document)
decodeGet raw =
    let
        flag =
            D.decodeValue (D.field "ok" D.bool) raw |> Result.withDefault False

        errorText =
            D.decodeValue (D.field "error" D.string) raw |> Result.withDefault ""

        config =
            D.decodeValue (D.field "config" D.value) raw |> Result.toMaybe
    in
    if not flag then
        Err ("get_ui_config: " ++ (if errorText == "" then "backend refused the read" else errorText))

    else
        case config of
            Nothing ->
                Ok Nothing

            Just value ->
                if value == E.null then
                    Ok Nothing

                else
                    Ok (UC.decode value)


{-| Apply a document read at startup.

The board memory always lands. The VIEWPORT (pan/zoom) lands only onto an
untouched viewport: the read is asynchronous, and if the user has already panned
or zoomed by the time the answer arrives, applying the file would yank the board
out from under the gesture in progress. Losing the stored zoom in that one race
is the cheaper failure.

The solo key becomes a pending intent (see the module header) — the window it
names will usually not exist until the user reopens it.
-}
applyLoaded : UC.Document -> Model -> Model
applyLoaded doc model =
    let
        untouchedViewport =
            model.canvasOffset == { x = 0, y = 0 } && model.canvasScale == 1.0

        storedTouch =
            doc.windows |> Dict.values |> List.map .t |> List.maximum |> Maybe.withDefault 0
    in
    { model
        | uiLoaded = True
        , uiLayout = doc.windows
        , uiTouch = max storedTouch model.uiTouch
        , uiSoloPending = UC.soloIntent doc
        , uiExtras = doc.extras
        , canvasOffset =
            if untouchedViewport then
                Win.storedOffset doc.canvasOffset

            else
                model.canvasOffset

        , canvasScale =
            if untouchedViewport then
                Win.storedScale doc.canvasScale

            else
                model.canvasScale
    }


{-| Fold the live board into the store and bump the touch counter for the rects
that changed.

A window whose rect did NOT move keeps its old touch. Refreshing every entry on
every save would make `t` mean "least recently SAVED", and eviction (which drops
the oldest `t` first) would then throw away the rect of a window the user has not
touched in weeks in favour of one that merely happened to be open.


A live solo supersedes any pending restore intent — the user has expressed a
presentation choice, and the file must not resurrect an older one.
-}
absorb : Model -> Model
absorb model =
    let
        fold ( key, pos ) ( store, touch ) =
            let
                same e =
                    e.x == pos.x && e.y == pos.y && e.w == pos.w && e.h == pos.h

                touched =
                    touch + 1
            in
            case Dict.get key store of
                Just e ->
                    if same e then
                        ( store, touch )

                    else
                        ( Dict.insert key { e | x = pos.x, y = pos.y, w = pos.w, h = pos.h, t = touched } store
                        , touched
                        )

                Nothing ->
                    ( Dict.insert key { x = pos.x, y = pos.y, w = pos.w, h = pos.h, t = touched } store
                    , touched
                    )

        ( uiLayout1, uiTouch1 ) =
            List.foldl fold ( model.uiLayout, model.uiTouch ) (Win.layoutRects model)

        live =
            Win.soloKey model
    in
    { model
        | uiLayout = uiLayout1
        , uiTouch = uiTouch1
        , uiSoloPending =
            case live of
                Just _ ->
                    Nothing

                Nothing ->
                    model.uiSoloPending
    }


{-| The `sync_ui_config` envelope. Unlike the read, a successful write carries
nothing the client needs — the point of decoding it is the FAILURE: "the backend
refused my document" is otherwise indistinguishable from "nothing has changed".
-}
decodeSyncResult : E.Value -> Result String ()
decodeSyncResult raw =
    case D.decodeValue (D.field "ok" D.bool) raw of
        Ok True ->
            Ok ()

        _ ->
            let
                why =
                    D.decodeValue (D.field "error" D.string) raw
                        |> Result.withDefault "(no reason given)"
            in
            Err ("sync_ui_config refused: " ++ why)


{-| Absorb, bound, encode, send: the ONLY producer of a `sync_ui_config`
payload, and the only writer of the store's persisted half. One function so that
SD16's list of interaction-end triggers cannot become six slightly different
savers — and so that the unload flush, the zoom idle tick and a resize all agree
about what the file says right now.

Eviction protects the OPEN windows, taken from the board (`layoutRects`, not the
store): the backends refuse an oversized document rather than trim it, because
only this client knows which windows the user is looking at. When it does drop
something the count is logged — a silently shrinking cap is how a limit becomes a
bug report.

The model it returns carries the absorbed store (touch counter included), so a
caller that keeps the model keeps the memory consistent with the file it just
wrote.
-}
syncUiLayout : Model -> ( Model, Cmd Msg )
syncUiLayout model =
    if not model.uiLoaded then
        -- No read has answered yet (or it FAILED — see the Err branch in
        -- App/Update). Writing now would replace a file this process has never
        -- seen with a document assembled from an empty store: the layout would
        -- vanish at the next restart with nothing in the logs to explain it.
        ( model, Cmd.none )

    else
        let
            absorbed =
                absorb model

            openKeys =
                absorbed |> Win.layoutRects |> List.map Tuple.first

            solo =
                case Win.soloKey absorbed of
                    Just k ->
                        Just k

                    Nothing ->
                        absorbed.uiSoloPending

            doc =
                UC.fromStore
                    { solo = solo
                    , offset = absorbed.canvasOffset
                    , scale = absorbed.canvasScale
                    , windows = absorbed.uiLayout
                    , extras = absorbed.uiExtras
                    }

            ( bounded, dropped ) =
                UC.evict doc openKeys

            note =
                if dropped > 0 then
                    Ports.logWarn
                        ("ui.conf: dropped "
                            ++ String.fromInt dropped
                            ++ " stored window rect(s) over the cap of "
                            ++ String.fromInt UC.maxStoredWindows
                            ++ " (open windows are never dropped)"
                        )

                else
                    Cmd.none
        in
        ( { absorbed | uiLayout = bounded.windows }
        , Cmd.batch
            [ Ports.syncUiConfig { config = E.encode 0 (UC.encode bounded) }
            , note
            ]
        )


{-| The store has been read, so a document now exists to answer with. Called for
BOTH outcomes of a successful read — a real document, and "there is no file yet"
— because it is the FAILURE that must keep writes off: an `Err` leaves this flag
false, and the session then runs without ever replacing a file it could not see.

Separate from `applyLoaded` on purpose: the "no file" branch must apply nothing,
because a late answer would otherwise clear a store the user has already been
writing into.
-}
markLoaded : Model -> Model
markLoaded model =
    { model | uiLoaded = True }


{-| Pipe an arm's result through the layout write. Every SD16 trigger in
`App/Update.elm` is spelled `withUiSave` so that the complete set of moments this
feature writes on is one `grep` away — and so that adding a trigger is a
deliberate act rather than a new line inside an already-long arm.

It composes rather than replaces: whatever Cmd the arm already had to issue goes
out in the same batch, and the model it hands on is the absorbed one.
-}
withUiSave : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
withUiSave ( m, cmd ) =
    let
        ( m1, save ) =
            syncUiLayout m
    in
    ( m1, Cmd.batch [ cmd, save ] )


{-| A window that has just been created is the pending intent's key? Then solo
attaches (SD15 + INV2: the intent only ever becomes a live solo through the
sanctioned helper, and only for a window that exists). Idempotent: with no
matching intent this returns the model unchanged.
-}
attachPendingSolo : String -> Model -> Model
attachPendingSolo key model =
    case model.uiSoloPending of
        Just pending ->
            if pending == key then
                { model | uiSoloPending = Nothing } |> Win.enterSolo key

            else
                model

        Nothing ->
            model


{-| Forget an identity that is gone for good — a deleted session, a removed plan
subtree. NOT called when a window merely closes: that entry is the reason
reopening the session puts the window back where the user left it.
-}
prune : List String -> Model -> Model
prune deadKeys model =
    { model | uiLayout = List.foldl Dict.remove model.uiLayout deadKeys }
