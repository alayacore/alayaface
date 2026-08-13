module App.SelectorKit exposing
    ( Kit
    , focusAfterDelay
    , focusAndCursor
    , focusPrompt
    , setInput
    , selectItem
    , confirmItem
    , editItem
    , addItem
    , editBack
    , editSave
    , editField
    , deleteItem
    , confirmDelete
    , cancelDelete
    , confirmSync
    , discardClose
    , cancelSyncPrompt
    , syncSuccess
    , syncFailed
    )

{-| Parameterized update glue shared by the three list-based
configuration selectors: the per-session model selector, the global
default-model editor, and the MCP server editor.

`Session.Selector` captures the pure state machine and `Overlay.Selector`
the shared view; this module captures the shared *update* logic so the
App/Update handlers are one-liners instead of ~150 duplicated lines per
feature. Each feature supplies a `Kit` describing how to read/write its
state, name and id accessors, DOM ids, and the few genuinely custom
behaviors (confirm action, sync command, post-close focus).

Focus helpers live here too because every kit handler needs them and
App.Update cannot be imported from here (it would be circular).
-}

import App.Types exposing (Model, Msg(..))
import Browser.Dom as Dom
import Process
import Session.Selector as Sel
import Task
import Ports


-- KIT CONFIGURATION


type alias Kit item draft =
    { get : Model -> Sel.State item draft
    , set : Sel.State item draft -> Model -> Model
    , setShow : Bool -> Model -> Model
    , nameOf : item -> String
    , idOf : item -> Int
    , setIdOf : Int -> item -> item
    , draftOf : item -> draft
    , emptyDraft : draft
    , draftIdOf : draft -> Int
    , itemOfDraft : draft -> item
    , updateDraftField : String -> String -> draft -> draft
    , inputId : Model -> String
    , editorId : Model -> String
    , scrollItemId : Model -> Int -> String
      -- Confirm action: the item id is passed (single click / Enter on
      -- a row). Per-session sets the active model; the preset editor
      -- sets the default model; the MCP editor opens the edit page.
    , confirm : Int -> Model -> ( Model, Cmd Msg )
      -- Command sent when the user confirms the sync prompt.
    , syncCmd : Model -> Cmd Msg
      -- Model transition on successful sync (close + focus vs reset editor).
    , syncSuccess : Model -> ( Model, Cmd Msg )
      -- Command issued after a discard-close.
    , afterClose : Model -> Cmd Msg
    }


-- FOCUS HELPERS


focusAfterDelay : String -> Cmd Msg
focusAfterDelay id =
    Task.attempt (\_ -> NoOp)
        (Process.sleep 0
            |> Task.andThen (\_ -> Dom.focus id)
        )


focusAndCursor : String -> Cmd Msg
focusAndCursor id =
    Cmd.batch
        [ focusAfterDelay id
        , Ports.setCursorPos id
        ]


focusPrompt : Model -> Cmd Msg
focusPrompt model =
    case model.activeId of
        Just sid ->
            Task.attempt (\_ -> NoOp) (Dom.focus ("msg-input-" ++ sid))

        Nothing ->
            Cmd.none


-- SHARED HANDLERS


setInput : Kit item draft -> String -> Model -> ( Model, Cmd Msg )
setInput kit val model =
    ( kit.set (Sel.setInput kit.nameOf val (kit.get model)) model
    , Cmd.none
    )


selectItem : Kit item draft -> Int -> Model -> ( Model, Cmd Msg )
selectItem kit idx model =
    let
        st =
            kit.get model

        scrollCmd =
            case List.head (List.drop idx (Sel.filterItems kit.nameOf st.working st.input)) of
                Just item ->
                    Ports.scrollIntoView (kit.scrollItemId model (kit.idOf item))

                Nothing ->
                    Cmd.none
    in
    ( kit.set (Sel.selectItem idx st) model
    , scrollCmd
    )


confirmItem : Kit item draft -> Int -> Model -> ( Model, Cmd Msg )
confirmItem kit id model =
    kit.confirm id model


editItem : Kit item draft -> Int -> Model -> ( Model, Cmd Msg )
editItem kit id model =
    let
        st =
            kit.get model
    in
    case List.filter (\item -> kit.idOf item == id) st.working |> List.head of
        Just item ->
            ( kit.set (Sel.openEdit (kit.draftOf item) st) model
            , focusAndCursor (kit.editorId model)
            )

        Nothing ->
            ( model, Cmd.none )


addItem : Kit item draft -> Model -> ( Model, Cmd Msg )
addItem kit model =
    ( kit.set (Sel.openEdit kit.emptyDraft (kit.get model)) model
    , focusAndCursor (kit.editorId model)
    )


editBack : Kit item draft -> Model -> ( Model, Cmd Msg )
editBack kit model =
    ( kit.set (Sel.backFromEdit (kit.get model)) model
    , focusAndCursor (kit.inputId model)
    )


editSave : Kit item draft -> Model -> ( Model, Cmd Msg )
editSave kit model =
    ( kit.set
        (Sel.saveItem kit.draftIdOf kit.itemOfDraft kit.idOf kit.setIdOf (kit.get model))
        model
    , focusAndCursor (kit.inputId model)
    )


editField : Kit item draft -> String -> String -> Model -> ( Model, Cmd Msg )
editField kit field value model =
    ( kit.set (Sel.updateDraft (kit.updateDraftField field value) (kit.get model)) model
    , Cmd.none
    )


deleteItem : Kit item draft -> Int -> Model -> ( Model, Cmd Msg )
deleteItem kit id model =
    ( kit.set (Sel.requestDelete id (kit.get model)) model
    , Cmd.none
    )


confirmDelete : Kit item draft -> Int -> Model -> ( Model, Cmd Msg )
confirmDelete kit id model =
    ( kit.set (Sel.confirmDeleteItem kit.idOf id (kit.get model)) model
    , Cmd.none
    )


cancelDelete : Kit item draft -> Model -> ( Model, Cmd Msg )
cancelDelete kit model =
    ( kit.set (Sel.cancelDelete (kit.get model)) model
    , Cmd.none
    )


confirmSync : Kit item draft -> Model -> ( Model, Cmd Msg )
confirmSync kit model =
    ( kit.set (Sel.startSync (kit.get model)) model
    , kit.syncCmd model
    )


discardClose : Kit item draft -> Model -> ( Model, Cmd Msg )
discardClose kit model =
    ( kit.setShow False (kit.set (Sel.close (kit.get model)) model)
    , kit.afterClose model
    )


cancelSyncPrompt : Kit item draft -> Model -> ( Model, Cmd Msg )
cancelSyncPrompt kit model =
    ( kit.set (Sel.backToList (kit.get model)) model
    , focusAndCursor (kit.inputId model)
    )


syncSuccess : Kit item draft -> Model -> ( Model, Cmd Msg )
syncSuccess kit model =
    kit.syncSuccess model


syncFailed : Kit item draft -> String -> Model -> ( Model, Cmd Msg )
syncFailed kit err model =
    ( kit.set (Sel.syncFailed err (kit.get model)) model
    , Cmd.none
    )
