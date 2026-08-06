module Plan.Frames exposing (taskEvent)

{-| Decide what an SM "task" frame from a node-owned session means to the
runner (R5 boot-frame gate).

alayacore emits a boot task frame (`in_progress:false`, context 0) at
session start, BEFORE any prompt is processed. Without tracking task
starts it is indistinguishable from a real task completion — the runner
would mark the just-bound node Succeeded (empty output) and closeAndClear
would CANCEL its just-started session ("Canceled" right after the first
prompt, node done in milliseconds). A real task always starts with
`in_progress:true` (after the prompt, which is only sent once the session
is bound), so:

    taskEvent started sid inProgress taskError
    --> ( updatedStarted, Maybe ( sid, taskError ) )

  - `in_progress:true`  → remember the session (real task start), no event.
  - `in_progress:false` → TaskDone only if that session had started; the
    boot frame (never started) is ignored.
-}

import Set exposing (Set)


taskEvent : Set String -> String -> Bool -> Bool -> ( Set String, Maybe ( String, Bool ) )
taskEvent started sid inProgress taskError =
    if inProgress then
        ( Set.insert sid started, Nothing )

    else if Set.member sid started then
        ( started, Just ( sid, taskError ) )

    else
        ( started, Nothing )
