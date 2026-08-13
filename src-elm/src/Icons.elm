module Icons exposing (paperclip, chip, help)

{-| Hand-drawn SVG icons for the input-bar footer (replacing the old
emoji buttons). All icons share a chunky, short-and-fat, near-square
style: 24×24 viewBox, round caps/joins, `currentColor` strokes so they
inherit the button's color (and hover color) automatically.

- paperclip — attachment (vertical orientation, two loops)
- chip      — model selector (CPU die + pins)
- help      — question mark inside a rounded square

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


{-| Help: chunky question mark in a rounded square. The dot is filled
with the current color (other shapes are strokes).
-}
help : Html msg
help =
    icon []
        [ rect
            [ SAttr.x "3.5"
            , SAttr.y "3.5"
            , SAttr.width "17"
            , SAttr.height "17"
            , SAttr.rx "4"
            ]
            []
        , path
            [ SAttr.d "M9.5 9.5 a2.5 2.5 0 0 1 5 0 c0 1.7 -2.5 2.2 -2.5 3.8" ]
            []
        , circle
            [ SAttr.cx "12"
            , SAttr.cy "16.6"
            , SAttr.r "1.2"
            , SAttr.fill "currentColor"
            , SAttr.stroke "none"
            ]
            []
        ]
