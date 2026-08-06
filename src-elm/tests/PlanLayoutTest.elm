module PlanLayoutTest exposing (tests)

import Expect
import Test exposing (Test, describe, test)
import Dict exposing (Dict)
import Plan.Layout as L
import Plan.Types as P


planFromJson : String -> P.Plan
planFromJson json =
    case P.parsePlan json of
        Ok p ->
            p

        Err errs ->
            Debug.todo ("bad test plan: " ++ String.join "; " errs)


tests : Test
tests =
    describe "Plan.Layout"
        [ describe "layering"
            [ test "chain layers are increasing" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "C", "prompt": "c", "depends_on": ["b"] }
                            ] }"""

                        ( nodes, _ ) =
                            L.layout plan

                        byId =
                            Dict.fromList (List.map (\n -> ( n.id, n.layer )) nodes)
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just 0) (Dict.get "a" byId)
                        , \_ -> Expect.equal (Just 1) (Dict.get "b" byId)
                        , \_ -> Expect.equal (Just 2) (Dict.get "c" byId)
                        ]
                        ()
            , test "diamond: b and c share layer 1" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "C", "prompt": "c", "depends_on": ["a"] },
                              { "id": "d", "title": "D", "prompt": "d", "depends_on": ["b", "c"] }
                            ] }"""

                        ( nodes, _ ) =
                            L.layout plan

                        byId =
                            Dict.fromList (List.map (\n -> ( n.id, n.layer )) nodes)
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Just 0) (Dict.get "a" byId)
                        , \_ -> Expect.equal (Just 1) (Dict.get "b" byId)
                        , \_ -> Expect.equal (Just 1) (Dict.get "c" byId)
                        , \_ -> Expect.equal (Just 2) (Dict.get "d" byId)
                        ]
                        ()
            , test "parallel independent tasks all at layer 0" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b" },
                              { "id": "c", "title": "C", "prompt": "c" }
                            ] }"""

                        ( nodes, _ ) =
                            L.layout plan

                        layers =
                            List.map .layer nodes
                    in
                    Expect.equal [ 0, 0, 0 ] layers
            ]
        , describe "geometry"
            [ test "nodes are placed in columns by layer with stable rows" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "C", "prompt": "c", "depends_on": ["a"] }
                            ] }"""

                        ( nodes, _ ) =
                            L.layout plan

                        a =
                            nodes |> List.filter (\n -> n.id == "a") |> List.head
                        b =
                            nodes |> List.filter (\n -> n.id == "b") |> List.head
                        c =
                            nodes |> List.filter (\n -> n.id == "c") |> List.head
                    in
                    case ( a, b, c ) of
                        ( Just na, Just nb, Just nc ) ->
                            Expect.all
                                [ \_ -> Expect.equal nb.x nc.x |> Expect.onFail "b and c same column (layer 1)"
                                , \_ -> Expect.equal nb.y (nc.y - (L.nodeH + 30)) |> Expect.onFail "b above c (row order)"
                                , \_ -> Expect.equal True (na.x < nb.x) |> Expect.onFail "a left of b"
                                ]
                                ()

                        _ ->
                            Expect.fail "missing nodes"
            , test "same-row edge connects source right to target left" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] }
                            ] }"""

                        ( nodes, edges ) =
                            L.layout plan

                        a =
                            nodes |> List.filter (\n -> n.id == "a") |> List.head
                        b =
                            nodes |> List.filter (\n -> n.id == "b") |> List.head
                    in
                    case ( a, b, List.head edges ) of
                        ( Just na, Just nb, Just e ) ->
                            Expect.all
                                [ \_ -> Expect.equal "a" e.from
                                , \_ -> Expect.equal "b" e.to
                                , \_ -> Expect.equal (na.x + L.nodeW) e.v1.x |> Expect.onFail "v1 starts at source right edge"
                                , \_ -> Expect.equal (na.y + L.nodeH / 2) e.h.y |> Expect.onFail "h at vertical middle"
                                , \_ -> Expect.equal nb.x e.v2.x |> Expect.onFail "v2 ends at target left edge"
                                , \_ -> Expect.equal (nb.y + L.nodeH / 2) (e.v2.y + e.v2.h) |> Expect.onFail "v2 at target middle height"
                                ]
                                ()

                        _ ->
                            Expect.fail "missing nodes/edges"
            , test "different-row edge routes bottom→top orthogonally" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "C", "prompt": "c", "depends_on": ["a"] },
                              { "id": "d", "title": "D", "prompt": "d", "depends_on": ["b"] }
                            ] }"""

                        ( nodes, edges ) =
                            L.layout plan

                        a =
                            nodes |> List.filter (\n -> n.id == "a") |> List.head
                        c =
                            nodes |> List.filter (\n -> n.id == "c") |> List.head
                        -- a is layer 0 row 0; c is layer 1 row 1 (lower than
                        -- a's bottom edge) → different-row orthogonal route.
                        aToC =
                            edges |> List.filter (\e -> e.from == "a" && e.to == "c") |> List.head
                    in
                    case ( a, c, aToC ) of
                        ( Just na, Just nc, Just e ) ->
                            let
                                midY =
                                    max (na.y + L.nodeH) nc.y
                            in
                            Expect.all
                                [ \_ -> Expect.equal (na.x + L.nodeW / 2) e.v1.x |> Expect.onFail "v1 at source center-x"
                                , \_ -> Expect.equal (na.y + L.nodeH) e.v1.y |> Expect.onFail "v1 starts at source bottom"
                                , \_ -> Expect.equal midY (e.v1.y + e.v1.h) |> Expect.onFail "v1 reaches midY"
                                , \_ -> Expect.equal midY e.h.y |> Expect.onFail "h at midY"
                                , \_ -> Expect.equal (nc.x + L.nodeW / 2) e.v2.x |> Expect.onFail "v2 at target center-x"
                                , \_ -> Expect.equal nc.y (e.v2.y + e.v2.h) |> Expect.onFail "v2 ends at target top"
                                ]
                                ()

                        _ ->
                            Expect.fail "missing edge a→c"
            , test "no negative geometry for reverse-height edge" <|
                \_ ->
                    -- target sits HIGHER than source bottom; segments must
                    -- still have non-negative w/h.
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "C", "prompt": "c", "depends_on": ["a"] },
                              { "id": "d", "title": "D", "prompt": "d", "depends_on": ["b", "c"] },
                              { "id": "e", "title": "E", "prompt": "e", "depends_on": ["d"] }
                            ] }"""

                        ( _, edges ) =
                            L.layout plan

                        nonNegative seg =
                            seg.w >= 0 && seg.h >= 0

                        allNonNeg =
                            List.all (\e -> nonNegative e.v1 && nonNegative e.h && nonNegative e.v2) edges
                    in
                    Expect.equal True allNonNeg
            , test "dagWidth/dagHeight cover all nodes" <|
                \_ ->
                    let
                        plan =
                            planFromJson """{ "name": "x", "tasks": [
                              { "id": "a", "title": "A", "prompt": "a" },
                              { "id": "b", "title": "B", "prompt": "b", "depends_on": ["a"] },
                              { "id": "c", "title": "C", "prompt": "c", "depends_on": ["a"] },
                              { "id": "d", "title": "D", "prompt": "d", "depends_on": ["b", "c"] }
                            ] }"""

                        ( nodes, _ ) =
                            L.layout plan

                        w =
                            L.dagWidth nodes

                        h =
                            L.dagHeight nodes
                    in
                    Expect.all
                        [ \_ -> Expect.equal True (List.all (\n -> n.x < w) nodes)
                        , \_ -> Expect.equal True (List.all (\n -> n.y < h) nodes)
                        ]
                        ()
            ]
        ]
