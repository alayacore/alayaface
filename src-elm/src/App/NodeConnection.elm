module App.NodeConnection exposing
    ( NodeConnection
    , ChainCtx
    , ChainSegment
    , nodeConnectionFor
    , nodeLabelFor
    , parseNodeConnection
    , liveSessionForOrigin
    , chainForSession
    , chainForPlan
    )

{-| Node ↔ session connection lookup (pure, testable).

A session window "belongs to" a plan node when its id appears in
`planNodeSessions` (sid → "planId/nodeId" badge label). C3/C5：窗口 key
= Session.id（resume/fork 不换身份），直接按 id 查绑定。

The reverse direction (plan window → its owning session) uses the plan's
meta.json origin: the ORIGINAL session id that auto-created the plan.
`liveSessionForOrigin` resolves that to the live window id (sessions are
keyed by Session.id under C2b, so it is the id itself when open).

Since P36, the app draws a whole CONNECTION CHAIN, not a single curve:
when a deep node session is focused (or a sub-plan window is active),
every segment from that window up through each ancestor plan↔session
pair to the TOP-LEVEL session is drawn, so the user can trace the lines
all the way up. `chainForSession` / `chainForPlan` build that chain
purely from `ChainCtx` (the dicts the app already tracks).

This module is shared by App.Update (focus → z-pairing + curve port) and
App.Types (Model field) without dragging in the whole app model.
-}

import Dict exposing (Dict)
import Set exposing (Set)


type alias NodeConnection =
    { sessionId : String
    , planId : String
    , nodeId : String
    }


{-| One segment of the active connection chain. `kind` is
- "node" → the bezier from a session window to a node card in its plan
  window (`sessionId` = the node session, `planId` = its plan,
  `nodeId` = Just the node card);
- "plan" → the bezier from a plan window to its owning session
  (`sessionId` = the LIVE owning session, `planId` = the plan,
  `nodeId` = Nothing).

Kept as a plain record (not a union type) because it crosses the Elm↔JS
port boundary, which only accepts JSON values.
-}
type alias ChainSegment =
    { kind : String
    , sessionId : String
    , planId : String
    , nodeId : Maybe String
    }


{-| The pure inputs the chain builder needs, lifted from the app model:
- `nodeSessions` — session id → "planId/nodeId" binding label;
- `liveSessions` — ids of sessions with an open window right now;
- `planOrigins` — plan id → its owning session's ON-DISK id (from
  meta.json origin; the plan lives under that dir id).
-}
type alias ChainCtx =
    { nodeSessions : Dict String String
    , liveSessions : Dict String ()
    , planOrigins : Dict String String
    }


nodeSegment : String -> String -> String -> ChainSegment
nodeSegment sid planId nodeId =
    { kind = "node", sessionId = sid, planId = planId, nodeId = Just nodeId }


planSegment : String -> String -> ChainSegment
planSegment planId sid =
    { kind = "plan", sessionId = sid, planId = planId, nodeId = Nothing }


{-| Resolve a session id to the window currently showing it: C2b/C3 下
窗口按 Session.id key——会话开着 → Just 自身；否则 Nothing。
-}
liveSessionForOrigin : Dict String a -> String -> Maybe String
liveSessionForOrigin liveSessions origId =
    if Dict.member origId liveSessions then
        Just origId

    else
        Nothing


{-| The "planId/nodeId" badge label for a session id（窗口按 Session.id
key，直接查绑定）。
-}
nodeLabelFor : Dict String String -> String -> Maybe String
nodeLabelFor planNodeSessions sid =
    Dict.get sid planNodeSessions


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
nodeConnectionFor : Dict String String -> String -> Maybe NodeConnection
nodeConnectionFor planNodeSessions sid =
    nodeLabelFor planNodeSessions sid
        |> Maybe.andThen parseNodeConnection
        |> Maybe.map
            (\( planId, nodeId ) ->
                { sessionId = sid, planId = planId, nodeId = nodeId }
            )


{-| Walk UP the ancestor chain of `planId`, appending one segment per
level to `acc` (built in reverse; reversed once at the end):

1. the plan↔owning-session segment (the plan window to the LIVE session
   that created it — its `[Plan: …]` button when visible);
2. if that owning session is ITSELF a plan node session, its own
   node↔session segment, then continue with the parent plan;

…until a plain (top-level) session is reached, the owning session has no
open window, the plan has no meta, or a cycle is detected (`visited`).
-}
ancestorChain : ChainCtx -> String -> Set String -> List ChainSegment -> List ChainSegment
ancestorChain ctx planId visited acc =
    if Set.member planId visited then
        List.reverse acc

    else
        case Dict.get planId ctx.planOrigins of
            Nothing ->
                List.reverse acc

            Just originDiskId ->
                case liveSessionForOrigin ctx.liveSessions originDiskId of
                    Nothing ->
                        List.reverse acc

                    Just liveOrigin ->
                        let
                            acc1 =
                                planSegment planId liveOrigin :: acc
                        in
                        case nodeConnectionFor ctx.nodeSessions liveOrigin of
                            Nothing ->
                                List.reverse acc1

                            Just parent ->
                                if Set.member parent.planId (Set.insert planId visited) then
                                    -- Parent plan already on the path →
                                    -- would loop; stop without adding its
                                    -- segment.
                                    List.reverse acc1

                                else
                                    ancestorChain ctx parent.planId
                                        (Set.insert planId visited)
                                        (nodeSegment liveOrigin parent.planId parent.nodeId :: acc1)


{-| The FULL connection chain for a focused session: its own
node↔session segment first, then every ancestor segment up to the
top-level session — so focusing a DEEP node session shows the whole
path ("through the lines you can directly find the topmost session
window"). [] for plain sessions (not bound to a plan node).
-}
chainForSession : ChainCtx -> String -> List ChainSegment
chainForSession ctx sid =
    case nodeConnectionFor ctx.nodeSessions sid of
        Nothing ->
            []

        Just conn ->
            ancestorChain ctx conn.planId Set.empty
                [ nodeSegment sid conn.planId conn.nodeId ]


{-| The FULL connection chain for an active plan window: the plan's own
segment to its owning session, plus (for a sub-plan) that owning
session's whole ancestor chain up to the top-level session. [] when the
plan has no meta or its owning session is closed.
-}
chainForPlan : ChainCtx -> String -> List ChainSegment
chainForPlan ctx planId =
    case Dict.get planId ctx.planOrigins of
        Nothing ->
            []

        Just originDiskId ->
            case liveSessionForOrigin ctx.liveSessions originDiskId of
                Nothing ->
                    []

                Just liveOrigin ->
                    case nodeConnectionFor ctx.nodeSessions liveOrigin of
                        -- Top-level plan: just the plan↔session segment.
                        Nothing ->
                            [ planSegment planId liveOrigin ]

                        -- Sub-plan: the plan segment, then the owning
                        -- (node) session's own segment + its ancestors.
                        Just parent ->
                            ancestorChain ctx parent.planId
                                (Set.singleton planId)
                                (nodeSegment liveOrigin parent.planId parent.nodeId
                                    :: planSegment planId liveOrigin
                                    :: []
                                )
