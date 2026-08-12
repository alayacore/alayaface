module Arch.Values exposing
    ( Hash
    , Block
    , RunSummary
    , Version
    , SessionRefs
    , blockSize
    , chunkMessages
    , encodeBlock
    , encodeRunSummary
    , encodeVersion
    , encodeSessionRefs
    , encodeMessage
    , blockContent
    , runContent
    , versionContent
    , refsContent
    , decodeBlock
    , decodeRunSummary
    , decodeVersion
    , decodeSessionRefs
    , decodeMessage
    )

{-| C architecture immutable value types (docs/arch-persistent.md §3) —
the Elm representation of content-addressed objects (reference = content
hash) plus codecs and pure algorithms.

Core invariants:
  I1  Block / RunSummary / Version are immutable once created (never mutated)
  I2  a plan's "displayed state" = planViews inside the session version
      (not a plan-global field)
  I3  messages are chunked at fixed sizes; equal chunk content hashes =
      structural sharing (zero copy)
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Session.Types as T


type alias Hash =
    String


{-| Message block: an immutable slice of a message sequence (the
smallest unit of the object store).
-}
type alias Block =
    { messages : List T.Message }


{-| Immutable snapshot of one plan run: the minimal info needed by the
status bar / plan overview. Full node detail stays in the run.json
workspace; versioning only freezes this summary.
-}
type alias RunSummary =
    { runId : String
    , status : String
    , startedAt : Int
    , finishedAt : Maybe Int
    , summary : String
    }


{-| Session version (immutable): a message block reference sequence
(prefix-shared) + the run each plan saw in this version. `planViews`:
planId → run hash; Nothing = never executed under this version.
-}
type alias Version =
    { blocks : List Hash
    , planViews : Dict String (Maybe Hash)
    , parent : Maybe Hash
    }


{-| Session refs layer (mutable, lightweight): id is stable (= creation
id); head = current version; versions = version history; workCopy =
current work-copy directory id (C2b: after fork/resume = the new
alayacore session directory; Nothing = the root directory itself is the
work copy). **There is no conversation/instance split.**
-}
type alias SessionRefs =
    { id : String
    , head : Hash
    , versions : List Hash
    , workCopy : Maybe String
    }


{-| Message block size (in messages). A block is the smallest unit of
content-addressed sharing: message blocks unchanged since before a plan
hash identically in old and new versions → shared automatically (zero copy).
-}
blockSize : Int
blockSize =
    50


{-| Split a message list into fixed-size blocks (pure function; the
caller object_puts each block, gets its hash, then assembles the Version).
-}
chunkMessages : List T.Message -> List Block
chunkMessages msgs =
    let
        step acc rest =
            case List.take blockSize rest of
                [] ->
                    List.reverse acc

                chunk ->
                    step (Block chunk :: acc) (List.drop blockSize rest)
    in
    step [] msgs


-- ─── Encoding ───────────────────────────────────────────────────────

{-| The object_put content string (object-store key = content hash).
-}
blockContent : Block -> String
blockContent b =
    E.encode 2 (encodeBlock b)


versionContent : Version -> String
versionContent v =
    E.encode 2 (encodeVersion v)


runContent : RunSummary -> String
runContent r =
    E.encode 2 (encodeRunSummary r)


refsContent : SessionRefs -> String
refsContent s =
    E.encode 2 (encodeSessionRefs s)


encodeBlock : Block -> E.Value
encodeBlock b =
    E.object [ ( "messages", E.list encodeMessage b.messages ) ]


encodeRunSummary : RunSummary -> E.Value
encodeRunSummary r =
    E.object
        [ ( "runId", E.string r.runId )
        , ( "status", E.string r.status )
        , ( "startedAt", E.int r.startedAt )
        , ( "finishedAt", maybeInt r.finishedAt )
        , ( "summary", E.string r.summary )
        ]


encodeVersion : Version -> E.Value
encodeVersion v =
    E.object
        [ ( "blocks", E.list E.string v.blocks )
        , ( "planViews", E.dict identity encodeMaybeRun v.planViews )
        , ( "parent", maybeString v.parent )
        ]


encodeSessionRefs : SessionRefs -> E.Value
encodeSessionRefs s =
    E.object
        [ ( "id", E.string s.id )
        , ( "head", E.string s.head )
        , ( "versions", E.list E.string s.versions )
        , ( "workCopy", maybeString s.workCopy )
        ]


encodeMessage : T.Message -> E.Value
encodeMessage m =
    E.object
        [ ( "id", E.string m.id )
        , ( "role", E.string (T.roleToString m.role) )
        , ( "content", E.string m.content )
        , ( "toolId", maybeString m.toolId )
        , ( "toolName", maybeString m.toolName )
        , ( "isError", E.bool m.isError )
        , ( "historyId", maybeString m.historyId )
        , ( "media", maybeEncodeList encodeMedia m.media )
        ]


encodeMedia : T.MediaItem -> E.Value
encodeMedia mi =
    E.object
        [ ( "mediaType", E.string (T.mediaTypeToString mi.mediaType) )
        , ( "uri", E.string mi.uri )
        , ( "name", maybeString mi.name )
        ]


maybeString : Maybe String -> E.Value
maybeString v =
    case v of
        Just s ->
            E.string s

        Nothing ->
            E.null


maybeInt : Maybe Int -> E.Value
maybeInt v =
    case v of
        Just n ->
            E.int n

        Nothing ->
            E.null


maybeEncodeList : (a -> E.Value) -> Maybe (List a) -> E.Value
maybeEncodeList enc v =
    case v of
        Just xs ->
            E.list enc xs

        Nothing ->
            E.null


encodeMaybeRun : Maybe Hash -> E.Value
encodeMaybeRun v =
    maybeString v


-- ─── Decoding ───────────────────────────────────────────────────────

decodeBlock : D.Decoder Block
decodeBlock =
    D.map Block
        (D.field "messages" (D.list decodeMessage))


decodeRunSummary : D.Decoder RunSummary
decodeRunSummary =
    D.map5 RunSummary
        (D.field "runId" D.string)
        (D.field "status" D.string)
        (D.field "startedAt" D.int)
        (D.field "finishedAt" (D.maybe D.int))
        (D.field "summary" D.string)


decodeVersion : D.Decoder Version
decodeVersion =
    D.map3 Version
        (D.field "blocks" (D.list D.string))
        (D.field "planViews" (D.dict decodeMaybeRun))
        (D.field "parent" (D.maybe D.string))


decodeSessionRefs : D.Decoder SessionRefs
decodeSessionRefs =
    D.map4 SessionRefs
        (D.field "id" D.string)
        (D.field "head" D.string)
        (D.field "versions" (D.list D.string))
        -- Lenient: pre-C2b files have no workCopy field (= root dir is the work copy).
        (D.oneOf [ D.field "workCopy" D.string |> D.map Just, D.succeed Nothing ])


decodeMaybeRun : D.Decoder (Maybe Hash)
decodeMaybeRun =
    D.nullable D.string


decodeMessage : D.Decoder T.Message
decodeMessage =
    D.map8 T.Message
        (D.field "id" D.string)
        (D.field "role" decodeRole)
        (D.field "content" D.string)
        (D.field "toolId" (D.maybe D.string))
        (D.field "toolName" (D.maybe D.string))
        (D.field "isError" D.bool)
        (D.field "historyId" (D.maybe D.string))
        (D.field "media" (D.maybe (D.list decodeMedia)))


decodeRole : D.Decoder T.Role
decodeRole =
    D.string
        |> D.andThen
            (\s ->
                case T.roleFromString s of
                    Just role ->
                        D.succeed role

                    Nothing ->
                        D.fail ("unknown role: " ++ s)
            )


decodeMedia : D.Decoder T.MediaItem
decodeMedia =
    D.map3 T.MediaItem
        (D.field "mediaType" decodeMediaType)
        (D.field "uri" D.string)
        (D.field "name" (D.maybe D.string))


decodeMediaType : D.Decoder T.MediaType
decodeMediaType =
    D.string
        |> D.andThen
            (\s ->
                case T.mediaTypeFromString s of
                    Just mt ->
                        D.succeed mt

                    Nothing ->
                        D.fail ("unknown media type: " ++ s)
            )
