module Session.Meta exposing
    ( SessionMeta
    , empty
    , encode
    , decode
    , metaPathFor
    , resolveConversation
    )

{-| Session lineage (P39/Phase B): per-session metadata written by the
UI into `sessions/<instanceId>/session.meta.json`:

    {
      "conversation_id": "<root 会话 id，永不变化>",
      "parent_instance_id": "<父实例 id；root 为 null>"
    }

A CONVERSATION is the stable identity (its id = the ROOT instance that
created it); every FORK of that conversation is a new PHYSICAL INSTANCE
whose `parent_instance_id` points at the instance it was forked from.
The lineage chain = following parent pointers back to the root.
`meta.origin.sessionId` and node bindings point at the CONVERSATION id
(never change); physical instances resolve to their conversation via
this registry (`resolveConversation`).

Roots map to themselves (`conversation_id` = own id, parent = null);
a session without a meta file is treated as a root (fallback: instance
id → conversation id = itself) — backward compatible, nothing breaks
for pre-P39 data.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E


type alias SessionMeta =
    { conversationId : String
    , parentInstanceId : Maybe String
    }


{-| Root metadata: a conversation whose head is this instance.
-}
empty : String -> SessionMeta
empty conversationId =
    { conversationId = conversationId
    , parentInstanceId = Nothing
    }


{-| The session.meta.json path inside a session's own directory
(`sessions/<id>/session.meta.json`).
-}
metaPathFor : String -> String
metaPathFor instanceId =
    instanceId ++ "/session.meta.json"


encode : SessionMeta -> E.Value
encode m =
    E.object
        [ ( "conversation_id", E.string m.conversationId )
        , ( "parent_instance_id"
          , Maybe.withDefault E.null (Maybe.map E.string m.parentInstanceId)
          )
        ]


decode : D.Decoder SessionMeta
decode =
    D.map2 SessionMeta
        (D.field "conversation_id" D.string)
        -- Lenient: pre-lineage files / roots have no parent.
        (D.oneOf [ D.field "parent_instance_id" D.string |> D.map Just, D.succeed Nothing ])


{-| Resolve a PHYSICAL instance id to its CONVERSATION id (stable):
look up the registry (instanceId → SessionMeta) and take its
conversationId; a missing entry (session without a meta file — e.g.
pre-P39 data or an in-flight create) falls back to the instance id
itself, i.e. it IS a root conversation. O(1) per event.
-}
resolveConversation : Dict String SessionMeta -> String -> String
resolveConversation registry instanceId =
    Dict.get instanceId registry
        |> Maybe.map .conversationId
        |> Maybe.withDefault instanceId
