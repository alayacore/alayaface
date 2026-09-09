module SettingsConfigTest exposing (tests)

{-| `App.SettingsConfig`: the per-preset settings editor.

The family had no unit tests before it was sliced out: `EscapeOverlayTest` sends
`CloseSettingsEditor` and the e2e `model-fields` suite drives the real overlay, but
nothing pinned what a save sends or what a failed read leaves on screen.

The two assertions that matter most are the ones about NOT doing something: the
caret must not move on `open` (the fields are still empty, and this client has had
the "focus an input that has no value yet" bug), and a failed read must not blank
the form. And because `sync_global_settings` MERGES, the payload completeness test
below is about the round trip rather than the file — see the module comment on why
that distinction exists.
-}

import App.SettingsConfig as SC exposing (Action(..))
import Expect
import Json.Encode as E
import Test exposing (Test, describe, test)



-- ─── fixtures ──────────────────────────────────────────────────────

blank : SC.Editor
blank =
    SC.emptyEditor


{-| `Focus` and `PlaceCursor` stay distinguishable on purpose: both must happen
after a good read, and an assertion that lumps them together cannot show one
going missing.
-}
effectKinds : List SC.Action -> List String
effectKinds actions =
    List.map
        (\action ->
            case action of
                SC.Read _ ->
                    "Read"

                SC.Sync _ ->
                    "Sync"

                SC.Focus _ ->
                    "Focus"

                SC.PlaceCursor _ ->
                    "PlaceCursor"
        )
        actions


{-| A `list_global_settings` reply, shaped like the file the backend read.
-}
listReply : Bool -> String -> E.Value
listReply ok error =
    E.object
        [ ( "ok", E.bool ok )
        , ( "tool_confirm", E.string "ask" )
        , ( "builtin_tools", E.string "read_file,write_file" )
        , ( "system_prompt", E.string "the plan contract" )
        , ( "reasoning_level", E.int 2 )
        , ( "error", E.string error )
        ]


syncReply : Bool -> String -> E.Value
syncReply ok error =
    E.object [ ( "ok", E.bool ok ), ( "error", E.string error ) ]



-- ─── open / close ──────────────────────────────────────────────────

openCloseTests : Test
openCloseTests =
    describe "App/SettingsConfig — opening and closing"
        [ test "open shows a loading form for the requested preset" <|
            \_ ->
                let
                    ( ed, actions ) =
                        SC.open "Complex"
                in
                Expect.all
                    [ \p -> Expect.equal True p.show
                    , \p -> Expect.equal True p.loading
                    , \p -> Expect.equal "Complex" p.preset
                    , \p -> Expect.equal "" p.systemPrompt
                    , \_ -> Expect.equal [ "Read" ] (effectKinds actions)
                    ]
                    ed
        , test "open does NOT move the caret yet (the fields have no values)" <|
            \_ ->
                -- The read has not answered: focusing now would put the cursor in
                -- an empty box and the file's values would land under it a moment
                -- later. The Focus/PlaceCursor pair belongs to the reply.
                Expect.equal [ "Read" ] (effectKinds (SC.open "Complex" |> Tuple.second))
        , test "opening another preset cannot leak the previous one's fields" <|
            \_ ->
                -- The editor is one overlay reused per preset, so `open` replaces
                -- the whole record rather than clearing fields one at a time.
                let
                    ( simple, _ ) =
                        SC.open "Simple"

                    ( complex, _ ) =
                        SC.open "Complex"
                in
                Expect.all
                    [ \( a, b ) -> Expect.equal "" a.systemPrompt
                    , \( a, b ) -> Expect.equal "Simple" a.preset
                    , \( a, b ) -> Expect.equal "Complex" b.preset
                    , \( a, b ) -> Expect.equal "" b.systemPrompt
                    ]
                    ( simple, complex )
        , test "close refuses while a sync is in flight" <|
            \_ ->
                let
                    wedged =
                        { blank | show = True, syncing = True, preset = "Simple" }
                in
                SC.close wedged |> Expect.equal wedged
        , test "close clears the preset too, not just the fields" <|
            \_ ->
                SC.close { blank | show = True, preset = "Simple" }
                    |> Expect.all
                        [ \p -> Expect.equal False p.show
                        , \p -> Expect.equal "" p.preset
                        ]
        ]



-- ─── the fields ────────────────────────────────────────────────────

{-| An editor open on a preset with values in it and a stale error showing.
-}
full : SC.Editor
full =
    { blank
        | show = True
        , preset = "Simple"
        , toolConfirm = "ask"
        , builtinTools = "read_file"
        , systemPrompt = "keep me"
        , reasoningLevel = 1
        , error = Just "stale message"
    }


fieldTests : Test
fieldTests =
    describe "App/SettingsConfig — editing fields"
        [ test "every field edit clears the error line" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal Nothing (SC.setToolConfirm "auto" full |> .error)
                    , \_ -> Expect.equal Nothing (SC.setBuiltinTools "none" full |> .error)
                    , \_ -> Expect.equal Nothing (SC.setSystemPrompt "x" full |> .error)
                    , \_ -> Expect.equal Nothing (SC.setReasoningLevel 0 full |> .error)
                    ]
                    ()
        , test "a field edit touches only that field (the preset and siblings stay)" <|
            \_ ->
                let
                    ed =
                        SC.setToolConfirm "auto" full
                in
                Expect.all
                    [ \p -> Expect.equal "auto" p.toolConfirm
                    , \p -> Expect.equal "read_file" p.builtinTools
                    , \p -> Expect.equal "keep me" p.systemPrompt
                    , \p -> Expect.equal 1 p.reasoningLevel
                    , \p -> Expect.equal "Simple" p.preset
                    ]
                    ed
        ]



-- ─── saving ────────────────────────────────────────────────────────

saveTests : Test
saveTests =
    describe "App/SettingsConfig — saving"
        [ test "a save sends all four fields plus the preset" <|
            \_ ->
                -- The command merges, so a key left out would keep its old value
                -- rather than be cleared — which is the opposite of a wipe and
                -- just as surprising. The payload is the whole form, every time.
                case SC.save full |> Tuple.second of
                    [ SC.Sync p ] ->
                        Expect.all
                            [ \_ -> Expect.equal "Simple" p.preset
                            , \_ -> Expect.equal "ask" p.toolConfirm
                            , \_ -> Expect.equal "read_file" p.builtinTools
                            , \_ -> Expect.equal "keep me" p.systemPrompt
                            , \_ -> Expect.equal 1 p.reasoningLevel
                            ]
                            ()

                    other ->
                        Expect.fail ("expected exactly one Sync, got " ++ String.fromInt (List.length other))
        , test "a save marks syncing and writes no error" <|
            \_ ->
                SC.save full
                    |> Tuple.first
                    |> Expect.all
                        [ \p -> Expect.equal True p.syncing
                        , \p -> Expect.equal Nothing p.error
                        ]
        , test "no validation happens here — the backend normalizes" <|
            \_ ->
                -- An empty tool_confirm is a legitimate value (no confirmation);
                -- inventing a client-side rule would fight the backend's.
                Expect.equal [ "Sync" ] (SC.save { full | toolConfirm = "" } |> Tuple.second |> effectKinds)
        ]



-- ─── the replies ───────────────────────────────────────────────────

replyTests : Test
replyTests =
    let
        loading =
            { blank | show = True, loading = True, preset = "Complex" }

        editing =
            { blank | show = True, preset = "Complex", systemPrompt = "typed by hand", reasoningLevel = 0 }
    in
    describe "App/SettingsConfig — adopting a reply"
        [ test "a good read fills the form with the file's values" <|
            \_ ->
                case SC.adoptList (listReply True "") loading of
                    Just ( ed, actions ) ->
                        Expect.all
                            [ \p -> Expect.equal "ask" p.toolConfirm
                            , \p -> Expect.equal "read_file,write_file" p.builtinTools
                            , \p -> Expect.equal "the plan contract" p.systemPrompt
                            , \p -> Expect.equal 2 p.reasoningLevel
                            , \p -> Expect.equal False p.loading
                            , \p -> Expect.equal "Complex" p.preset
                            , \_ -> Expect.equal [ "Focus", "PlaceCursor" ] (effectKinds actions)
                            ]
                            ed

                    Nothing ->
                        Expect.fail "a well-formed reply was refused"
        , test "a failed read keeps what the user typed and shows the error" <|
            \_ ->
                -- Blanking the form on a read error turns a backend problem into
                -- the user losing their work, and a subsequent save would then
                -- write the blanks.
                case SC.adoptList (listReply False "boom") editing of
                    Just ( ed, actions ) ->
                        Expect.all
                            [ \p -> Expect.equal "typed by hand" p.systemPrompt
                            , \p -> Expect.equal 0 p.reasoningLevel
                            , \p -> Expect.equal (Just "boom") p.error
                            , \p -> Expect.equal False p.loading
                            , \_ -> Expect.equal [] (effectKinds actions)
                            ]
                            ed

                    Nothing ->
                        Expect.fail "a well-formed failure reply was refused"
        , test "a failed read does not move the caret" <|
            \_ ->
                SC.adoptList (listReply False "boom") editing
                    |> Maybe.map (\( _, actions ) -> effectKinds actions)
                    |> Expect.equal (Just [])
        , test "an unreadable reply leaves loading set rather than guessing" <|
            \_ ->
                -- A stuck spinner is honest; a form filled with defaults the file
                -- never had is how a save writes values nobody typed.
                SC.adoptList (E.object []) editing |> Expect.equal Nothing
        , test "a good save closes the overlay" <|
            \_ ->
                SC.adoptSync (syncReply True "") { editing | syncing = True }
                    |> Expect.equal (Just SC.emptyEditor)
        , test "a failed save unsticks syncing so the overlay can close" <|
            \_ ->
                case SC.adoptSync (syncReply False "Invalid preset name") { editing | syncing = True } of
                    Just ed ->
                        Expect.all
                            [ \p -> Expect.equal False p.syncing
                            , \p -> Expect.equal (Just "Invalid preset name") p.error
                            , \p -> Expect.equal "typed by hand" p.systemPrompt
                            , \p -> Expect.equal "Complex" p.preset
                            ]
                            ed

                    Nothing ->
                        Expect.fail "a well-formed failure reply was refused"
        , test "an unreadable save reply leaves syncing set rather than guessing" <|
            \_ ->
                SC.adoptSync (E.object []) { editing | syncing = True } |> Expect.equal Nothing
        ]



-- ─── the entry point ───────────────────────────────────────────────

tests : Test
tests =
    describe "App.SettingsConfig — the per-preset settings editor"
        [ openCloseTests
        , fieldTests
        , saveTests
        , replyTests
        ]
