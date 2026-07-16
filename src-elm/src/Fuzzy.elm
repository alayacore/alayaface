module Fuzzy exposing (fuzzyMatch, fuzzyScore)

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


fuzzyScore : String -> String -> Int
fuzzyScore search target =
    if String.isEmpty search then
        100

    else if String.length search > String.length target then
        0

    else
        let
            searchChars =
                String.toList search

            targetChars =
                String.toList target
        in
        let
            ( scoreVal, _, _ ) =
                fuzzyScoreHelp searchChars targetChars 0 0
        in
        scoreVal


fuzzyScoreHelp : List Char -> List Char -> Int -> Int -> ( Int, List Char, List Char )
fuzzyScoreHelp search target score consecutive =
    case search of
        [] ->
            ( score, [], target )

        s :: restSearch ->
            case target of
                [] ->
                    ( 0, search, [] )

                t :: restTarget ->
                    if s == t then
                        let
                            newConsecutive =
                                consecutive + 1

                            bonus =
                                if newConsecutive > 1 then
                                    10 * newConsecutive
                                else
                                    1
                        in
                        fuzzyScoreHelp restSearch restTarget (score + bonus) newConsecutive

                    else
                        fuzzyScoreHelp search restTarget score 0
