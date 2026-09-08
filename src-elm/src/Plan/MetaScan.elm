module Plan.MetaScan exposing
    ( Scan
    , init
    , Effect(..)
    , arm
    , begin
    , onListResult
    , onReadResult
    )

{-| Plan-metadata rebuild state machine (R3/C): after a page load the
frontend walks the on-disk session tree —
`sessions/` listing → each session's `plans/` dir → each plan dir → each
node dir — reading every `*.meta.json` (planMetas), every
`session.refs.json` (sessionRefs) and recording every known session's
REAL on-disk directory (sessionDirMap). Extracted from App/Update.elm:
the walk used to live inline inside the FsListDirResult / FsReadResult
message arms, interleaving queue bookkeeping, reqId allocation and
model writes in one ~300-line procedure.

This module owns the walk as a pure state machine: every transition
takes the scan state (and the fs reqId counter, which is shared with
the file-picker flows and must advance in lockstep) and returns the new
state plus a list of `Effect`s. The caller (App/Update) maps effects to
port commands and model writes — the module itself never touches ports
or the model, so every branch is unit-testable in isolation.

Routing stays by reqId (B3), never by global flags: a response whose
reqId matches the scan's in-flight listing/read belongs to the rebuild;
anything else belongs to the file picker / plan-open flows. The scan
can never swallow a user listing that races it, nor be corrupted by
one.

Scan fields:
  pending       — armed by FsHomeDirResult; the scan starts only AFTER
                  the session file-picker's home listing has been
                  consumed (both are untagged fs_list_dir results —
                  firing them in the same batch would let the home
                  listing be misrouted into the scan and desynchronize
                  it, leaving planMetas empty after a restart).
  loading       — a scan step is in flight (drives nothing in the UI;
                  kept for state clarity and tests).
  dirListing    — the directory whose listing the next result belongs
                  to; Nothing = the sessions/ listing is in flight.
  dirQueue      — remaining directories to list (sessions/ → plans/ →
                  plan dirs → node dirs).
  reading       — the file whose read the next result belongs to.
  readQueue     — remaining *.meta.json files to read.
  scanReqId     — reqId of the in-flight fs_list_dir.
  readReqId     — reqId of the in-flight fs_read_file_text.
  sessionQueue  — session.refs.json reads queued from the sessions/
                  listing (root refs, C architecture).
  nodeRefsQueue — session.refs.json reads queued from node dir
                  listings (nested node-session refs, C3-2).
-}

import Dict exposing (Dict)
import Json.Decode as D
import Plan.Meta as PM
import Arch.Values as AV


type alias Scan =
    { pending : Bool
    , loading : Bool
    , dirListing : Maybe String
    , dirQueue : List String
    , reading : Maybe String
    , readQueue : List String
    , scanReqId : Maybe String
    , readReqId : Maybe String
    , sessionQueue : List String
    , nodeRefsQueue : List String
    }


init : Scan
init =
    { pending = False
    , loading = False
    , dirListing = Nothing
    , dirQueue = []
    , reading = Nothing
    , readQueue = []
    , scanReqId = Nothing
    , readReqId = Nothing
    , sessionQueue = []
    , nodeRefsQueue = []
    }


{-| What a scan step wants the caller to do. Commands carry their
already-allocated reqId (the counter came in and went out with the
step, so the scan can never allocate a reqId another flow already
uses). Model writes are data, not side effects: the caller applies them
with Dict.inserts.
-}
type Effect
    = ListDir String String
    -- ^ (reqId, path) — issue fs_list_dir.
    | ReadText String String
    -- ^ (reqId, path) — issue fs_read_file_text.
    | GetObject String
    -- ^ hash — load a version object (issued when a session.refs.json
    -- read references a head version that is not cached yet).
    | RememberDir String String
    -- ^ (sessionId, realOnDiskDir) — record in sessionDirMap (P28).
    | RememberMeta String PM.PlanMeta
    -- ^ (planId, meta) — insert into planMetas.
    | RememberRefs AV.SessionRefs
    -- ^ insert refs into sessionRefs (keyed by refs.id).


{-| Arm the scan: FsHomeDirResult succeeded, so the next non-scan
listing response starts the rebuild (see `pending` above).
-}
arm : Scan -> Scan
arm scan =
    { scan | pending = True }


{-| Allocate the next fs reqId. Mirrors Plan/Update.nextFsReq — the two
must never diverge (responses are routed by these ids).
-}
allocReqId : Int -> ( String, Int )
allocReqId counter =
    ( "fs-" ++ String.fromInt (counter + 1), counter + 1 )


{-| Begin the scan (called from the file-picker listing branch once the
home listing has been consumed): list the sessions/ directory.
-}
begin : Scan -> Int -> String -> ( Scan, Int, List Effect )
begin scan counter sessionsRoot =
    let
        ( reqId, counter1 ) =
            allocReqId counter
    in
    ( { scan | pending = False, loading = True, scanReqId = Just reqId }
    , counter1
    , [ ListDir reqId sessionsRoot ]
    )


{-| A listing result for the scan. `sessionsRoot` is the resolved
sessions/ path (caller owns path resolution). The walk classifies the
listing by the directory it belongs to (scan.dirListing):

  * sessions/           → queue each session's plans/ dir + refs
  * .../plans           → queue each plan dir AND its meta.json read
  * .../plans/<planId>  → queue the node dirs (work/ excluded)
  * .../plans/<p>/<n>   → record the nested session dirs (P28) and
                          queue their session.refs.json (C3-2)

After classifying, one queued dir is listed (or, when no dirs remain,
the queued reads start) — the serialized tail of the walk.
-}
onListResult : Scan -> Int -> Bool -> String -> List { name : String, isDir : Bool } -> ( Scan, Int, List Effect )
onListResult scan counter ok sessionsRoot entries =
    if not ok then
        -- Scan listing failed (backend error): abandon the rebuild
        -- rather than stalling. planMetas stays empty this session;
        -- plan links still resolve from the on-disk files.
        ( { scan | scanReqId = Nothing, dirListing = Nothing, loading = False }
        , counter
        , []
        )

    else
        case scan.dirListing of
            Just dir ->
                -- A directory level. `dirsIn` = the subdirectories of
                -- this listing (plans, node dirs, or nested sessions).
                let
                    dirsIn =
                        entries
                            |> List.filter (\e -> e.isDir && e.name /= ".." && e.name /= ".")
                            |> List.map .name

                    segs =
                        String.split "/" dir |> List.filter ((/=) "")
                in
                case List.reverse segs of
                    "plans" :: _ ->
                        -- .../plans: each subdir is a PLAN dir — queue
                        -- its meta.json read AND its dir listing (to
                        -- reach nested node sessions).
                        continue
                            { scan
                                | readQueue =
                                    scan.readQueue
                                        ++ List.map (\p -> dir ++ "/" ++ p ++ "/" ++ p ++ ".meta.json") dirsIn
                                , dirQueue =
                                    scan.dirQueue
                                        ++ List.map (\p -> dir ++ "/" ++ p) dirsIn
                            }
                            counter

                    _ :: "plans" :: _ ->
                        -- .../plans/<planId>: subdirs are node dirs
                        -- (and work/) — queue them for listing (the
                        -- node level yields the nested refs).
                        continue
                            { scan
                                | dirQueue =
                                    scan.dirQueue
                                        ++ List.map (\n -> dir ++ "/" ++ n) (List.filter ((/=) "work") dirsIn)
                            }
                            counter

                    _ ->
                        -- .../plans/<planId>/<nodeId>: subdirs are node
                        -- session dirs (<uuid>) — record each session's
                        -- REAL (nested) directory so plans it creates
                        -- stay in this subtree (P28 layout fix) AND
                        -- queue their session.refs.json (C3-2: node
                        -- cascade fork's work-copy record).
                        continue
                            { scan
                                | nodeRefsQueue =
                                    scan.nodeRefsQueue
                                        ++ List.map (\n -> dir ++ "/" ++ n ++ "/session.refs.json") dirsIn
                            }
                            counter
                        |> withDirEffects dir dirsIn

            Nothing ->
                -- The sessions/ listing: queue every session's plans/
                -- subdir (missing plans dirs list empty; ".." from the
                -- listing is skipped) AND every session's version refs
                -- (sessions/<uuid>/session.refs.json — C architecture:
                -- session ROOT refs; work-copy directories have no
                -- refs and are never registered).
                let
                    sessionDirs =
                        entries
                            |> List.filter (\e -> e.isDir && e.name /= ".." && e.name /= ".")
                            |> List.map .name

                    planDirs =
                        List.map (\n -> sessionsRoot ++ "/" ++ n ++ "/plans") sessionDirs

                    sessionMetaQueue =
                        List.map (\n -> sessionsRoot ++ "/" ++ n ++ "/session.refs.json") sessionDirs
                in
                case planDirs of
                    next :: rest ->
                        let
                            ( reqId, counter1 ) =
                                allocReqId counter
                        in
                        ( { scan
                            | dirQueue = rest
                            , dirListing = Just next
                            , sessionQueue = sessionMetaQueue
                            , scanReqId = Just reqId
                          }
                        , counter1
                        , sessionDirEffects sessionsRoot sessionDirs
                            ++ [ ListDir reqId next ]
                        )

                    [] ->
                        -- No plans dirs anywhere: go straight to reading
                        -- the session lineage refs.
                        case sessionMetaQueue of
                            r :: rs ->
                                let
                                    ( reqId, counter1 ) =
                                        allocReqId counter
                                in
                                ( { scan
                                    | scanReqId = Nothing
                                    , reading = Just r
                                    , readReqId = Just reqId
                                    , sessionQueue = rs
                                    , readQueue = []
                                    , loading = False
                                  }
                                , counter1
                                , [ ReadText reqId r ]
                                )

                            [] ->
                                ( { scan | scanReqId = Nothing, loading = False }
                                , counter
                                , []
                                )


{-| RememberDir effects for a node-dir listing (each subdir is a real
session directory nested under the node). Prepended after `continue`
so the walk's next request is issued first and the map writes follow
(ordering between effects is irrelevant — they never conflict).
-}
withDirEffects : String -> List String -> ( Scan, Int, List Effect ) -> ( Scan, Int, List Effect )
withDirEffects dir dirsIn ( scan, counter, effects ) =
    ( scan
    , counter
    , effects
        ++ List.map (\n -> RememberDir n (dir ++ "/" ++ n)) dirsIn
    )


sessionDirEffects : String -> List String -> List Effect
sessionDirEffects sessionsRoot sessionDirs =
    List.map (\n -> RememberDir n (sessionsRoot ++ "/" ++ n)) sessionDirs


{-| Drain the walk: list the next queued directory; when no directories
remain, start the queued reads (session refs ++ node refs ++ metas, in
that order); when nothing remains, the rebuild is done.
-}
continue : Scan -> Int -> ( Scan, Int, List Effect )
continue scan counter =
    case scan.dirQueue of
        next :: rest ->
            let
                ( reqId, counter1 ) =
                    allocReqId counter
            in
            ( { scan | dirQueue = rest, dirListing = Just next, scanReqId = Just reqId }
            , counter1
            , [ ListDir reqId next ]
            )

        [] ->
            let
                readQueue =
                    scan.sessionQueue ++ scan.nodeRefsQueue ++ scan.readQueue
            in
            case readQueue of
                r :: rs ->
                    let
                        ( reqId, counter1 ) =
                            allocReqId counter
                    in
                    ( { scan
                        | dirListing = Nothing
                        , scanReqId = Nothing
                        , reading = Just r
                        , readReqId = Just reqId
                        , sessionQueue = []
                        , nodeRefsQueue = []
                        , readQueue = rs
                        , loading = False
                      }
                    , counter1
                    , [ ReadText reqId r ]
                    )

                [] ->
                    ( { scan | dirListing = Nothing, scanReqId = Nothing, loading = False }
                    , counter
                    , []
                    )


{-| A text-read result for the scan. session.refs.json content feeds
sessionRefs (and may demand a version-object load for its head); every
other path is a plan meta.json feeding planMetas. Either way the chain
continues with the next queued read (a failed/corrupt read is skipped,
not fatal).
-}
onReadResult : Scan -> Int -> Dict String AV.Version -> Bool -> String -> ( Scan, Int, List Effect )
onReadResult scan counter versionCache ok content =
    let
        path =
            Maybe.withDefault "" scan.reading

        readEffects =
            if ok then
                if String.endsWith "/session.refs.json" path then
                    case D.decodeString AV.decodeSessionRefs content of
                        Ok refs ->
                            if refs.head /= "" && not (Dict.member refs.head versionCache) then
                                [ RememberRefs refs, GetObject refs.head ]

                            else
                                [ RememberRefs refs ]

                        Err _ ->
                            []

                else
                    case D.decodeString PM.decodeMeta content of
                        Ok meta ->
                            -- planId = the meta file name minus
                            -- ".meta.json" (paths are
                            -- sessions/<origin>/plans/<planId>/<planId>.meta.json).
                            let
                                planId =
                                    path
                                        |> String.split "/"
                                        |> List.reverse
                                        |> List.head
                                        |> Maybe.withDefault path
                                        |> String.dropRight (String.length ".meta.json")
                            in
                            [ RememberMeta planId meta ]

                        Err _ ->
                            []

            else
                -- A failed meta read (missing/corrupt file): skip it,
                -- keep the chain going.
                []
    in
    case scan.readQueue of
        next :: rest ->
            let
                ( reqId, counter1 ) =
                    allocReqId counter
            in
            ( { scan | reading = Just next, readQueue = rest, readReqId = Just reqId }
            , counter1
            , readEffects ++ [ ReadText reqId next ]
            )

        [] ->
            ( { scan | reading = Nothing, readReqId = Nothing }
            , counter
            , readEffects
            )
