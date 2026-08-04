module Overlay.MediaPreview exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Json.Decode as D
import Session.Types as T


-- Media preview overlay. Clicking a multimodal chip (staged or in a
-- message) opens this. Images are shown fit-to-viewport, video/audio get
-- native player controls, and documents show a "not supported" notice.
-- Clicking the backdrop or the close button dismisses; clicks on the
-- media itself do not close.

view :
    { item : T.MediaItem
    , onClose : msg
    , noOp : msg
    }
    -> Html msg
view config =
    Html.div
        [ Attr.class "media-preview-overlay"
        , Ev.onClick config.onClose
        ]
        [ Html.div
            [ Attr.class "media-preview-stage"
            , Ev.stopPropagationOn "click" (D.succeed ( config.noOp, True ))
            ]
            [ Html.button
                [ Attr.class "media-preview-close"
                , Ev.stopPropagationOn "click" (D.succeed ( config.onClose, True ))
                , Attr.title "Close"
                ]
                [ Html.text "✕" ]
            , content config.item
            ]
        ]


content : T.MediaItem -> Html msg
content item =
    case item.mediaType of
        T.Image ->
            Html.img
                [ Attr.class "media-preview-img"
                , Attr.src item.uri
                , Attr.alt (Maybe.withDefault "" item.name)
                ]
                []

        T.Video ->
            Html.video
                [ Attr.class "media-preview-video"
                , Attr.src item.uri
                , Attr.controls True
                ]
                []

        T.Audio ->
            Html.audio
                [ Attr.class "media-preview-audio"
                , Attr.src item.uri
                , Attr.controls True
                ]
                []

        T.Document ->
            Html.div [ Attr.class "media-preview-unsupported" ]
                [ Html.div [ Attr.class "media-preview-unsupported-icon" ]
                    [ Html.text "📄" ]
                , Html.div [ Attr.class "media-preview-unsupported-text" ]
                    [ Html.text "Preview not supported yet" ]
                , Html.div [ Attr.class "media-preview-unsupported-name" ]
                    [ Html.text (Maybe.withDefault "" item.name) ]
                ]
