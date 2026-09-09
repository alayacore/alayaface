module App.Presets exposing
    ( Info, Manager, Action(..)
    , emptyManager
    , open, close
    , copy, renameStart, setRenameInput, renameSave, renameCancel
    , toggleEdit, armDelete, confirmDelete, cancelDelete
    , dragStart, dragOver, dragEnd, drop
    , adoptList, adoptAction
    , movePreset
    )

{-| The Preset Manager: the list of presets, the overlay's view state, and every
transition that overlay makes.

The presets themselves are not a document this client owns — `~/.alayaface/presets/
<name>/` is written by the backend, one directory per preset — so unlike
`App.AsrConfig` / `Session.ModelConfig` / `App.UiConfig` there is no whole-file
write here and no "unmodelled field is deleted" hazard. What this module does own
is the **one order the user controls**, saved by `reorder_presets` into
`~/.alayaface/preset_order.conf`. That command is forgiving in a way that matters
here: it drops names the backend does not have and APPENDS the presets a submitted
list left out. So a truncated payload cannot lose a preset, but it can silently
reshuffle one to the end — which is why `drop` reorders the whole list and the
`Reorder` payload is derived from that list rather than from the drag indices.

Two more facts are worth knowing before editing:

  - The wire key for a seed preset is `is_seed`; the record field is `isSeed`.
    `presetInfoDecoder` is the only place that bridges them.
  - `Simple` and `Complex` are seeded and referenced by the plan contract, so the
    backend rejects renaming and deleting them and the manager hides the buttons
    (see `Info.isSeed`). The UI refusing is a courtesy; the refusal that matters is
    the backend's, so a client bug cannot strand the contract. A COPY, by contrast,
    is the supported way to fork a seed — the backend only refuses a target name
    that already exists ("Preset already exists"), which is what `nextCopyName`
    proposes a free one to avoid.

Pure by the rule in AGENTS.md: `App.Types` types two of its `Model` fields with
these types, so importing `App.Types` back would be a cycle. Effects leave as
`Action` data; `App.Update`'s `applyPresetAction` is the only mapper to ports.
-}

import Set
import Json.Decode as D
import Json.Encode as E


-- ─── The state ─────────────────────────────────────────────────────

{-| One preset as the backend lists it.
-}
type alias Info =
    { name : String

    -- Built-in seed preset (Simple/Complex): referenced by the seeded plan
    -- contract, so it cannot be renamed (the backend rejects it and the manager
    -- hides the Rename button).
    , isSeed : Bool
    }


{-| The overlay's view state.

`busy` is why `close` refuses: an action in flight would be answered by a reply
nobody is listening to. `dragFrom`/`dragOver` are PRESET indices, not rendered row
indices — a preset that is open for editing shows extra rows below its main row,
and counting rows is what made the first version of this drop into the wrong slot.
-}
type alias Manager =
    { show : Bool
    , loading : Bool
    , busy : Bool
    , renaming : Maybe String
    , renameInput : String
    , editing : Maybe String
    , confirmDelete : Maybe String
    , error : Maybe String
    , dragFrom : Maybe Int
    , dragOver : Maybe Int
    }


emptyManager : Manager
emptyManager =
    { show = False
    , loading = False
    , busy = False
    , renaming = Nothing
    , renameInput = ""
    , editing = Nothing
    , confirmDelete = Nothing
    , error = Nothing
    , dragFrom = Nothing
    , dragOver = Nothing
    }


{-| What a transition wants from the backend. Data, not commands.
-}
type Action
    = List
    | Copy String String
    | Rename String String
    | Delete String
    | Reorder (List String)



-- ─── The schema this client reads ─────────────────────────────────

presetInfoDecoder : D.Decoder Info
presetInfoDecoder =
    D.map2 Info
        (D.field "name" D.string)
        (D.field "is_seed" D.bool)


{-| A `list_presets` reply.
-}
listReplyDecoder : D.Decoder { ok : Bool, presets : List Info, error : String }
listReplyDecoder =
    D.map3
        (\ok presets error -> { ok = ok, presets = presets, error = error })
        (D.field "ok" D.bool)
        (D.field "presets" (D.list presetInfoDecoder))
        (D.field "error" D.string)


{-| The reply of every action command (copy / rename / delete / reorder). All
four answer with the same `{ ok, error }` shape, which is why one decoder serves
them and `adoptAction` cannot tell which one it is answering — it does not need
to, because a success re-reads the list either way.
-}
actionReplyDecoder : D.Decoder { ok : Bool, error : String }
actionReplyDecoder =
    D.map2
        (\ok error -> { ok = ok, error = error })
        (D.field "ok" D.bool)
        (D.field "error" D.string)



-- ─── Transitions ───────────────────────────────────────────────────

{-| Open the manager: list view, and a read to fill it.
-}
open : ( Manager, List Action )
open =
    ( { emptyManager | show = True, loading = True }, [ List ] )


{-| Close it, refusing while an action is in flight.
-}
close : Manager -> Manager
close pm =
    if pm.busy then
        pm

    else
        emptyManager


{-| Copy a preset under a generated name. The name is chosen client-side because
only the client knows what the user is looking at, and `nextCopyName` never
proposes a name already on the list. It is a proposal, not a claim: a preset
created in another client between the read and the click still wins, and the
backend's rejection surfaces from the reply.
-}
copy : String -> List Info -> Manager -> ( Manager, List Action )
copy source presets pm =
    ( { pm | busy = True, error = Nothing }
    , [ Copy source (nextCopyName source presets) ]
    )


{-| The name a copy will get: `X-copy`, then `X-copy-2`, `X-copy-3`, … past the
names currently listed.
-}
nextCopyName : String -> List Info -> String
nextCopyName source presets =
    let
        taken =
            List.map .name presets |> Set.fromList

        base =
            source ++ "-copy"

        find n =
            let
                cand =
                    base ++ "-" ++ String.fromInt n
            in
            if Set.member cand taken then
                find (n + 1)

            else
                cand
    in
    if Set.member base taken then
        find 2

    else
        base


renameStart : String -> Manager -> Manager
renameStart name pm =
    { pm | renaming = Just name, renameInput = name }


{-| Typing the new name clears the error line, so a message about the previous
attempt does not sit under a value that might fix it.
-}
setRenameInput : String -> Manager -> Manager
setRenameInput val pm =
    { pm | renameInput = val, error = Nothing }


renameSave : String -> Manager -> ( Manager, List Action )
renameSave oldName pm =
    ( { pm | busy = True, error = Nothing }
    , [ Rename oldName pm.renameInput ]
    )


renameCancel : Manager -> Manager
renameCancel pm =
    { pm | renaming = Nothing, renameInput = "" }


{-| Which preset's edit sections (Settings / Models / MCP) are expanded. Toggled,
because the rows are the only way in and there is no other affordance to close
them.
-}
toggleEdit : String -> Manager -> Manager
toggleEdit name pm =
    { pm
        | editing =
            if pm.editing == Just name then
                Nothing

            else
                Just name
    }


armDelete : String -> Manager -> Manager
armDelete name pm =
    { pm | confirmDelete = Just name }


{-| The armed confirm, pressed. Clears the confirm as it goes: the list is about
to change under the row, so an armed state pointing at that row must not survive.
-}
confirmDelete : String -> Manager -> ( Manager, List Action )
confirmDelete name pm =
    ( { pm | busy = True, error = Nothing, confirmDelete = Nothing }
    , [ Delete name ]
    )


cancelDelete : Manager -> Manager
cancelDelete pm =
    { pm | confirmDelete = Nothing }


dragStart : Int -> Manager -> Manager
dragStart idx pm =
    { pm | dragFrom = Just idx, dragOver = Just idx }


dragOver : Int -> Manager -> Manager
dragOver idx pm =
    { pm | dragOver = Just idx }


dragEnd : Manager -> Manager
dragEnd pm =
    { pm | dragFrom = Nothing, dragOver = Nothing }


{-| Release on row `to`: reorder locally and write the new order.

Without a pending drag this changes and writes nothing — a stray drop event
reaches this same message, and an order built from a `Nothing` source would be an
order built from nothing at all.
-}
drop : Int -> List Info -> Manager -> ( List Info, Manager, List Action )
drop to presets pm =
    case pm.dragFrom of
        Just from ->
            let
                reordered =
                    movePreset from to presets
            in
            ( reordered
            , dragEnd pm
            , [ Reorder (List.map .name reordered) ]
            )

        Nothing ->
            ( presets, pm, [] )


{-| Adopt a `list_presets` reply, including the re-read after a successful action.
`Nothing` means the body was not a reply: leave the manager (and its `loading`)
exactly as it is. On a failed read the presets passed in are handed back unchanged
— the list a user is looking at beats an empty one that could not be read.
-}
adoptList : E.Value -> List Info -> Manager -> Maybe ( List Info, Manager )
adoptList raw presets pm =
    case D.decodeValue listReplyDecoder raw |> Result.toMaybe of
        Just res ->
            if res.ok then
                Just ( res.presets, { pm | loading = False, error = Nothing } )

            else
                Just ( presets, { pm | loading = False, error = Just res.error } )

        Nothing ->
            Nothing


{-| Adopt an action reply. Success clears the pending rename/delete state and asks
for the list again — the client does not guess what the backend called a new copy
or whether a rename cascaded, it re-reads.
-}
adoptAction : E.Value -> Manager -> Maybe ( Manager, List Action )
adoptAction raw pm =
    case D.decodeValue actionReplyDecoder raw |> Result.toMaybe of
        Just res ->
            if res.ok then
                Just
                    ( { pm
                        | busy = False
                        , renaming = Nothing
                        , renameInput = ""
                        , confirmDelete = Nothing
                      }
                    , [ List ]
                    )

            else
                Just ( { pm | busy = False, error = Just res.error }, [] )

        Nothing ->
            Nothing



-- ─── List arithmetic ───────────────────────────────────────────────

{-| Move the item at index `from` to index `to` (0-based, clamped to the list
bounds). See the note on `Manager` about why these are preset indices.
-}
movePreset : Int -> Int -> List a -> List a
movePreset from to list =
    let
        len =
            List.length list

        f =
            clamp 0 (len - 1) from

        t =
            clamp 0 (len - 1) to
    in
    if len <= 1 || f == t then
        list

    else
        case List.drop f list of
            item :: rest ->
                let
                    withoutItem =
                        List.take f list ++ rest
                in
                List.take t withoutItem
                    ++ (item :: List.drop t withoutItem)

            [] ->
                list
