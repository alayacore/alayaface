module Session.Protocol exposing
    ( isUserEchoTag
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


-- User echo tags (UT/UI/UV/UA/UD appear on stdout as echoes)

userEchoTags : List String
userEchoTags =
    [ "UT", "UI", "UV", "UA", "UD" ]


isUserEchoTag : String -> Bool
isUserEchoTag s =
    List.member s userEchoTags


-- Delta Frame (At/Ar)

type alias DeltaEvent =
    { sessionId : String
    , historyId : String
    , content : String
    , tag : String
    }


deltaEventDecoder : D.Decoder DeltaEvent
deltaEventDecoder =
    D.map4 DeltaEvent
        (D.field "session_id" D.string)
        (D.field "history_id" D.string)
        (D.field "content" D.string)
        (D.field "tag" D.string)


-- Frame Event (all complete frames)

type alias FrameEvent =
    { sessionId : String
    , tag : String
    , rawValue : String
    , historyId : Maybe String
    , content : Maybe String
    , json : Maybe D.Value
    , userContentType : Maybe String
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
        (D.field "user_content_type" (D.nullable D.string))


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


-- Delta parsing (Rust side unwraps the NUL-delimited history-ID prefix
-- and forwards `history_id` + `content` separately in DeltaEvent and
-- FrameEvent; no client-side delta parsing is needed.)

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
