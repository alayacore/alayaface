module App.NodeConnection exposing
    ( NodeConnection
    , PlanConnection
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


type alias NodeConnection =
    { sessionId : String
    , planId : String
    , nodeId : String
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
completed binding, etc).
-}
nodeConnectionFor : Dict String String -> Dict String String -> String -> Maybe NodeConnection
nodeConnectionFor planNodeSessions planResumedFrom sid =
    nodeLabelFor planNodeSessions planResumedFrom sid
        |> Maybe.andThen parseNodeConnection
        |> Maybe.map
            (\( planId, nodeId ) ->
                { sessionId = sid, planId = planId, nodeId = nodeId }
            )
