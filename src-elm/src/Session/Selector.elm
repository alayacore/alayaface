module Session.Selector exposing
    ( Page(..)
    , State
    , empty
    , isDirty
    , open
    , setList
    , setLoadError
    , setInput
    , selectItem
    , selectedItem
    , openEdit
    , backFromEdit
    , updateDraft
    , saveItem
    , requestDelete
    , confirmDeleteItem
    , cancelDelete
    , closeRequest
    , close
    , startSync
    , syncFailed
    , askSync
    , backToList
    , setLoading
    , filterItems
    )

import Fuzzy

{-| Shared state machine for the three list-based configuration
selectors (per-session model selector, the global default-model
editor, and the MCP server editor).

All three previously duplicated the same logic: a searchable list
page, an edit form page, an unsaved-changes confirm-sync prompt, a
syncing page, and a failure page. This module captures that flow once,
purely — no ports, no UI — so it can be unit-tested and reused.

The state is parameterized over the list item type and the draft
type; the caller supplies the item↔draft conversions and search key.
-}


-- Pages

type Page
    = ModelSelList
    | ModelSelEdit
    | ModelSelConfirmSync
    | ModelSelSyncing
    | ModelSelSyncFailed
    | ModelSelLoading


-- State

type alias State item draft =
    { page : Page
    , input : String
    , selected : Int
    , working : List item
    , original : List item
    , draft : Maybe draft
    , confirmDelete : Maybe Int
    , loadError : Maybe String
    , syncError : Maybe String
    }


empty : State item draft
empty =
    { page = ModelSelList
    , input = ""
    , selected = 0
    , working = []
    , original = []
    , draft = Nothing
    , confirmDelete = Nothing
    , loadError = Nothing
    , syncError = Nothing
    }


-- Queries

isDirty : State item draft -> Bool
isDirty st =
    st.working /= st.original


-- Transitions

{-| Open the selector: reset to a fresh list page seeded from `source`.
-}
open : List item -> State item draft -> State item draft
open source st =
    { st
        | page = ModelSelList
        , input = ""
        , selected = 0
        , working = source
        , draft = Nothing
        , confirmDelete = Nothing
        , syncError = Nothing
    }


{-| Populate the list from a load result (editors load asynchronously).
-}
setList : List item -> State item draft -> State item draft
setList items st =
    { st
        | page = ModelSelList
        , working = items
        , original = items
        , loadError = Nothing
    }


setLoadError : Maybe String -> State item draft -> State item draft
setLoadError err st =
    { st
        | page = ModelSelList
        , loadError = err
    }


{-| Update the search input, clamping the selection when the filter
shrinks the list.
-}
setInput : (item -> String) -> String -> State item draft -> State item draft
setInput search val st =
    let
        filtered =
            filterItems search st.working val

        clampedSelected =
            if List.length filtered <= st.selected then
                max 0 (List.length filtered - 1)

            else
                st.selected
    in
    { st
        | input = val
        , selected = clampedSelected
    }


selectItem : Int -> State item draft -> State item draft
selectItem idx st =
    { st | selected = idx }


{-| The currently selected item after filtering, if any.
-}
selectedItem : (item -> String) -> State item draft -> Maybe item
selectedItem search st =
    List.head (List.drop st.selected (filterItems search st.working st.input))


openEdit : draft -> State item draft -> State item draft
openEdit d st =
    { st
        | page = ModelSelEdit
        , draft = Just d
        , confirmDelete = Nothing
    }


backFromEdit : State item draft -> State item draft
backFromEdit st =
    { st
        | page = ModelSelList
        , draft = Nothing
    }


updateDraft : (draft -> draft) -> State item draft -> State item draft
updateDraft fn st =
    { st | draft = Maybe.map fn st.draft }


{-| Persist the current draft into `working`. New items (draft id 0)
are appended with the next free id; existing items are replaced.
-}
saveItem : (draft -> Int) -> (draft -> item) -> (item -> Int) -> State item draft -> State item draft
saveItem draftId draftToItem itemId st =
    case st.draft of
        Just draft ->
            let
                newItem =
                    draftToItem draft

                working =
                    if draftId draft == 0 then
                        let
                            nextId =
                                List.foldl (\m acc -> max acc (itemId m)) 0 st.working + 1
                        in
                        st.working ++ [ newItem ]

                    else
                        List.map
                            (\m -> if itemId m == draftId draft then newItem else m)
                            st.working
            in
            { st
                | page = ModelSelList
                , working = working
                , draft = Nothing
            }

        Nothing ->
            st


requestDelete : Int -> State item draft -> State item draft
requestDelete id st =
    { st | confirmDelete = Just id }


confirmDeleteItem : (item -> Int) -> Int -> State item draft -> State item draft
confirmDeleteItem itemId id st =
    { st
        | working = List.filter (\m -> itemId m /= id) st.working
        , confirmDelete = Nothing
    }


cancelDelete : State item draft -> State item draft
cancelDelete st =
    { st | confirmDelete = Nothing }


{-| What should happen when the user asks to close?
`Nothing` blocks the close (sync in flight); `Just True` requires an
unsaved-changes confirmation; `Just False` closes cleanly.
-}
closeRequest : State item draft -> Maybe Bool
closeRequest st =
    if st.page == ModelSelSyncing then
        Nothing

    else
        Just (isDirty st)


{-| Close cleanly: reset to an empty list page.
-}
close : State item draft -> State item draft
close st =
    { st
        | page = ModelSelList
        , input = ""
        , selected = 0
        , working = []
        , draft = Nothing
        , confirmDelete = Nothing
        , syncError = Nothing
    }


startSync : State item draft -> State item draft
startSync st =
    { st
        | page = ModelSelSyncing
        , syncError = Nothing
    }


syncFailed : String -> State item draft -> State item draft
syncFailed err st =
    { st
        | page = ModelSelSyncFailed
        , syncError = Just err
    }


{-| Show the unsaved-changes confirmation page (before syncing/closing).
-}
askSync : State item draft -> State item draft
askSync st =
    { st | page = ModelSelConfirmSync }


{-| Return from the confirm-sync or failure page to the list.
-}
backToList : State item draft -> State item draft
backToList st =
    { st | page = ModelSelList }


{-| Show the loading page (editors load asynchronously).
-}
setLoading : State item draft -> State item draft
setLoading st =
    { st | page = ModelSelLoading }


-- Filtering

{-| Keep items whose search key fuzzy-matches the trimmed term
(case-insensitive). An empty term keeps everything.
-}
filterItems : (item -> String) -> List item -> String -> List item
filterItems search items term =
    let
        trimmed =
            String.trim term

        needle =
            String.toLower trimmed
    in
    if String.isEmpty trimmed then
        items

    else
        List.filter (\m -> Fuzzy.fuzzyMatch needle (String.toLower (search m))) items
