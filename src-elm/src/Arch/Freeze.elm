module Arch.Freeze exposing
    ( FreezeState
    , begin
    , initialPuts
    , onPutResult
    , buildVersion
    , versionReq
    , isComplete
    , runSummaries
    )

{-| C 架构版本固化状态机（docs/arch-persistent.md §4.2）——纯逻辑：
把会话工作副本固化为不可变 Version 的异步流程（对象存储 put 的
进度跟踪）。App/Update 负责把 Ports.objectPut 的结果喂进来。

流程：
  1. begin：切块 + 预分配 reqId（块 0..n-1，run = n..n+m-1）
  2. initialPuts：需要 put 的对象列表（(reqId, content)）
  3. onPutResult：按 reqId 收集 hash
  4. buildVersion：全部就绪 → 组装 Version（planViews 完整：runs 里
     每个 plan → 其 run hash；unexecuted 里每个 plan → Nothing）
-}

import Dict exposing (Dict)
import Arch.Values as AV
import Session.Types as T


type alias FreezeState =
    { sessionId : String
    , blocks : List AV.Block
    , blockHashes : Dict Int String
    -- 本次固化的 plan 状态：(planId, RunSummary)，reqId = n + idx
    , runs : List ( String, AV.RunSummary )
    , runHashes : Dict Int String
    -- 该版本下未执行的 plan（视图里 Nothing）
    , unexecuted : List String
    , parent : Maybe String
    -- C2b：该会话当前工作副本的**可持久化目录 id**（写入 refs.workCopy；
    -- 见 Plan.Update.persistableWorkCopy——fork 目录 / resume 保留旧值 /
    -- 根 = Nothing）
    , workCopy : Maybe String
    -- 组装好的版本对象（buildVersion 成功后暂存，version put 完成时
    -- 用它填充 versionCache）
    , built : Maybe AV.Version
    , versionHash : Maybe String
    }


{-| 开始一次固化。`runs` = 本次要记录为"已执行"的 plan 状态（顺序
固定，reqId 从块数开始）；`unexecuted` = 该版本下从未执行的 plan。
-}
begin : String -> List T.Message -> List ( String, AV.RunSummary ) -> List String -> Maybe String -> Maybe String -> FreezeState
begin sessionId messages runs unexecuted parent workCopy =
    { sessionId = sessionId
    , blocks = AV.chunkMessages messages
    , blockHashes = Dict.empty
    , runs = runs
    , runHashes = Dict.empty
    , unexecuted = unexecuted
    , parent = parent
    , workCopy = workCopy
    , built = Nothing
    , versionHash = Nothing
    }


{-| 初始需要 put 的对象（块 0..n-1，run = n..n+m-1）。
-}
initialPuts : FreezeState -> List ( Int, String )
initialPuts st =
    let
        blockPuts =
            List.indexedMap (\i b -> ( i, AV.blockContent b )) st.blocks

        n =
            List.length st.blocks

        runPuts =
            List.indexedMap
                (\i ( _, r ) -> ( n + i, AV.runContent r ))
                st.runs
    in
    blockPuts ++ runPuts


{-| 处理一个 object_put 结果（reqId 匹配），返回推进后的状态。
-}
onPutResult : Int -> Maybe String -> FreezeState -> FreezeState
onPutResult reqId hash st =
    let
        n =
            List.length st.blocks

        m =
            List.length st.runs
    in
    case hash of
        Nothing ->
            st

        Just h ->
            if reqId < n then
                { st | blockHashes = Dict.insert reqId h st.blockHashes }

            else if reqId < n + m then
                { st | runHashes = Dict.insert (reqId - n) h st.runHashes }

            else if reqId == n + m then
                { st | versionHash = Just h }

            else
                st


{-| 版本对象的 reqId（= 块数 + run 数）：块和 run 全部 put 完成后，
调用方用它 put 组装好的 Version。
-}
versionReq : FreezeState -> Int
versionReq st =
    List.length st.blocks + List.length st.runs


{-| 所有块和 run 就绪 → 组装 Version；否则 Nothing。
-}
buildVersion : FreezeState -> Maybe AV.Version
buildVersion st =
    let
        n =
            List.length st.blocks

        m =
            List.length st.runs

        blocksReady =
            List.range 0 (n - 1) |> List.all (\i -> Dict.member i st.blockHashes)

        runsReady =
            List.range 0 (m - 1) |> List.all (\i -> Dict.member i st.runHashes)
    in
    if blocksReady && runsReady then
        let
            runViews =
                List.indexedMap
                    (\i ( pid, _ ) ->
                        ( pid, Dict.get i st.runHashes )
                    )
                    st.runs

            unexecutedViews =
                List.map (\pid -> ( pid, Nothing )) st.unexecuted

            planViews =
                Dict.fromList (runViews ++ unexecutedViews)
        in
        Just
            { blocks = List.map (\i -> Dict.get i st.blockHashes |> Maybe.withDefault "") (List.range 0 (n - 1))
            , planViews = planViews
            , parent = st.parent
            }

    else
        Nothing


{-| 版本已固化（versionHash 已写）——固化流程完成。
-}
isComplete : FreezeState -> Bool
isComplete st =
    st.versionHash /= Nothing


{-| 本次固化产生的 run 摘要映射（run hash → RunSummary）——固化完成
时调用方把它并入内存 runSummaries 缓存（状态栏按版本解析需要）。
-}
runSummaries : FreezeState -> Dict String AV.RunSummary
runSummaries st =
    List.indexedMap
        (\i ( _, r ) -> ( Dict.get i st.runHashes, r ))
        st.runs
        |> List.filterMap (\( h, r ) -> Maybe.map (\hh -> ( hh, r )) h)
        |> Dict.fromList
