module Overlay.ConfirmTool exposing (view)

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Ev
import Session.Types as T


view :
    { onConfirm : String -> Bool -> msg
    }
    -> T.PendingConfirm
    -> Html msg
view config p =
    Html.div [ Attr.class "confirm-page" ]
        [ Html.div [ Attr.class "confirm-page-title" ]
            [ Html.text ("Allow \"" ++ Maybe.withDefault "Tool" p.toolName ++ "\" to run?") ]
        , case p.toolInput of
            Just input ->
                Html.div [ Attr.class "confirm-page-input" ]
                    [ Html.text input ]

            Nothing ->
                Html.text ""
        , Html.div [ Attr.class "confirm-page-buttons" ]
            [ Html.button
                [ Attr.class "btn btn-success btn-lg"
                , Ev.onClick (config.onConfirm p.id True)
                ]
                [ Html.text "✓ Allow" ]
            , Html.button
                [ Attr.class "btn btn-danger btn-lg"
                , Ev.onClick (config.onConfirm p.id False)
                ]
                [ Html.text "✕ Deny" ]
            ]
        ]
