module PresetsTest exposing (tests)

{-| `App.Presets`: the Preset Manager's transitions.

Before this family was sliced out of the dispatcher, the only tests over it were
the nine on `movePreset`; every arm (open, copy naming, the two-step delete, the
drop, both replies) was reachable only through `App.Update`. The e2e
`preset-reorder` suite covers the drag end to end, but nothing pinned the copy
name or the write-after-reply rules.

The assertions worth keeping are the ones about WHAT is written: a copy name that
collides, a reorder derived from a drag that never happened, or a re-list skipped
after a rename are all silent until the user's preset directory looks wrong.
-}

import App.Presets as PS exposing (Action(..))
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)



-- ─── fixtures ──────────────────────────────────────────────────────

info : String -> PS.Info
info name =
    { name = name
    , isSeed = name == "Simple" || name == "Complex"
    }


presets : List PS.Info
presets =
    [ info "Simple", info "Complex", info "Work" ]


namesOf : List PS.Info -> List String
namesOf =
    List.map .name


{-| Effects as plain text, so one `Expect.equal` compares a whole effect set
including its arguments.
-}
effectOf : List PS.Action -> List String
effectOf actions =
    List.map
        (\action ->
            case action of
                List ->
                    "List"

                Copy source name ->
                    "Copy " ++ source ++ " -> " ++ name

                Rename oldName newName ->
                    "Rename " ++ oldName ++ " -> " ++ newName

                Delete name ->
                    "Delete " ++ name

                Reorder names ->
                    "Reorder " ++ String.join "," names
        )
        actions


listReply : List PS.Info -> E.Value
listReply rows =
    E.object
        [ ( "ok", E.bool True )
        , ( "error", E.string "" )
        , ( "presets"
          , E.list
                (\p ->
                    E.object
                        [ ( "name", E.string p.name )
                        , ( "is_seed", E.bool p.isSeed )
                        ]
                )
                rows
          )
        ]


okReply : Bool -> String -> E.Value
okReply ok error =
    E.object [ ( "ok", E.bool ok ), ( "error", E.string error ) ]


{-| A failed `list_presets`, built the way transport.js builds one: it sends an
EMPTY `presets` array alongside the error, so the decoder is satisfied and the
question becomes what the client does with a list it was told to discard.
-}
listFailure : String -> E.Value
listFailure error =
    E.object
        [ ( "ok", E.bool False )
        , ( "presets", E.list identity [] )
        , ( "error", E.string error )
        ]



-- ─── open / close ──────────────────────────────────────────────────

openCloseTests : Test
openCloseTests =
    let
        blank =
            PS.emptyManager
    in
    describe "opening and closing"
        [ test "open shows the list, marks it loading, and asks for it" <|
            \_ ->
                let
                    ( pm, actions ) =
                        PS.open
                in
                Expect.all
                    [ \p -> Expect.equal True p.show
                    , \p -> Expect.equal True p.loading
                    , \_ -> Expect.equal [ "List" ] (effectOf actions)
                    ]
                    pm
        , test "close refuses while an action is in flight" <|
            \_ ->
                let
                    busy =
                        { blank | show = True, busy = True, error = Just "x" }
                in
                PS.close busy |> Expect.equal busy
        , test "close from the list clears everything" <|
            \_ ->
                PS.close { blank | show = True, error = Just "x", confirmDelete = Just "Work" }
                    |> Expect.equal PS.emptyManager
        ]



-- ─── copy: the generated name ──────────────────────────────────────

copyTests : Test
copyTests =
    let
        blank =
            PS.emptyManager
    in
    describe "copying a preset"
        [ test "a free name gets the plain suffix" <|
            \_ ->
                PS.copy "Work" presets blank
                    |> Tuple.second
                    |> effectOf
                    |> Expect.equal [ "Copy Work -> Work-copy" ]
        , test "a taken suffix is walked, not duplicated" <|
            \_ ->
                let
                    withCopy =
                        presets ++ [ info "Work-copy", info "Work-copy-2" ]
                in
                PS.copy "Work" withCopy blank
                    |> Tuple.second
                    |> effectOf
                    |> Expect.equal [ "Copy Work -> Work-copy-3" ]
        , test "the walk starts at 2, so the first copy keeps the plain name" <|
            \_ ->
                PS.copy "Simple" [ info "Simple-copy" ] blank
                    |> Tuple.second
                    |> effectOf
                    |> Expect.equal [ "Copy Simple -> Simple-copy-2" ]
        , test "a copy marks busy and clears the previous error" <|
            \_ ->
                let
                    ( pm, _ ) =
                        PS.copy "Work" presets { blank | error = Just "stale" }
                in
                Expect.all
                    [ \p -> Expect.equal True p.busy
                    , \p -> Expect.equal Nothing p.error
                    ]
                    pm
        , test "a seed preset is copied under a new name, not renamed" <|
            \_ ->
                -- The backend protects seed NAMES from rename/delete; copying is
                -- the supported way to fork one, so this must not be refused here.
                PS.copy "Complex" presets blank
                    |> Tuple.second
                    |> effectOf
                    |> Expect.equal [ "Copy Complex -> Complex-copy" ]
        ]



-- ─── rename ────────────────────────────────────────────────────────

renameTests : Test
renameTests =
    let
        blank =
            PS.emptyManager
    in
    describe "renaming a preset"
        [ test "starting a rename seeds the input with the current name" <|
            \_ ->
                PS.renameStart "Work" blank
                    |> Expect.all
                        [ \p -> Expect.equal (Just "Work") p.renaming
                        , \p -> Expect.equal "Work" p.renameInput
                        ]
        , test "typing clears the error line" <|
            \_ ->
                { blank | error = Just "taken" }
                    |> PS.setRenameInput "W"
                    |> .error
                    |> Expect.equal Nothing
        , test "saving sends the typed name as-is (trimming is the backend's job)" <|
            \_ ->
                { blank | renameInput = "  Private  " }
                    |> PS.renameSave "Work"
                    |> Tuple.second
                    |> effectOf
                    |> Expect.equal [ "Rename Work ->   Private  " ]
        , test "cancel drops the edit but keeps the list state" <|
            \_ ->
                let
                    pm =
                        { blank | show = True, renaming = Just "Work", renameInput = "half" }
                in
                PS.renameCancel pm
                    |> Expect.all
                        [ \p -> Expect.equal Nothing p.renaming
                        , \p -> Expect.equal "" p.renameInput
                        , \p -> Expect.equal True p.show
                        ]
        ]



-- ─── delete ────────────────────────────────────────────────────────

deleteTests : Test
deleteTests =
    let
        blank =
            PS.emptyManager
    in
    describe "deleting a preset"
        [ test "the first click only arms the confirm — it writes nothing" <|
            \_ ->
                let
                    armed =
                        PS.armDelete "Work" blank
                in
                Expect.all
                    [ \p -> Expect.equal (Just "Work") p.confirmDelete
                    , \p -> Expect.equal False p.busy
                    , \p -> Expect.equal "" p.renameInput
                    ]
                    armed
        , test "confirming writes the delete AND clears the armed row" <|
            \_ ->
                let
                    armed =
                        { blank | confirmDelete = Just "Work", error = Just "x" }

                    ( pm, actions ) =
                        PS.confirmDelete "Work" armed
                in
                Expect.all
                    [ \p -> Expect.equal [ "Delete Work" ] (effectOf actions)
                    , \p -> Expect.equal True p.busy
                    , \p -> Expect.equal Nothing p.confirmDelete
                    , \p -> Expect.equal Nothing p.error
                    ]
                    pm
        , test "cancel disarms without writing anything" <|
            \_ ->
                { blank | confirmDelete = Just "Work" }
                    |> PS.cancelDelete
                    |> .confirmDelete
                    |> Expect.equal Nothing
        ]



-- ─── the drag ──────────────────────────────────────────────────────

dragTests : Test
dragTests =
    let
        blank =
            PS.emptyManager
    in
    describe "drag-to-reorder"
        [ test "starting a drag marks both the source and the current target" <|
            \_ ->
                PS.dragStart 1 blank
                    |> Expect.all
                        [ \p -> Expect.equal (Just 1) p.dragFrom
                        , \p -> Expect.equal (Just 1) p.dragOver
                        ]
        , test "the drop moves the PRESET list and writes the new order" <|
            \_ ->
                let
                    dragging =
                        { blank | dragFrom = Just 0 }

                    ( rows, pm, actions ) =
                        PS.drop 2 presets dragging
                in
                Expect.all
                    [ \_ -> Expect.equal [ "Complex", "Work", "Simple" ] (namesOf rows)
                    , \_ -> Expect.equal [ "Reorder Complex,Work,Simple" ] (effectOf actions)
                    , \_ -> Expect.equal Nothing pm.dragFrom
                    ]
                    ()
        , test "a drop with no drag in progress reorders nothing and writes nothing" <|
            \_ ->
                -- A stray drop event reaches this message. An order derived from a
                -- missing source would be written as the user's whole arrangement.
                let
                    ( rows, pm, actions ) =
                        PS.drop 1 presets blank
                in
                Expect.all
                    [ \_ -> Expect.equal presets rows
                    , \_ -> Expect.equal [] actions
                    , \_ -> Expect.equal blank pm
                    ]
                    ()
        , test "the written order is the whole list, so no preset can be dropped from it" <|
            \_ ->
                let
                    ( _, _, actions ) =
                        PS.drop 0 presets { blank | dragFrom = Just 2 }
                in
                case actions of
                    [ Reorder names ] ->
                        -- Every row survived, none invented: a partial list here
                        -- would silently reorder presets that were never dragged.
                        Expect.equal (List.sort (namesOf presets)) (List.sort names)

                    other ->
                        Expect.fail ("expected one Reorder, got " ++ String.fromInt (List.length other))
        , test "ending a drag clears both indices" <|
            \_ ->
                { blank | dragFrom = Just 0, dragOver = Just 2 }
                    |> PS.dragEnd
                    |> Expect.all
                        [ \p -> Expect.equal Nothing p.dragFrom
                        , \p -> Expect.equal Nothing p.dragOver
                        ]
        ]



-- ─── the replies ───────────────────────────────────────────────────

replyTests : Test
replyTests =
    let
        blank =
            PS.emptyManager

        loading =
            { blank | show = True, loading = True }
    in
    describe "adopting a reply"
        [ test "a good list replaces the rows and clears loading" <|
            \_ ->
                case PS.adoptList (listReply presets) [] loading of
                    Just ( rows, pm ) ->
                        Expect.all
                            [ \_ -> Expect.equal [ "Simple", "Complex", "Work" ] (namesOf rows)
                            , \p -> Expect.equal False p.loading
                            , \p -> Expect.equal Nothing p.error
                            ]
                            pm

                    Nothing ->
                        Expect.fail "a well-formed reply was refused"
        , test "the seed flag is read from the wire key is_seed" <|
            \_ ->
                -- The field is `isSeed` in Elm and `is_seed` on the wire. Renaming
                -- either side without the decoder would silently make every seed
                -- preset renamable.
                case PS.adoptList (listReply presets) [] loading of
                    Just ( rows, _ ) ->
                        rows |> List.filter .isSeed |> namesOf |> Expect.equal [ "Simple", "Complex" ]

                    Nothing ->
                        Expect.fail "a well-formed reply was refused"
        , test "a reply using the Elm field name is refused, not half-read" <|
            \_ ->
                let
                    raw =
                        E.object
                            [ ( "ok", E.bool True )
                            , ( "error", E.string "" )
                            , ( "presets", E.list (\p -> E.object [ ( "name", E.string p.name ), ( "isSeed", E.bool p.isSeed ) ]) presets )
                            ]
                in
                PS.adoptList raw [] loading |> Expect.equal Nothing
        , test "a failed read keeps the rows the user is looking at" <|
            \_ ->
                case PS.adoptList (listFailure "boom") presets loading of
                    Just ( rows, pm ) ->
                        Expect.all
                            [ \_ -> Expect.equal presets rows
                            , \p -> Expect.equal (Just "boom") p.error
                            , \p -> Expect.equal False p.loading
                            ]
                            pm

                    Nothing ->
                        Expect.fail "a well-formed failure reply was refused"
        , test "an unreadable reply leaves loading set rather than guessing" <|
            \_ ->
                -- `loading` stuck is visible (a spinner); adopting a shape we do
                -- not understand is how a protocol change becomes bad data.
                PS.adoptList (E.object []) presets loading |> Expect.equal Nothing
        , test "a good action re-reads the list instead of guessing the result" <|
            \_ ->
                -- A rename can cascade, and a copy's name is the backend's to
                -- reject, so the reply only says "it worked" — the truth is the
                -- re-read.
                let
                    pm =
                        { blank | show = True, busy = True, renaming = Just "Work", renameInput = "x", confirmDelete = Just "y" }
                in
                case PS.adoptAction (okReply True "") pm of
                    Just ( pm1, actions ) ->
                        Expect.all
                            [ \_ -> Expect.equal [ "List" ] (effectOf actions)
                            , \p -> Expect.equal False p.busy
                            , \p -> Expect.equal Nothing p.renaming
                            , \p -> Expect.equal "" p.renameInput
                            , \p -> Expect.equal Nothing p.confirmDelete
                            , \p -> Expect.equal True p.show
                            ]
                            pm1

                    Nothing ->
                        Expect.fail "a well-formed action reply was refused"
        , test "a failed action unsticks busy so the manager can close again" <|
            \_ ->
                let
                    pm =
                        { blank | busy = True }
                in
                case PS.adoptAction (okReply False "preset not found") pm of
                    Just ( pm1, actions ) ->
                        Expect.all
                            [ \p -> Expect.equal False p.busy
                            , \p -> Expect.equal (Just "preset not found") p.error
                            , \_ -> Expect.equal [] actions
                            ]
                            pm1

                    Nothing ->
                        Expect.fail "a well-formed failure reply was refused"
        , test "a failed action does NOT ask for a re-read" <|
            \_ ->
                -- The list on screen is still what the backend has; replacing it
                -- here would be a second, unrelated read.
                PS.adoptAction (okReply False "x") PS.emptyManager
                    |> Maybe.map (\( _, actions ) -> effectOf actions)
                    |> Expect.equal (Just [])
        ]



-- ─── the entry point ───────────────────────────────────────────────

tests : Test
tests =
    describe "App.Presets — the preset manager"
        [ openCloseTests
        , copyTests
        , renameTests
        , deleteTests
        , dragTests
        , replyTests
        ]
