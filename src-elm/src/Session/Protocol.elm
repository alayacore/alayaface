module Session.Protocol exposing
    ( isUserEchoTag
    , historyKeyOf
    , DeltaEvent
    , FrameEvent
    , StatusEvent
    , deltaEventDecoder
    , frameEventDecoder
    , statusEventDecoder
    , SystemMsgEnvelope
    , systemMsgDecoder
    )

import Json.Decode as D


-- User echo tag (UX appears on stdout as the echo of user content).
--
-- v14 collapsed the old per-kind tags (UT/UI/UV/UA/UD) into the single
-- content plane UX; the concrete kind now travels in the JSON "type" and
-- arrives as the event's content_type.

userEchoTags : List String
userEchoTags =
    [ "UX" ]


isUserEchoTag : String -> Bool
isUserEchoTag s =
    List.member s userEchoTags


{-| The key a content block is accumulated under: its kind plus its history
id. Shared by the delta handler, the complete-frame handler and the plan
counter so the three cannot drift.

The kind (not the tag) is part of the key because AX/Ax carry both assistant
text and assistant reasoning under one tag: the same history id can name a
text block and a reasoning block, and keying on the tag alone would merge
them.
-}
historyKeyOf : String -> String -> String
historyKeyOf contentType historyId =
    contentType ++ ":" ++ historyId


-- Delta Frame (Ax)
--
-- contentType is the content item's kind: "text" or "reasoning".

type alias DeltaEvent =
    { sessionId : String
    , historyId : String
    , content : String
    , tag : String
    , contentType : String
    }


deltaEventDecoder : D.Decoder DeltaEvent
deltaEventDecoder =
    D.map5 DeltaEvent
        (D.field "session_id" D.string)
        (D.field "history_id" D.string)
        (D.field "content" D.string)
        (D.field "tag" D.string)
        (D.field "content_type" D.string)


-- Frame Event (all complete frames)

type alias FrameEvent =
    { sessionId : String
    , tag : String
    , rawValue : String
    , historyId : Maybe String
    , content : Maybe String
    , json : Maybe D.Value
    , contentType : Maybe String
    }


frameEventDecoder : D.Decoder FrameEvent
frameEventDecoder =
    D.map7 FrameEvent
        (D.field "session_id" D.string)
        (D.field "tag" D.string)
        (D.field "raw_value" D.string)
        (D.field "history_id" (D.nullable D.string))
        (D.field "content" (D.nullable D.string))
        (D.field "json" (D.nullable D.value))
        (D.field "content_type" (D.nullable D.string))


-- Status Event

type alias StatusEvent =
    { sessionId : String
    , connected : Bool
    , message : String
    }


statusEventDecoder : D.Decoder StatusEvent
statusEventDecoder =
    D.map3 StatusEvent
        (D.field "session_id" D.string)
        (D.field "connected" D.bool)
        (D.field "message" D.string)


-- Content and function frames carry their JSON object directly (the reader
-- parses it and forwards it as `json`), so there is no client-side prefix
-- parsing.

-- System message

type alias SystemMsgEnvelope =
    { msgType : String
    , data : D.Value
    }


systemMsgDecoder : D.Decoder SystemMsgEnvelope
systemMsgDecoder =
    D.map2 SystemMsgEnvelope
        (D.field "type" D.string)
        (D.field "data" D.value)
