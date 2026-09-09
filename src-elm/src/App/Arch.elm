module App.Arch exposing
    ( Action(..)
    , objectPutResult
    , objectGetResult
    , openVersionList, closeVersionList
    , viewVersion, closeVersionView
    )

{-| The App-level half of the C architecture (`docs/arch-persistent.md`): the
replies from the object store, the freeze queue they drain, and version browsing.

`Arch.Freeze` already owns the state machine (begin / onPutResult / buildVersion /
isComplete) and `Arch.Values` owns the encoding. What could not live in either is
the part that touches `Model` — which fields a completed freeze writes, where the
refs file goes, when the next queued freeze starts — so that is what this module
holds. It takes `Model` (unlike the `App/AsrConfig` shape; these replies decide
across five fields at once) but still returns effects as `Action` DATA, so the
commands a freeze issues are assertable and not just its model writes.


## The one-at-a-time rule, and who breaks it

Freezes are **serial**: one `freezeActive`, a queue behind it, and a `reqId` that
only has meaning inside the active freeze. This module dequeues, so it is the only
place a QUEUED freeze starts — but it is not the only writer of the queue:
`Plan/Update.elm` appends a freeze when a run finishes and starts that first item
itself. The invariant therefore spans two modules, and a second
`freezeActive = Just …` added anywhere would let two freezes interleave and build
a version out of both sessions' blocks. `grep freezeQueue` finds every writer.


## Why the refs write is not an object put

`session.refs.json` is the mutable head pointer, addressed by SESSION ID rather
than by content hash, so it goes through the file writer. Sending it as `Put` would
store an unreachable object and leave the session pointing at the previous version.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import App.Types exposing (Model)
import Arch.Freeze as Freeze
import Arch.Values as AV
import Plan.Update as PU


{-| What a transition wants from the transport. Mapped to ports by
`App.Update`'s `applyArchAction`, which is the only producer of these commands.
-}
type Action
    = Put Int String
    | Get String
    | WriteRefs String String


{-| `object_put` reply. `reqId` is the number `Arch.Freeze` assigned inside the
active freeze, so it means nothing without one: a reply arriving after its freeze
was abandoned is dropped rather than applied to whatever froze next.
-}
putReplyDecoder : D.Decoder { reqId : String, ok : Bool, hash : String }
putReplyDecoder =
    D.map3
        (\reqId ok hash -> { reqId = reqId, ok = ok, hash = hash })
        (D.field "reqId" D.string)
        (D.field "ok" D.bool)
        (D.field "hash" D.string)


{-| `object_get` reply. `reqId` IS the content hash — every reader asks for an
object by hash — which is why this reply cannot be routed back to whoever wanted
it. See `objectGetResult`.
-}
getReplyDecoder : D.Decoder { reqId : String, ok : Bool, content : String }
getReplyDecoder =
    D.map3
        (\reqId ok content -> { reqId = reqId, ok = ok, content = content })
        (D.field "reqId" D.string)
        (D.field "ok" D.bool)
        (D.field "content" D.string)



-- ─── The freeze path ───────────────────────────────────────────────

objectPutResult : E.Value -> Model -> ( Model, List Action )
objectPutResult raw model =
    case D.decodeValue putReplyDecoder raw of
        Err _ ->
            ( model, [] )

        Ok r ->
            if not r.ok then
                -- A failed object write abandons the whole freeze rather than
                -- leave a half-assembled version behind, and lets the next one
                -- start.
                startNextFreeze { model | freezeActive = Nothing, freezeQueue = [] }

            else
                case model.freezeActive of
                    Nothing ->
                        ( model, [] )

                    Just st ->
                        afterPut r st model


{-| One accepted `object_put`: advance the active freeze, then keep waiting, write
the version object, or finish and drain the queue.
-}
afterPut : { r | reqId : String, hash : String } -> Freeze.FreezeState -> Model -> ( Model, List Action )
afterPut r st model =
    let
        st2 =
            Freeze.onPutResult (String.toInt r.reqId |> Maybe.withDefault -1) (Just r.hash) st
    in
    if Freeze.isComplete st2 then
        freezeFinished st2 model

    else
        case Freeze.buildVersion st2 of
            Just version ->
                -- All blocks and runs are in the store: write the version object
                -- itself. `built` is stashed so the completion path can fill
                -- versionCache without another round trip.
                ( { model | freezeActive = Just { st2 | built = Just version } }
                , [ Put (Freeze.versionReq st2) (AV.versionContent version) ]
                )

            Nothing ->
                -- Some blocks/runs are still in flight: keep waiting.
                ( { model | freezeActive = Just st2 }, [] )


{-| The version object is written: move the head pointer, merge the caches, then
start the next queued freeze.

The refs content is the one THIS freeze produced — computed before `startNextFreeze`
runs, which may begin another freeze but cannot change these fields.
-}
freezeFinished : Freeze.FreezeState -> Model -> ( Model, List Action )
freezeFinished st2 model =
    let
        versionHash =
            Maybe.withDefault "" st2.versionHash

        refs0 =
            Dict.get st2.sessionId model.sessionRefs
                |> Maybe.withDefault (AV.SessionRefs st2.sessionId "" [] Nothing)

        refs =
            { refs0
                | head = versionHash
                , versions = refs0.versions ++ [ versionHash ]

                -- C2b: the work-copy directory at freeze time (after a fork =
                -- forkId; a resume keeps the old value).
                , workCopy = st2.workCopy
            }

        m1 =
            { model
                | freezeActive = Nothing
                , sessionRefs = Dict.insert st2.sessionId refs model.sessionRefs
                , runSummaries = Dict.union (Freeze.runSummaries st2) model.runSummaries
                , versionCache =
                    case st2.built of
                        Just v ->
                            Dict.insert versionHash v model.versionCache

                        Nothing ->
                            model.versionCache
            }

        ( m2, nextActions ) =
            startNextFreeze m1
    in
    ( m2
    , nextActions ++ [ WriteRefs (refsPath model.homeDir st2.sessionId) (AV.refsContent refs) ]
    )


refsPath : String -> String -> String
refsPath homeDir sessionId =
    PU.sessionsDir homeDir ++ "/" ++ sessionId ++ "/session.refs.json"


{-| Start the next queued freeze — serial by construction. NOT the only writer of
the queue: see the module comment before adding a caller or another `freezeActive`
assignment.
-}
startNextFreeze : Model -> ( Model, List Action )
startNextFreeze model =
    case model.freezeQueue of
        next :: rest ->
            ( { model | freezeActive = Just next, freezeQueue = rest }
            , next |> Freeze.initialPuts |> List.map (\( reqId, content ) -> Put reqId content)
            )

        [] ->
            ( { model | freezeActive = Nothing }, [] )



-- ─── Reading objects back ──────────────────────────────────────────

{-| `object_get` reply. Shared by three readers — the freeze cache, plan-meta
scanning (`MetaScan.GetObject`) and version browsing — and it cannot tell them
apart, because `reqId` is the hash in every case. What it does decide is WHICH
KIND of object arrived: a Version, then a Block, then neither. The order matters,
and a payload that is neither is dropped rather than cached — caching garbage under
a content key is how a bad object comes back on every later read of that hash.
-}
objectGetResult : E.Value -> Model -> ( Model, List Action )
objectGetResult raw model =
    case D.decodeValue getReplyDecoder raw of
        Err _ ->
            ( model, [] )

        Ok r ->
            if not r.ok then
                ( model, [] )

            else
                case D.decodeString AV.decodeVersion r.content of
                    Ok v ->
                        let
                            m1 =
                                { model | versionCache = Dict.insert r.reqId v model.versionCache }

                            -- C4: if this is the version being viewed, pull the
                            -- message blocks it names as well.
                            gets =
                                if model.versionViewFor == Just r.reqId then
                                    missingBlocks m1 v

                                else
                                    []
                        in
                        ( m1, gets )

                    Err _ ->
                        case D.decodeString AV.decodeBlock r.content of
                            Ok b ->
                                ( { model | blockCache = Dict.insert r.reqId b.messages model.blockCache }, [] )

                            Err _ ->
                                ( model, [] )


{-| Ask for the message blocks of a version that are not cached yet. Used by both
ways a version is entered (opening it, and its object arriving), which is why it is
one function: two copies of "which blocks are missing" is how a version renders
with a hole in it.
-}
missingBlocks : Model -> AV.Version -> List Action
missingBlocks model version =
    version.blocks
        |> List.filter (\b -> not (Dict.member b model.blockCache))
        |> List.map Get



-- ─── Version browsing (read-only; D8 never materializes) ───────────

{-| Open a session's version list. The Session Manager is closed because both
occupy the one overlay slot.
-}
openVersionList : String -> Model -> ( Model, List Action )
openVersionList sid model =
    ( { model | versionListFor = Just sid, showSessionManager = False }, [] )


closeVersionList : Model -> ( Model, List Action )
closeVersionList model =
    ( { model | versionListFor = Nothing }, [] )


{-| View one historical version. If the version object is already cached its
blocks are fetched straight away; if not, only the version is requested and
`objectGetResult` fetches the blocks when it lands — one round trip, not two
racing ones.
-}
viewVersion : String -> String -> Model -> ( Model, List Action )
viewVersion sid hash model =
    let
        m1 =
            { model
                | versionListFor = Nothing
                , versionViewFor = Just hash
                , versionViewSession = Just sid
            }
    in
    case Dict.get hash m1.versionCache of
        Just v ->
            ( m1, missingBlocks m1 v )

        Nothing ->
            ( m1, [ Get hash ] )


closeVersionView : Model -> ( Model, List Action )
closeVersionView model =
    ( { model | versionViewFor = Nothing, versionViewSession = Nothing }, [] )
