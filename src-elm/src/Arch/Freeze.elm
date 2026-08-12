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

{-| C architecture version-freeze state machine (docs/arch-persistent.md
§4.2) — pure logic: the async flow that freezes a session's work copy
into an immutable Version (object-store put progress tracking).
App/Update feeds the Ports.objectPut results back in.

Flow:
  1. begin: chunk messages + pre-allocate reqIds (blocks 0..n-1, runs n..n+m-1)
  2. initialPuts: the objects to put, as (reqId, content)
  3. onPutResult: collect hashes by reqId
  4. buildVersion: once all are ready, assemble the Version (planViews
     complete: every plan in `runs` → its run hash; every plan in
     `unexecuted` → Nothing)
-}

import Dict exposing (Dict)
import Arch.Values as AV
import Session.Types as T


type alias FreezeState =
    { sessionId : String
    , blocks : List AV.Block
    , blockHashes : Dict Int String
    -- plan states frozen in this run: (planId, RunSummary), reqId = n + idx
    , runs : List ( String, AV.RunSummary )
    , runHashes : Dict Int String
    -- plans not executed under this version (Nothing in the view)
    , unexecuted : List String
    , parent : Maybe String
    -- C2b: this session's current work copy's **persistable directory
    -- id** (written to refs.workCopy; see Plan.Update.persistableWorkCopy
    -- — fork directory / resume keeps the old value / root = Nothing)
    , workCopy : Maybe String
    -- the assembled version object (stashed after buildVersion succeeds,
    -- used to fill versionCache when the version put completes)
    , built : Maybe AV.Version
    , versionHash : Maybe String
    }


{-| Begin a freeze. `runs` = the plan states to record as "executed"
this time (order fixed, reqIds start at the block count); `unexecuted` =
plans never executed under this version.
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


{-| The initial objects to put (blocks 0..n-1, runs n..n+m-1).
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


{-| Handle one object_put result (matched by reqId), returning the
advanced state.
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


{-| The version object's reqId (= block count + run count): once all
blocks and runs are put, the caller uses it to put the assembled Version.
-}
versionReq : FreezeState -> Int
versionReq st =
    List.length st.blocks + List.length st.runs


{-| All blocks and runs ready → assemble the Version; otherwise Nothing.
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


{-| The version has been frozen (versionHash written) — the freeze flow
is complete.
-}
isComplete : FreezeState -> Bool
isComplete st =
    st.versionHash /= Nothing


{-| The run summary map produced by this freeze (run hash → RunSummary) —
when the freeze completes, the caller merges it into the in-memory
runSummaries cache (the status bar resolves by version).
-}
runSummaries : FreezeState -> Dict String AV.RunSummary
runSummaries st =
    List.indexedMap
        (\i ( _, r ) -> ( Dict.get i st.runHashes, r ))
        st.runs
        |> List.filterMap (\( h, r ) -> Maybe.map (\hh -> ( hh, r )) h)
        |> Dict.fromList
