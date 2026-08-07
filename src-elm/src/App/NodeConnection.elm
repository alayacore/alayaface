module App.NodeConnection exposing
    ( NodeConnection
    , PlanConnection
    , AncestorEdge
    , ancestorEdges
    , nodeConnectionFor
    , nodeLabelFor
    , parseNodeConnection
    , liveSessionForOrigin
    )

{-| Node ↔ session connection lookup (pure, testable).

A session window "belongs to" a plan node when its id appears in
`planNodeSessions` (sid → "planId/nodeId" badge label). Resumed sessions
get a FRESH id (P18) — resolve them through `planResumedFrom`
(live id → original dir id) first, then look up the label for the
original id.

The reverse direction (plan window → its owning session) uses the plan's
meta.json origin: the ORIGINAL session id that auto-created the plan.
`liveSessionForOrigin` resolves that to the LIVE window id (the original
if it is open, else the fresh id of a resume of it).

This module is shared by App.Update (focus → z-pairing + curve port) and
App.Types (Model field) without dragging in the whole app model.
-}

import Dict exposing (Dict)
import Set exposing (Set)


type alias NodeConnection =
    { sessionId : String
    , planId : String
    , nodeId : String
    , ancestors : List AncestorEdge
    }


{-| A dependency edge `from → to` between two nodes of the same plan.
When a node session is focused, every edge on a path from the plan root
down to that node is drawn (so the whole ancestor chain lights up, e.g.
A→B→C→D when D is selected).
-}
type alias AncestorEdge =
    { from : String
    , to : String
    }


{-| The plan window ↔ owning session connection: which plan window is
connected to which LIVE session window.
-}
type alias PlanConnection =
    { planId : String
    , sessionId : String
    }


{-| Resolve an on-disk (original) session id to the id of the window
currently showing it: the original id if that session is open, or the
fresh id of a resume of it (`planResumedFrom` fresh → original, with the
fresh one still open).
-}
liveSessionForOrigin : Dict String a -> Dict String String -> String -> Maybe String
liveSessionForOrigin liveSessions planResumedFrom origId =
    if Dict.member origId liveSessions then
        Just origId

    else
        Dict.foldl
            (\fresh orig acc ->
                case acc of
                    Just _ ->
                        acc

                    Nothing ->
                        if orig == origId && Dict.member fresh liveSessions then
                            Just fresh

                        else
                            Nothing
            )
            Nothing
            planResumedFrom


{-| The "planId/nodeId" badge label for a session id, resolving resumed
(fresh-id) sessions back to their original on-disk id first.
-}
nodeLabelFor : Dict String String -> Dict String String -> String -> Maybe String
nodeLabelFor planNodeSessions planResumedFrom sid =
    case Dict.get sid planNodeSessions of
        Just label ->
            Just label

        Nothing ->
            Dict.get sid planResumedFrom
                |> Maybe.andThen (\origId -> Dict.get origId planNodeSessions)


{-| Split a "planId/nodeId" label. Node ids may themselves contain "/",
so everything after the first segment is the node id. Empty labels are
rejected (they can never be a real binding).
-}
parseNodeConnection : String -> Maybe ( String, String )
parseNodeConnection label =
    if String.isEmpty label then
        Nothing

    else
        case String.split "/" label of
            planId :: rest ->
                Just ( planId, String.join "/" rest )

            [] ->
                Nothing


{-| Build the connection for a session id: which plan window and which
node card does this session belong to. Returns Nothing for sessions that
are not bound to a plan node (plain chats, runner sessions without a
completed binding, etc). The `ancestors` list is filled in later by the
Update layer (it needs the parsed plan); here it starts empty.
-}
nodeConnectionFor : Dict String String -> Dict String String -> String -> Maybe NodeConnection
nodeConnectionFor planNodeSessions planResumedFrom sid =
    nodeLabelFor planNodeSessions planResumedFrom sid
        |> Maybe.andThen parseNodeConnection
        |> Maybe.map
            (\( planId, nodeId ) ->
                { sessionId = sid
                , planId = planId
                , nodeId = nodeId
                , ancestors = []
                }
            )


{-| All dependency edges that lie on SOME path from a plan root down to
`nodeId` — i.e. every edge (parent → child) where the child is `nodeId`
or an ancestor of it. Given the A→B→C→D chain, focusing D yields
[(A,B),(B,C),(C,D)]; a diamond A→B,A→C,B→D,C→D focusing D yields all
four edges. `nodes` is the task list as (id, dependsOn) pairs.
-}
ancestorEdges : List ( String, List String ) -> String -> List AncestorEdge
ancestorEdges nodes nodeId =
    let
        depsOf =
            Dict.fromList nodes

        relevant =
            collectAncestors depsOf nodeId Set.empty

        onPath id =
            Set.member id relevant
    in
    List.filterMap
        (\( id, deps ) ->
            if onPath id then
                Just ( id, List.filter onPath deps )

            else
                Nothing
        )
        nodes
        |> List.concatMap
            (\( child, parents ) ->
                List.map (\p -> { from = p, to = child }) parents
            )


{-| Transitive closure of parents of `nodeId` (including itself).
Terminates on cycles via the visited set (plans are validated acyclic,
but a malformed hand-edited file must not hang the UI).
-}
collectAncestors : Dict String (List String) -> String -> Set String -> Set String
collectAncestors depsOf id acc =
    if Set.member id acc then
        acc

    else
        case Dict.get id depsOf of
            Nothing ->
                Set.insert id acc

            Just deps ->
                List.foldl (\d a -> collectAncestors depsOf d a) (Set.insert id acc) deps
