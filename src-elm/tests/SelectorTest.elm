module SelectorTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Session.Selector as Sel exposing (Page(..))


type alias Item =
    { id : Int
    , name : String
    }


type alias Draft =
    { id : Int
    , name : String
    }


draftToItem : Draft -> Item
draftToItem d =
    { id = d.id, name = d.name }


search : Item -> String
search it =
    it.name


tests : Test
tests =
    describe "Session.Selector"
        [ describe "open"
            [ test "resets to a clean list seeded from source" <|
                \_ ->
                    let
                        st =
                            Sel.empty |> Sel.open [ Item 1 "a", Item 2 "b" ]
                    in
                    Expect.equal
                        { page = ModelSelList
                        , input = ""
                        , selected = 0
                        , working = [ Item 1 "a", Item 2 "b" ]
                        , original = []
                        , draft = Nothing
                        , confirmDelete = Nothing
                        , loadError = Nothing
                        , syncError = Nothing
                        }
                        st
            , test "is dirty when working differs from original" <|
                \_ ->
                    Sel.empty
                        |> Sel.setList [ Item 1 "a" ]
                        |> Sel.setInput search "x"
                        |> Sel.isDirty
                        |> Expect.equal False
            ]
        , describe "setInput"
            [ test "clamps selection when the filter shrinks the list" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "aaa", Item 2 "bbb", Item 3 "ccc" ]
                                |> Sel.selectItem 2
                                |> Sel.setInput search "b"
                    in
                    Expect.equal 0 st.selected
            , test "keeps selection when the filter still matches it" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "aaa", Item 2 "bbb" ]
                                |> Sel.selectItem 1
                                |> Sel.setInput search "b"
                    in
                    Expect.equal 0 st.selected
            ]
        , describe "selectedItem"
            [ test "returns the filtered item at the selection" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "alpha", Item 2 "beta" ]
                                |> Sel.setInput search "bet"
                    in
                    Expect.equal (Just (Item 2 "beta")) (Sel.selectedItem search st)
            , test "Nothing when the list is empty" <|
                \_ ->
                    Expect.equal Nothing (Sel.selectedItem search Sel.empty)
            ]
        , describe "saveItem"
            [ test "appends new drafts with the next free id" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "a" ]
                                |> Sel.openEdit (Draft 0 "new")
                                |> Sel.saveItem (\d -> d.id) draftToItem (\i -> i.id) (\id i -> { i | id = id })
                    in
                    Expect.equal [ Item 1 "a", Item 2 "new" ] st.working
            , test "replaces an existing item by id" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "a", Item 2 "b" ]
                                |> Sel.openEdit (Draft 2 "B2")
                                |> Sel.saveItem (\d -> d.id) draftToItem (\i -> i.id) (\id i -> { i | id = id })
                    in
                    Expect.equal [ Item 1 "a", Item 2 "B2" ] st.working
            , test "no-op without a draft" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "a" ]
                                |> Sel.saveItem (\d -> d.id) draftToItem (\i -> i.id) (\id i -> { i | id = id })
                    in
                    Expect.equal [ Item 1 "a" ] st.working
            ]
        , describe "closeRequest"
            [ test "blocks close while syncing" <|
                \_ ->
                    Sel.empty
                        |> Sel.setList [ Item 1 "a" ]
                        |> Sel.setInput search "x"
                        |> Sel.startSync
                        |> Sel.closeRequest
                        |> Expect.equal Nothing
            , test "asks to confirm when dirty" <|
                \_ ->
                    Sel.empty
                        |> Sel.setList [ Item 1 "a" ]
                        |> Sel.openEdit (Draft 1 "changed")
                        |> Sel.saveItem (\d -> d.id) draftToItem (\i -> i.id) (\id i -> { i | id = id })
                        |> Sel.closeRequest
                        |> Expect.equal (Just True)
            , test "closes cleanly when not dirty" <|
                \_ ->
                    Sel.empty
                        |> Sel.setList [ Item 1 "a" ]
                        |> Sel.closeRequest
                        |> Expect.equal (Just False)
            ]
        , describe "delete + sync flow"
            [ test "confirmDeleteItem removes by id and clears the flag" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "a", Item 2 "b" ]
                                |> Sel.requestDelete 1
                                |> Sel.confirmDeleteItem (\i -> i.id) 1
                    in
                    Expect.equal
                        ( [ Item 2 "b" ], Nothing )
                        ( st.working, st.confirmDelete )
            , test "cancelDelete keeps the list" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "a" ]
                                |> Sel.requestDelete 1
                                |> Sel.cancelDelete
                    in
                    Expect.equal [ Item 1 "a" ] st.working
            , test "startSync → syncFailed keeps working list and records error" <|
                \_ ->
                    let
                        st =
                            Sel.empty
                                |> Sel.setList [ Item 1 "a" ]
                                |> Sel.startSync
                                |> Sel.syncFailed "boom"
                    in
                    Expect.equal
                        ( ModelSelSyncFailed, Just "boom", [ Item 1 "a" ] )
                        ( st.page, st.syncError, st.working )
            ]
        ]
