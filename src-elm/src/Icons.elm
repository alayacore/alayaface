module Icons exposing
    ( paperclip, chip, chevron, check, cross, running, send, mic, bulb, stop, audio
    , back, plus, menu, layers, gear, folder, file, copy, clip, grip, search, circle, warning
    )

{-| Hand-drawn SVG icons for the input-bar footer (replacing the old
emoji buttons) and the unified overlay menus / cards (replacing the
emoji literals sprinkled across overlay pages).

All icons share a chunky, short-and-fat, near-square style: 24×24
viewBox, round caps/joins, `currentColor` strokes so they inherit the
button's color (and hover color) automatically. Two stroke weights:
2.6–2.8 for control icons (close, check, chevron, etc.) and 2.0 for
outline icons (folder, file, copy, grip) — the difference is one tier
of optical weight, not a separate design language.

List:
- paperclip — attachment (vertical orientation, two loops)
- chip      — model selector (CPU die + pins)
- audio     — sound-wave bars (raw audio input)
- chevron   — right-pointing chevron (collapsed message window)
- check     — tool status (call finished / done)
- cross     — close / deny (two chunky strokes; replaces the old ✕ emoji)
- running   — spinner arc (tool status: input streaming / running)
- send      — paper plane (send button)
- mic       — voice input (capsule + sound cup)
- bulb      — reasoning-level selector (lightbulb)
- stop      — filled rounded square (cancel task / stop recording)

Unified overlay icons (Phase 7):
- back      — left chevron, returns to the previous page (replaces "← Back")
- plus      — add a new row (replaces "+ Add")
- menu      — hamburger (replaces ☰)
- layers    — stacked rectangle (replaces ◱ / Preset)
- gear      — settings cog (replaces ⚙)
- folder    — file picker dir entry (replaces 📁)
- file      — file picker file entry (replaces 📄)
- copy      — duplicate (replaces 📋 URL)
- clip      — attach / paperclip alt (replaces 📎)
- grip      — vertical dots, drag handle (replaces ⠿)
- search    — magnifying glass (replaces 🔍)
- circle    — filled dot, "active" marker (replaces ●)
- warning   — triangle + exclamation (replaces ⏳ / ⚠)

Rendered with elm/svg: the root `Svg.svg` is the HTML-embedding bridge
(returns `Html msg`), inner shapes get the proper SVG namespace.
-}

import Html exposing (Html)
import Html.Attributes as Attr
import Svg as SvgNS
import Svg exposing (Svg, g, path, polyline, rect)
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


iconSm : List (Svg.Attribute msg) -> List (Svg msg) -> Html msg
iconSm gAttrs children =
    Svg.svg
        [ Attr.attribute "viewBox" "0 0 24 24"
        , Attr.attribute "width" "16"
        , Attr.attribute "height" "16"
        ]
        [ g
            ([ SAttr.fill "none"
             , SAttr.stroke "currentColor"
             , SAttr.strokeWidth "2.0"
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


{-| Cross for the tool status (tool call errored) and the unified
close-X on every overlay card. Two chunky strokes; hover color comes
from the parent button's CSS.
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


{-| Audio: five sound-wave bars of increasing/decreasing height — the
raw audio input button (record the mic and send the WAV as a UA frame).
-}
audio : Html msg
audio =
    icon []
        [ path [ SAttr.d "M4 10 v4" ] []
        , path [ SAttr.d "M8 6.5 v11" ] []
        , path [ SAttr.d "M12 3.5 v17" ] []
        , path [ SAttr.d "M16 6.5 v11" ] []
        , path [ SAttr.d "M20 10 v4" ] []
        ]



-- ─── Unified overlay icons (Phase 7) ─────────────────────────────────


{-| Back arrow — replaces the literal "← Back" buttons on the model
editor / MCP editor / settings / global config / ASR config pages. Same
chunky stroke style; renders at 16×16 (iconSm) so it sits well inside
the small me-back-btn footprint.
-}
back : Html msg
back =
    iconSm [ SAttr.strokeWidth "2.4" ]
        [ polyline [ SAttr.points "14 6 8 12 14 18" ] []
        ]


{-| Plus sign — replaces "+ Add" / "+" buttons. Centered plus.
-}
plus : Html msg
plus =
    icon [ SAttr.strokeWidth "2.6" ]
        [ path [ SAttr.d "M12 5 V19 M5 12 H19" ] []
        ]


{-| Hamburger menu — replaces ☰ in the global menu's "Session Manager"
row. Three short horizontal bars, slight optical spacing at the right.
-}
menu : Html msg
menu =
    icon [ SAttr.strokeWidth "2.6" ]
        [ path [ SAttr.d "M4 7 H18" ] []
        , path [ SAttr.d "M4 12 H18" ] []
        , path [ SAttr.d "M4 17 H12" ] []
        ]


{-| Stacked layers — replaces ◱ in the global menu's "Preset Manager"
row. Three offset rounded rectangles suggesting depth.
-}
layers : Html msg
layers =
    icon [ SAttr.strokeWidth "2.2" ]
        [ path
            [ SAttr.d "M12 3 L21 8 L12 13 L3 8 Z" ]
            []
        , path
            [ SAttr.d "M3 12 L12 17 L21 12" ]
            []
        , path
            [ SAttr.d "M3 16 L12 21 L21 16" ]
            []
        ]


{-| Gear / cog — replaces ⚙ in the global menu's "Global config" row.
Outer toothed ring with an inner circle.
-}
gear : Html msg
gear =
    icon [ SAttr.strokeWidth "2.2" ]
        [ SvgNS.circle
            [ SAttr.cx "12"
            , SAttr.cy "12"
            , SAttr.r "3"
            ]
            []
        , path
            [ SAttr.d
                (String.concat
                    [ "M12 2.5 V5"
                    , " M12 19 V21.5"
                    , " M2.5 12 H5"
                    , " M19 12 H21.5"
                    , " M5.6 5.6 L7.3 7.3"
                    , " M16.7 16.7 L18.4 18.4"
                    , " M5.6 18.4 L7.3 16.7"
                    , " M16.7 7.3 L18.4 5.6"
                    ]
                )
            ]
            []
        ]


{-| Folder — replaces 📁 in the file picker. Tab on top + body, rounded
right corners on the body.
-}
folder : Html msg
folder =
    iconSm []
        [ path
            [ SAttr.d "M3 7 a1 1 0 0 1 1 -1 h5 l2 2 h8 a1 1 0 0 1 1 1 v9 a1 1 0 0 1 -1 1 H4 a1 1 0 0 1 -1 -1 Z" ]
            []
        ]


{-| Document with folded corner — replaces 📄 in the file picker.
-}
file : Html msg
file =
    iconSm []
        [ path
            [ SAttr.d "M6 3 H14 L19 8 V20 a1 1 0 0 1 -1 1 H6 a1 1 0 0 1 -1 -1 V4 a1 1 0 0 1 1 -1 Z" ]
            []
        , path
            [ SAttr.d "M14 3 V8 H19" ]
            []
        ]


{-| Two overlapping document outlines — copy / duplicate gesture
(replaces 📋 URL in MCP init).
-}
copy : Html msg
copy =
    iconSm []
        [ rect
            [ SAttr.x "8"
            , SAttr.y "8"
            , SAttr.width "12"
            , SAttr.height "12"
            , SAttr.rx "1.5"
            ]
            []
        , path
            [ SAttr.d "M16 8 V5 a1 1 0 0 0 -1 -1 H5 a1 1 0 0 0 -1 1 V17 a1 1 0 0 0 1 1 H8" ]
            []
        ]


{-| Paperclip — replaces 📎 in MCP init button labels and other copy
gestures. Same chunky wire as the paperclip in the input bar.
-}
clip : Html msg
clip =
    icon [ SAttr.strokeWidth "2.4" ]
        [ path
            [ SAttr.d "M16.5 7.5 L9 15 a3.5 3.5 0 0 0 5 5 L20.5 13.5 a5.5 5.5 0 0 0 -8 -8 L6 11.5 a2.5 2.5 0 0 0 3.5 3.5 L16 8.5" ]
            []
        ]


{-| Vertical drag handle — six dots in two columns. Replaces ⠿ in the
preset manager's drag handle.
-}
grip : Html msg
grip =
    iconSm []
        [ SvgNS.circle [ SAttr.cx "9", SAttr.cy "6", SAttr.r "1.2", SAttr.fill "currentColor", SAttr.stroke "none" ] []
        , SvgNS.circle [ SAttr.cx "9", SAttr.cy "12", SAttr.r "1.2", SAttr.fill "currentColor", SAttr.stroke "none" ] []
        , SvgNS.circle [ SAttr.cx "9", SAttr.cy "18", SAttr.r "1.2", SAttr.fill "currentColor", SAttr.stroke "none" ] []
        , SvgNS.circle [ SAttr.cx "15", SAttr.cy "6", SAttr.r "1.2", SAttr.fill "currentColor", SAttr.stroke "none" ] []
        , SvgNS.circle [ SAttr.cx "15", SAttr.cy "12", SAttr.r "1.2", SAttr.fill "currentColor", SAttr.stroke "none" ] []
        , SvgNS.circle [ SAttr.cx "15", SAttr.cy "18", SAttr.r "1.2", SAttr.fill "currentColor", SAttr.stroke "none" ] []
        ]


{-| Magnifying glass — replaces 🔍 in the global menu's zoom row.
-}
search : Html msg
search =
    icon [ SAttr.strokeWidth "2.4" ]
        [ SvgNS.circle [ SAttr.cx "10.5", SAttr.cy "10.5", SAttr.r "6" ] []
        , path [ SAttr.d "M15 15 L20 20" ] []
        ]


{-| Filled dot — replaces ● in the selector's active marker. Solid
disc, slightly larger than the surrounding text baseline.
-}
circle : Html msg
circle =
    icon [ SAttr.fill "currentColor", SAttr.stroke "none" ]
        [ SvgNS.circle [ SAttr.cx "12", SAttr.cy "12", SAttr.r "4.5" ] []
        ]


{-| Warning triangle with exclamation — replaces ⚠ / ⏳ in status rows
and tooltips.
-}
warning : Html msg
warning =
    icon [ SAttr.strokeWidth "2.2" ]
        [ path
            [ SAttr.d "M12 3 L22 20 H2 Z" ]
            []
        , path
            [ SAttr.d "M12 10 V14" ]
            []
        , path
            [ SAttr.d "M12 17 V17.5" ]
            []
        ]