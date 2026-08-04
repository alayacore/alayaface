module Session.Protocol exposing
    ( Tag(..)
    , tagToString
    , tagFromString
    , isUserEchoTag
    , DeltaEvent
    , FrameEvent
    , StatusEvent
    , deltaEventDecoder
    , frameEventDecoder
    , statusEventDecoder
    , parseDelta
    , wrapDelta
    , SystemMsgEnvelope
    , systemMsgDecoder
    )

import Json.Decode as D
import Json.Encode as E


-- Tags

type Tag
    = UserText
    | UserImage
    | UserVideo
    | UserAudio
    | UserDoc
    | UserEnd
    | AssistantText
    | AssistantReasoning
    | AssistantTool
    | UserToolResult
    | SystemMsg
    | CommandIn
    | CommandOut
    | AssistantTextDelta
    | AssistantReasoningDelta
    | ToolArgDelta
    | ToolResultPreview
    | UnknownTag String


tagToString : Tag -> String
tagToString t =
    case t of
        UserText -> "UT"
        UserImage -> "UI"
        UserVideo -> "UV"
        UserAudio -> "UA"
        UserDoc -> "UD"
        UserEnd -> "UE"
        AssistantText -> "AT"
        AssistantReasoning -> "AR"
        AssistantTool -> "AF"
        UserToolResult -> "UF"
        SystemMsg -> "SM"
        CommandIn -> "CI"
        CommandOut -> "CO"
        AssistantTextDelta -> "At"
        AssistantReasoningDelta -> "Ar"
        ToolArgDelta -> "Af"
        ToolResultPreview -> "Uf"
        UnknownTag s -> s


tagFromString : String -> Tag
tagFromString s =
    case s of
        "UT" -> UserText
        "UI" -> UserImage
        "UV" -> UserVideo
        "UA" -> UserAudio
        "UD" -> UserDoc
        "UE" -> UserEnd
        "AT" -> AssistantText
        "AR" -> AssistantReasoning
        "AF" -> AssistantTool
        "UF" -> UserToolResult
        "SM" -> SystemMsg
        "CI" -> CommandIn
        "CO" -> CommandOut
        "At" -> AssistantTextDelta
        "Ar" -> AssistantReasoningDelta
        "Af" -> ToolArgDelta
        "Uf" -> ToolResultPreview
        _ -> UnknownTag s


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


-- Delta parsing

parseDelta : String -> Maybe ( String, String )
parseDelta value =
    if String.length value == 0 || Char.toCode (String.left 1 value |> String.uncons |> Maybe.map Tuple.first |> Maybe.withDefault '\u{0000}') /= 0 then
        Nothing

    else
        case String.indexes "\u{0000}" value of
            first :: second :: _ ->
                let
                    id =
                        String.slice first (second + 1) value |> String.dropLeft 1 |> String.dropRight 1

                    content =
                        String.dropLeft (second + 1) value
                in
                if String.isEmpty id then
                    Nothing

                else
                    Just ( id, content )

            _ ->
                Nothing


wrapDelta : String -> String -> String
wrapDelta id content =
    "\u{0000}" ++ id ++ "\u{0000}" ++ content


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
