module Icons exposing (paperclip, chip, chevron, check, cross, running, send, mic, bulb, stop)

{-| Hand-drawn SVG icons for the input-bar footer (replacing the old
emoji buttons). All icons share a chunky, short-and-fat, near-square
style: 24×24 viewBox, round caps/joins, `currentColor` strokes so they
inherit the button's color (and hover color) automatically.

- paperclip — attachment (vertical orientation, two loops)
- chip      — model selector (CPU die + pins)

Rendered with elm/svg: the root `Svg.svg` is the HTML-embedding bridge
(returns `Html msg`), inner shapes get the proper SVG namespace.

-}

import Html exposing (Html)
import Html.Attributes as Attr
import Svg exposing (Svg, circle, g, path, rect)
import Svg.Attributes as SAttr


icon : List (Svg.Attribute msg) -> List (Svg msg) -> Html msg
icon gAttrs children =
    Svg.svg
        [ Attr.attribute "viewBox" "0 0 24 24"
        , Attr.attribute "width" "18"
        , Attr.attribute "height" "18"
        ]
        [ g
            ([ SAttr.fill "none"
             , SAttr.stroke "currentColor"
             , SAttr.strokeWidth "2.4"
             , SAttr.strokeLinecap "round"
             , SAttr.strokeLinejoin "round"
             ]
                ++ gAttrs
            )
            children
        ]


{-| Vertical paperclip: one continuous wire — outer loop (left bar, top
arch, right bar), inner loop (bottom arch, inner bars), free wire ends.
-}
paperclip : Html msg
paperclip =
    icon [ SAttr.strokeWidth "2.6" ]
        [ path
            [ SAttr.d "M7.2 20.6 V9.8 a4.8 4.8 0 0 1 9.6 0 v5.4 a2.6 2.6 0 0 1 -5.2 0 V8.2 a1.4 1.4 0 0 1 2.8 0 v7" ]
            []
        ]


{-| CPU chip for the model selector: rounded-square package, inner die,
eight short pins.
-}
chip : Html msg
chip =
    icon []
        [ rect
            [ SAttr.x "6.5"
            , SAttr.y "6.5"
            , SAttr.width "11"
            , SAttr.height "11"
            , SAttr.rx "2.5"
            ]
            []
        , rect
            [ SAttr.x "10"
            , SAttr.y "10"
            , SAttr.width "4"
            , SAttr.height "4"
            , SAttr.rx "1"
            ]
            []
        , path
            [ SAttr.d "M9.5 6.5 v-3 M14.5 6.5 v-3 M9.5 17.5 v3 M14.5 17.5 v3 M6.5 9.5 h-3 M6.5 14.5 h-3 M17.5 9.5 h3 M17.5 14.5 h3" ]
            []
        ]


{-| Right-pointing chevron for the collapsible message windows. Only
shown while the window is collapsed: it sits at the left edge where the
message border used to be (the border is dropped when collapsed), so the
label's x-position matches the expanded state. Expanded windows hide it
entirely and go back to their normal border. Same chunky, short-and-fat
stroke style as the other icons.
-}
chevron : Html msg
chevron =
    icon [ SAttr.strokeWidth "2.8" ]
        [ path
            [ SAttr.d "M9 5.5 L16.5 12 L9 18.5" ]
            []
        ]


{-| Check mark for the tool status (call finished / done). Same chunky
stroke family as the other icons; color comes from the CSS class.
-}
check : Html msg
check =
    icon [ SAttr.strokeWidth "2.8" ]
        [ path
            [ SAttr.d "M5 12.5 L10 17.5 L19 7" ]
            []
        ]


{-| Cross for the tool status (tool call errored). Two chunky strokes.
-}
cross : Html msg
cross =
    icon [ SAttr.strokeWidth "2.8" ]
        [ path
            [ SAttr.d "M7 7 L17 17 M17 7 L7 17" ]
            []
        ]


{-| Spinner arc for the tool status (input streaming / running): a
nearly-full circle with a gap, the standard "in progress" glyph.
-}
running : Html msg
running =
    icon [ SAttr.strokeWidth "2.8" ]
        [ path
            [ SAttr.d "M12 4 a8 8 0 1 1 -8 8" ]
            []
        ]


{-| Paper plane for the send button: body outline plus the fold line.
Chunky strokes, same family as the other icons.
-}
send : Html msg
send =
    icon [ SAttr.strokeWidth "2.6" ]
        [ path
            [ SAttr.d "M22 2 L11 13" ]
            []
        , path
            [ SAttr.d "M22 2 L15 22 L11 13 L2 9 Z" ]
            []
        ]


{-| Microphone for the voice input button (not wired up yet): rounded
capsule, sound cup, stand and base. Same chunky stroke family.
-}
mic : Html msg
mic =
    icon [ SAttr.strokeWidth "2.6" ]
        [ path
            [ SAttr.d "M12 2 a3 3 0 0 1 3 3 v6 a3 3 0 0 1 -6 0 V5 a3 3 0 0 1 3 -3 Z" ]
            []
        , path
            [ SAttr.d "M19 9.5 V11 a7 7 0 0 1 -14 0 V9.5" ]
            []
        , path
            [ SAttr.d "M12 18.5 V22" ]
            []
        , path
            [ SAttr.d "M8.5 22 h7" ]
            []
        ]


{-| Lightbulb for the reasoning-level selector: the classic
"thinking / idea" glyph — bulb, screw base and stand lines.
-}
bulb : Html msg
bulb =
    icon [ SAttr.strokeWidth "2.4" ]
        [ path
            [ SAttr.d "M12 2 a7 7 0 0 0 -4 12.7 c0.6 0.5 1 1.2 1 2 h6 c0 -0.8 0.4 -1.5 1 -2 A7 7 0 0 0 12 2 Z" ]
            []
        , path
            [ SAttr.d "M9 18 h6" ]
            []
        , path
            [ SAttr.d "M10 22 h4" ]
            []
        ]


{-| Stop square for the send button's cancel state (task running):
filled rounded square, the classic media-stop glyph. Red via CSS.
-}
stop : Html msg
stop =
    icon []
        [ rect
            [ SAttr.x "6.5"
            , SAttr.y "6.5"
            , SAttr.width "11"
            , SAttr.height "11"
            , SAttr.rx "2.5"
            , SAttr.fill "currentColor"
            , SAttr.stroke "none"
            ]
            []
        ]
