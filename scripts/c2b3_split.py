#!/usr/bin/env python3
"""C2b-3 refactor v2: SessionCreated keeps a short if-else dispatch;
helpers + createSessionWindow (dedented original body) are inserted
BEFORE `update msg model =` (top-level definitions cannot sit between
case branches)."""
import re

path = "src-elm/src/App/Update.elm"
src = open(path, encoding="utf-8").read()
lines = src.split("\n")

# locate the SessionCreated case
start = None
for idx, ln in enumerate(lines):
    if ln == "        SessionCreated id ->":
        start = idx
        break
assert start is not None, "SessionCreated case not found"
assert lines[start + 1] == "            let", "expected let after SessionCreated: " + repr(lines[start + 1])

# find the next case (SessionCreateError)
end = None
for idx in range(start + 1, len(lines)):
    if lines[idx] == "        SessionCreateError text ->":
        end = idx
        break
assert end is not None, "SessionCreateError not found"

body = lines[start + 1:end]
while body and body[-1] == "":
    body.pop()
assert body[-1] == "            )", "body does not end with tuple close: " + repr(body[-1])

def dedent8(ln):
    if ln.startswith("            "):
        return ln[8:]
    if ln.startswith("        "):
        return ln[8:]
    return ln

dedented = [dedent8(ln) for ln in body]

helpers = '''{-| C2b: is the in-flight cascade fork a top-level (plain) fork?
Top-level re-run forks go through work-copy replacement
(forkSessionCreated); node forks keep the old behavior (new window +
lineage, unified in C3).
-}
isPlainCascadeFork : Model -> Bool
isPlainCascadeFork model =
    case model.planCascadeFork of
        Just target ->
            target.planId == ""

        Nothing ->
            False


{-| C2b fork branch (§8.1): a top-level re-run fork takes over the same
Session:
- The window key stays Session.id (= plan origin `meta.origin.sessionId`,
  NOT forkSource — that is the old work copy, which may have resume differences).
- sessionWorkCopies[Session.id] = forkId (new work copy); buffered
  frames route by it back into sessions[Session.id] (overwriting old content).
- planReplaySessions marks Session.id (replaying history does not
  auto-create plans).
- No sessionOrder / sessionNums / windowPositions entries (the window
  did not change, so position is naturally preserved — no forkInheritPos);
  no lineage written.
- The old work-copy process/directory is closed by RegisterFork
  (registerForkInstance).
-}
forkSessionCreated : String -> Model -> ( Model, Cmd Msg )
forkSessionCreated forkId model =
    let
        sessionId =
            case model.planCascadeFork of
                Just target ->
                    Dict.get target.childPlanId model.planMetas
                        |> Maybe.map (.origin >> .sessionId)
                        |> Maybe.withDefault forkId

                Nothing ->
                    forkId

        -- Build the mapping first, then replay the buffer: core id (forkId) → Session.id.
        newWorkCopies =
            Dict.insert sessionId forkId model.sessionWorkCopies

        newSessions =
            Dict.insert sessionId (T.emptySession sessionId) model.sessions

        buffered =
            Dict.get forkId model.pendingEvents |> Maybe.withDefault []

        sessionsAfterBuffer =
            List.foldl
                (applyPendingEvent (PU.sessionIdOfWorkCopyDict newWorkCopies))
                newSessions
                buffered

        m0 =
            { model
                | sessionWorkCopies = newWorkCopies
                , sessions = sessionsAfterBuffer
                , activeId = Just sessionId
                , planMessageCounts =
                    case Dict.get sessionId sessionsAfterBuffer of
                        Just s ->
                            Dict.insert sessionId (planIndexForMessage s.messages) model.planMessageCounts

                        Nothing ->
                            model.planMessageCounts
                , planReplaySessions = Set.insert sessionId model.planReplaySessions
                , pendingEvents = Dict.remove forkId model.pendingEvents
            }

        cmds =
            Cmd.batch
                [ Task.attempt (\\_ -> NoOp) (Dom.focus ("msg-input-" ++ sessionId))
                , Ports.scrollToBottom { sessionId = sessionId }
                ]
    in
    ( m0, cmds )


{-| Usual creation of a new session window (plain New Session / resume /
runner node session / node cascade fork). After C2b this only handles
those paths — top-level forks go through forkSessionCreated.
-}
createSessionWindow : String -> Model -> ( Model, Cmd Msg )
createSessionWindow id model ='''

# New SessionCreated case: short if-else (branch list stays contiguous)
new_case = """        SessionCreated id ->
            -- C2b (§8.1): a top-level cascade fork does not create a new
            -- window — the forked session is just a new work copy of the
            -- same Session (window key = Session.id, unchanged).
            -- Node forks / plain creates go through createSessionWindow
            -- (original logic).
            if isPlainCascadeFork model then
                forkSessionCreated id model

            else
                createSessionWindow id model"""

# insert point: before the doc comment that directly precedes `update :`
# (helpers must sit between top-level definitions, not between a doc
# comment and its definition, and not between case branches)
u = None
for idx, ln in enumerate(lines):
    if ln.startswith("update : Msg -> Model ->"):
        # find the doc comment end just above (line containing just "-}")
        j = idx - 1
        while j > 0 and lines[j].strip() == "":
            j -= 1
        if lines[j].strip() == "-}":
            u = j - 1  # insert before the "{-|" line
            while u > 0 and not lines[u].startswith("{-|"):
                u -= 1
        else:
            u = idx
        break
assert u is not None, "update type annotation not found"

insert = helpers.split("\n") + dedented + [""]

new_lines = (
    lines[:start]
    + new_case.split("\n")
    + lines[end:]
)
# re-locate (line numbers shifted)
u2 = None
for idx, ln in enumerate(new_lines):
    if ln.startswith("update : Msg -> Model ->"):
        j = idx - 1
        while j > 0 and new_lines[j].strip() == "":
            j -= 1
        if new_lines[j].strip() == "-}":
            u2 = j - 1
            while u2 > 0 and not new_lines[u2].startswith("{-|"):
                u2 -= 1
        else:
            u2 = idx
        break
assert u2 is not None
out = new_lines[:u2] + insert + new_lines[u2:]

open(path, "w", encoding="utf-8").write("\n".join(out))
print("OK v2: helpers + createSessionWindow moved before update")
