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

{-| C 架构不可变值类型（docs/arch-persistent.md §3）——内容寻址对象
（引用 = 内容 hash）的 Elm 表示 + 编解码 + 纯算法。

核心不变式：
  I1  Block / RunSummary / Version 一经创建不可变（写后不更）
  I2  plan 的"显示状态" = 会话版本里的 planViews（不是 plan 全局字段）
  I3  消息按固定块切分，块内容 hash 相同 = 结构共享（零拷贝）
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Session.Types as T


type alias Hash =
    String


{-| 消息块：不可变消息序列片段（对象存储的最小单元）。
-}
type alias Block =
    { messages : List T.Message }


{-| plan 的一次运行快照（不可变）：状态栏 / plan 概览所需的最小信息。
完整的节点细节留在 run.json 工作区；版本化只固化这个摘要。
-}
type alias RunSummary =
    { runId : String
    , status : String
    , startedAt : Int
    , finishedAt : Maybe Int
    , summary : String
    }


{-| 会话版本（不可变）：消息块引用序列（前缀共享）+ 每个 plan 在本版本
看到的 run。`planViews`：planId → run hash；Nothing = 该版本下从未执行。
-}
type alias Version =
    { blocks : List Hash
    , planViews : Dict String (Maybe Hash)
    , parent : Maybe Hash
    }


{-| 会话的引用层（可变，轻量）：id 稳定（= 创建 id）；head = 当前版本；
versions = 版本历史；workCopy = 当前工作副本目录 id（C2b：fork/resume
后 = 新 alayacore 会话目录；Nothing = 根目录自身就是工作副本）。
**没有 conversation/instance 之分。**
-}
type alias SessionRefs =
    { id : String
    , head : Hash
    , versions : List Hash
    , workCopy : Maybe String
    }


{-| 消息块大小（条）。块 = 内容寻址共享的最小粒度：plan 之前不变的
消息块在新旧版本里 hash 相同 → 自动共享（零拷贝）。
-}
blockSize : Int
blockSize =
    50


{-| 把消息列表切成固定大小的块（纯函数；调用方负责把每块 object_put
拿到 hash 再组装 Version）。
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


-- ─── 编码 ───────────────────────────────────────────────────────────

{-| object_put 的 content 字符串（对象存储键 = 内容的 hash）。
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


-- ─── 解码 ───────────────────────────────────────────────────────────

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
        -- Lenient：C2b 前无 workCopy 字段（= 根目录即工作副本）。
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
