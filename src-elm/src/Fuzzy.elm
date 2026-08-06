module Fuzzy exposing (fuzzyMatch)

{-| Fuzzy string matching ported from alayacore's terminal adapter.
Checks if all characters in the search term appear in order
(but not necessarily consecutively) in the target string.
-}


fuzzyMatch : String -> String -> Bool
fuzzyMatch search target =
    if String.isEmpty search then
        True

    else if String.length search > String.length target then
        False

    else
        let
            searchChars =
                String.toList search

            targetChars =
                String.toList target
        in
        fuzzyMatchHelp searchChars targetChars


fuzzyMatchHelp : List Char -> List Char -> Bool
fuzzyMatchHelp search target =
    case search of
        [] ->
            True

        s :: restSearch ->
            case target of
                [] ->
                    False

                t :: restTarget ->
                    if s == t then
                        fuzzyMatchHelp restSearch restTarget

                    else
                        fuzzyMatchHelp search restTarget

