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

helpers = '''{-| C2b：进行中的级联 fork 是否为顶层（plain）fork。顶层重跑 fork 走
工作副本替换（forkSessionCreated）；节点 fork 保留旧行为（新窗口 +
血缘，C3 统一）。
-}
isPlainCascadeFork : Model -> Bool
isPlainCascadeFork model =
    case model.planCascadeFork of
        Just target ->
            target.planId == ""

        Nothing ->
            False


{-| C2b fork 分支（§8.1）：顶层重跑 fork 接管同一 Session：
- 窗口 key 保持 Session.id（= plan origin `meta.origin.sessionId`，
  不是 forkSource——那是旧工作副本，可能有 resume 差异）。
- sessionWorkCopies[Session.id] = forkId（新工作副本）；缓冲帧按此
  路由重放进 sessions[Session.id]（覆盖旧内容）。
- planReplaySessions 标记 Session.id（重放历史不自动建 plan）。
- 不建 sessionOrder / sessionNums / windowPositions 条目（窗口没换，
  位置天然保留——无需 forkInheritPos）；不写血缘。
- 旧工作副本进程/目录由 RegisterFork（registerForkInstance）关闭。
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

        -- 先建映射再重放缓冲：core id（forkId）→ Session.id。
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


{-| 新会话窗口的常规创建（普通 New Session / resume / runner 节点会话
/ 节点级联 fork）。C2b 后只负责这些路径——顶层 fork 走 forkSessionCreated。
-}
createSessionWindow : String -> Model -> ( Model, Cmd Msg )
createSessionWindow id model ='''

# New SessionCreated case: short if-else (branch list stays contiguous)
new_case = """        SessionCreated id ->
            -- C2b（§8.1）：顶层级联 fork 不创建新窗口——fork 出的会话只是
            -- 同一 Session 的新工作副本（窗口 key = Session.id 不动）。
            -- 节点 fork / 普通创建走 createSessionWindow（原逻辑）。
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
