module Plan.Layout exposing
    ( NodeLayout
    , EdgeLayout
    , Segment
    , layout
    , dagWidth
    , dagHeight
    , nodeW
    , nodeH
    )

{-| Pure DAG layout for the Plan view: longest-path layering → columns,
nodes stacked per layer, orthogonal edge routing. No SVG dependency —
the view renders absolutely-positioned divs from the geometry here.

Geometry conventions (top-left origin):
  - node: x = layer * (nodeW + colGap), y = row * (nodeH + rowGap)
  - edge: from source bottom-center to target top-center, routed as
    vertical → horizontal → vertical segments.
-}

import Dict exposing (Dict)
import Plan.Types as PT


-- Sizing (px). Kept here so View and tests share one source of truth.


nodeW : Float
nodeW =
    180


nodeH : Float
nodeH =
    64


colGap : Float
colGap =
    90


rowGap : Float
rowGap =
    30


type alias NodeLayout =
    { id : String
    , x : Float
    , y : Float
    , layer : Int
    , row : Int
    }


type alias Segment =
    { x : Float
    , y : Float
    , w : Float
    , h : Float
    }


type alias EdgeLayout =
    { from : String
    , to : String
    , v1 : Segment
    , h : Segment
    , v2 : Segment
    }


{-| Layout a validated plan (no cycles) into node positions + edges.
Node order within a layer preserves the input order (stable).
-}
layout : PT.Plan -> ( List NodeLayout, List EdgeLayout )
layout plan =
    let
        byId =
            List.foldl (\t acc -> Dict.insert t.id t acc) Dict.empty plan.tasks

        layerOf =
            computeLayers byId

        -- group task ids by layer, preserving input order
        rowsByLayer : Dict Int (List String)
        rowsByLayer =
            List.foldl
                (\t acc ->
                    let
                        l =
                            Maybe.withDefault 0 (Dict.get t.id layerOf)
                    in
                    Dict.update l (\maybeIds -> Just (Maybe.withDefault [] maybeIds ++ [ t.id ])) acc
                )
                Dict.empty
                plan.tasks

        nodes =
            Dict.toList rowsByLayer
                |> List.sortBy Tuple.first
                |> List.foldl
                    (\( layer, ids ) acc ->
                        acc
                            ++ List.indexedMap
                                (\row id ->
                                    { id = id
                                    , x = toFloat layer * (nodeW + colGap)
                                    , y = toFloat row * (nodeH + rowGap)
                                    , layer = layer
                                    , row = row
                                    }
                                )
                                ids
                    )
                    []

        posById =
            List.foldl (\n acc -> Dict.insert n.id n acc) Dict.empty nodes

        edges =
            List.concatMap (edgesFor byId posById) plan.tasks
    in
    ( nodes, edges )


edgesFor : Dict String PT.TaskNode -> Dict String NodeLayout -> PT.TaskNode -> List EdgeLayout
edgesFor byId posById t =
    List.filterMap
        (\dep ->
            case ( Dict.get dep posById, Dict.get t.id posById ) of
                ( Just from, Just to ) ->
                    Just (edgeBetween from to)

                _ ->
                    Nothing
        )
        t.dependsOn


edgeBetween : NodeLayout -> NodeLayout -> EdgeLayout
edgeBetween from to =
    let
        fx =
            from.x + nodeW / 2

        fy =
            from.y + nodeH

        tx =
            to.x + nodeW / 2

        ty =
            to.y

        sameRow =
            abs (from.y - to.y) < 0.5

        midY =
            max fy ty
    in
    if sameRow then
        -- Same row: connect source RIGHT side to target LEFT side with a
        -- single horizontal segment at the vertical middle.
        let
            yMid =
                from.y + nodeH / 2

            fxr =
                from.x + nodeW

            txl =
                to.x
        in
        { from = from.id
        , to = to.id
        , v1 = { x = fxr, y = yMid, w = 1, h = 0 }
        , h = { x = min fxr txl, y = yMid, w = abs (txl - fxr), h = 1 }
        , v2 = { x = txl, y = yMid, w = 1, h = 0 }
        }

    else
        { from = from.id
        , to = to.id
        , v1 = { x = fx, y = fy, w = 1, h = max 0 (midY - fy) }
        , h = { x = min fx tx, y = midY, w = abs (tx - fx), h = 1 }
        , v2 = { x = tx, y = min midY ty, w = 1, h = max 0 (abs (midY - ty)) }
        }


{-| Longest-path layering: layer(v) = 1 + max layer(deps). Converges in
at most n-1 iterations for a DAG (n iterations is safe either way).
-}
computeLayers : Dict String PT.TaskNode -> Dict String Int
computeLayers byId =
    let
        step dict =
            Dict.foldl
                (\_ t acc ->
                    let
                        base =
                            Maybe.withDefault 0 (Dict.get t.id acc)

                        maxDep =
                            List.foldl
                                (\d m -> max m (Maybe.withDefault 0 (Dict.get d acc) + 1))
                                0
                                t.dependsOn
                    in
                    Dict.insert t.id (max base maxDep) acc
                )
                dict
                byId

        n =
            Dict.size byId

        zero =
            Dict.map (\_ _ -> 0) byId
    in
    List.foldl (\_ acc -> step acc) zero (List.range 1 (max 1 n))


dagWidth : List NodeLayout -> Float
dagWidth nodes =
    case List.maximum (List.map (\n -> n.x + nodeW) nodes) of
        Just w ->
            w

        Nothing ->
            0


dagHeight : List NodeLayout -> Float
dagHeight nodes =
    case List.maximum (List.map (\n -> n.y + nodeH) nodes) of
        Just h ->
            h

        Nothing ->
            0
