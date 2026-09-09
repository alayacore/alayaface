module App.UiConfig exposing
    ( Entry
    , Document
    , version
    , maxStoredWindows
    , emptyDocument
    , decode
    , encode
    , evict
    , fromStore
    , soloIntent
    )

{-| The schema of `~/.alayaface/ui.conf` — the layout store (F3): every
window's rect, the canvas pan/zoom, and which window was solo.

## Why this module owns the whole schema

`sync_ui_config` REPLACES the file. AGENTS.md records what happens when the
schema is spread out or incomplete: a field the writer does not model is silently
DELETED from the user's file on the next save, and the symptom surfaces two hops
away ("the REASONING window never appears"). `model.conf` bit this project three
times that way. So the field list, the decoder and the encoder live here and
nowhere else.

## Why the backends own none of it

Both `get_ui_config` and `sync_ui_config` (Rust `commands/ui_config.rs`, Go
`handlers/ui_config.go`) pass the document through as opaque JSON and validate
only its shape: is it an object, is `version` an integer, is `windows` an object
no larger than `maxStoredWindows`. That is what lets a NEWER AlayaFace save a
richer document through an OLDER backend without the older one eating fields it
has never seen. `scripts/check-backend-parity.sh` compares `version` and
`maxStoredWindows` across all three files (they are the only numbers duplicated
by design), and `testdata/serialization/ui_cases.json` is the shared
accept/refuse table both backends run against.

## The limit, stated

Unknown keys are carried through at the TOP level (`Document.extras`), because
that is where a new field lands. Keys inside a `windows` entry are NOT carried:
an entry is the client's own rect format, so adding a per-window field means
adding it to `Entry` with a default on decode — the same discipline
`Session/ModelConfig.elm` applies to model fields. An older client run after a
newer one will therefore drop a per-window field it does not model; a top-level
one survives.

## What is deliberately not stored at all

`z`, and the `sessionOrder` / `planOrder` lists (SD17). Those are derived mutable
state that `rebasePositions` shrinks on purpose, and importing a stale stacking
model into a fresh process is worse than letting stacking follow creation order —
which is what the order lists already give on restore.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E


{-| Layout-document version this build writes, and the one reported for an
absent file. Twins: `DEFAULT_UI_CONF_VERSION` (Rust), `DefaultUiConfVersion`
(Go). A document from a FUTURE version is still read (unknown keys carried,
missing keys defaulted): refusing it would stop an older AlayaFace from saving
the layout at all.
-}
version : Int
version =
    1


{-| Upper bound on stored window entries. Twins: `MAX_STORED_WINDOWS` (Rust),
`MaxStoredWindows` (Go) — and the backends REFUSE an oversized document, so the
bound holds on both ends, not only in the writer.

Why bound at all: the store outlives the windows (SD15), so closing and
reopening sessions over months grows it without limit, and the keys are UUIDs —
they never collide and are never reused.
-}
maxStoredWindows : Int
maxStoredWindows =
    200


{-| One stored window rect. `t` is a monotonic touch counter, NOT a stacking
order: bumped when the window is created or moved, and read only by eviction.

Why a stored counter rather than "most recently used": decoding JSON into a
`Dict` sorts the keys, so recency is not recoverable from the map. Without `t` a
real LRU is unimplementable, and pretending the dictionary order is one would
make eviction depend on an implementation detail.
-}
type alias Entry =
    { x : Int, y : Int, w : Int, h : Int, t : Int }


{-| The whole document. `soloWin` is a key in the SAME space as `windows` (a
session id or a plan id, SD2) and may name a window that is not open — restore
then leaves it inert until that key appears (INV2).
-}
type alias Document =
    { version : Int
    , soloWin : Maybe String
    , canvasOffset : { x : Int, y : Int }
    , canvasScale : Float
    , windows : Dict String Entry
    , extras : Dict String E.Value
    }


emptyDocument : Document
emptyDocument =
    { version = version
    , soloWin = Nothing
    , canvasOffset = { x = 0, y = 0 }
    , canvasScale = 1.0
    , windows = Dict.empty
    , extras = Dict.empty
    }


knownKeys : List String
knownKeys =
    [ "version", "soloWin", "canvasOffset", "canvasScale", "windows" ]


{-| Assemble a document from what the client currently knows.

The reason this exists is NAMING, not construction: `soloWin` is the name of a
KEY in ui.conf, while `Model.soloWin` is the live presentation state — two
things with different lifetimes that happen to share a spelling. A module that
reads the Model must not have to reach across that ambiguity, so
`App/UiLayout.elm` builds its document here, and
`scripts/check-layout-invariants.sh` keeps the token out of the Model-reading
code (the check allow-lists this file because `UiConfig` cannot import
`App.Types`).
-}
fromStore :
    { solo : Maybe String
    , offset : { x : Int, y : Int }
    , scale : Float
    , windows : Dict String Entry
    , extras : Dict String E.Value
    }
    -> Document
fromStore s =
    { version = version
    , soloWin = s.solo
    , canvasOffset = s.offset
    , canvasScale = s.scale
    , windows = s.windows
    , extras = s.extras
    }


{-| The solo intent a stored document carries — the read half of `fromStore`.
-}
soloIntent : Document -> Maybe String
soloIntent doc =
    doc.soloWin


{-| Read a stored document. Lenient by design — this file is not critical, so
"unreadable" must degrade to defaults rather than to something the user has to
act on:

  * absent / wrong-typed field → that field's default;
  * a body that is not a JSON object at all → `Nothing` (the caller keeps its own
    defaults; there is nothing here worth salvaging);
  * an entry that is not a rect (a missing or fractional field, or a non-positive
    size) is DROPPED, so that one window falls back to the normal placement rule
    while the rest of the board survives. Not clamped into range: a stored 3×4
    window is a corrupt entry, and inventing a size for it would put a window on
    screen that nobody ever had.

The minimum-window-size check lives in the caller (`App.Windows`), because those
are geometry rules and this module must not import the module that imports the
store.
-}
decode : D.Value -> Maybe Document
decode raw =
    case D.decodeValue (D.dict D.value) raw of
        Err _ ->
            Nothing

        Ok fields ->
            Just
                { version = intOf "version" fields |> Maybe.withDefault version
                , soloWin = stringOf "soloWin" fields
                , canvasOffset =
                    objectOf "canvasOffset" fields
                        |> Maybe.andThen (\o -> D.decodeValue pointDecoder (E.object o) |> Result.toMaybe)
                        |> Maybe.withDefault { x = 0, y = 0 }
                , canvasScale =
                    floatOf "canvasScale" fields |> Maybe.withDefault 1.0
                , windows =
                    objectOf "windows" fields
                        |> Maybe.map (\ws -> List.filterMap entryOf ws |> Dict.fromList)
                        |> Maybe.withDefault Dict.empty
                , extras =
                    fields |> Dict.filter (\key _ -> not (List.member key knownKeys))
                }


{-| Re-encode. `extras` are written back verbatim (sorted keys after the known
ones), which is what makes "an older client must not delete a newer client's
field" true on the client side too.
-}
encode : Document -> E.Value
encode doc =
    (knownPairs doc ++ Dict.toList doc.extras) |> E.object


knownPairs : Document -> List ( String, E.Value )
knownPairs doc =
    [ ( "version", E.int doc.version )
    , ( "soloWin", doc.soloWin |> Maybe.map E.string |> Maybe.withDefault E.null )
    , ( "canvasOffset", E.object [ ( "x", E.int doc.canvasOffset.x ), ( "y", E.int doc.canvasOffset.y ) ] )
    , ( "canvasScale", E.float doc.canvasScale )
    , ( "windows"
      , doc.windows
            |> Dict.toList
            |> List.map (\( key, e ) -> ( key, encodeEntry e ))
            |> E.object
      )
    ]


{-| The wire form of one rect. Exposed through `encode`, kept private so nobody
adds a field to the JSON without adding it to `Entry` and to the decoder.
-}
encodeEntry : Entry -> E.Value
encodeEntry e =
    E.object
        [ ( "x", E.int e.x )
        , ( "y", E.int e.y )
        , ( "w", E.int e.w )
        , ( "h", E.int e.h )
        , ( "t", E.int e.t )
        ]


pointDecoder : D.Decoder { x : Int, y : Int }
pointDecoder =
    D.map2 (\x y -> { x = x, y = y })
        (D.field "x" D.int)
        (D.field "y" D.int)


{-| An entry with no `t` counts as the OLDEST possible touch (0): the first thing
eviction takes. Otherwise a hand-written or future-format entry would be
unevictable and the file could fill up with entries that never leave.
-}
entryOf : ( String, E.Value ) -> Maybe ( String, Entry )
entryOf ( key, value ) =
    case
        D.decodeValue
            (D.map5 Entry
                (D.field "x" D.int)
                (D.field "y" D.int)
                (D.field "w" D.int)
                (D.field "h" D.int)
                (D.maybe (D.field "t" D.int) |> D.map (Maybe.withDefault 0))
            )
            value
    of
        Ok e ->
            -- A rect must be usable, not merely parseable: `w`/`h` <= 0 cannot
            -- be drawn, and storing it would resurrect an invisible window.
            if e.w > 0 && e.h > 0 then
                Just ( key, e )

            else
                Nothing

        Err _ ->
            Nothing


intOf : String -> Dict String E.Value -> Maybe Int
intOf key fields =
    fields |> Dict.get key |> Maybe.andThen (\v -> D.decodeValue D.int v |> Result.toMaybe)


floatOf : String -> Dict String E.Value -> Maybe Float
floatOf key fields =
    fields |> Dict.get key |> Maybe.andThen (\v -> D.decodeValue D.float v |> Result.toMaybe)


stringOf : String -> Dict String E.Value -> Maybe String
stringOf key fields =
    fields |> Dict.get key |> Maybe.andThen (\v -> D.decodeValue D.string v |> Result.toMaybe)


objectOf : String -> Dict String E.Value -> Maybe (List ( String, E.Value ))
objectOf key fields =
    fields
        |> Dict.get key
        |> Maybe.andThen (\v -> D.decodeValue (D.dict D.value) v |> Result.toMaybe)
        |> Maybe.map Dict.toList


{-| Bound the document. An OPEN window keeps its entry whatever the cost —
dropping the rect of a window the user is looking at would make the next save
describe a board that no longer matches the screen. Beyond the cap, the CLOSED
entries go, oldest-touched first, the key breaking ties ASC so the same input
always drops the same entries (both backends and this client must be able to
agree about what a file contains).

Returns the document and how many entries were dropped: the caller logs that
once rather than letting the file shrink in silence.
-}
evict : Document -> List String -> ( Document, Int )
evict doc openKeys =
    let
        surplus =
            Dict.size doc.windows - maxStoredWindows
    in
    if surplus <= 0 then
        ( doc, 0 )

    else
        let
            doomed =
                doc.windows
                    |> Dict.toList
                    |> List.filter (\( key, _ ) -> not (List.member key openKeys))
                    |> List.sortBy (\( key, e ) -> ( e.t, key ))
                    |> List.take surplus
                    |> List.map Tuple.first
        in
        ( { doc | windows = List.foldl Dict.remove doc.windows doomed }
        , List.length doomed
        )
