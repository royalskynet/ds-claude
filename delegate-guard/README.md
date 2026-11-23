# delegate-guard

主 session 做「量大、低難度」的機械活時，先建議派 o；訊號夠強就直接把這一動改派給 o-worker。
派給 o 的工單必須帶成果驗收標準；o 完工後，主 session 用派工當下的驗收快照自己重驗。
起因 fixindex 11411。設計見 [DESIGN-v0.2.md](DESIGN-v0.2.md)；v0.3 經 Codex（gpt-6.1-sol）事前驗屍後修正。不改 O（o-worker.md、dcq、wo-verify），只讀它們的產物。

## 兩級動作

- **建議派**（不擋，回 `additionalContext`）：S6 任務打分命中、S1 達 10 次、S4 本段第 2 次大輸出。每段各一次。
- **直接改派**（deny，reason 附工單格式）：S1 達 18 次、S3、S5。非唯讀動作一直擋，直到 PostToolUse 確認 o 真的派出、或明示自做；每段最多擋 3 次，第 4 次放行並記 `overridden`，避免鎖死 session。

## 改派三類

| 類 | 條件 | 做法 |
|---|---|---|
| 無法派 | o 禁區（`~/.claude`、`.git/config`、launchd、憑證、LCT／CoinW）、`# deguard:self`、即時上下文 | 不擋，說一次原因 |
| 全權派 | S6 任務層命中，且訊號是 S3／S5 | 本段剩下的工作整包派，目標＝使用者原話（全文存 `goal-<sid>.md`） |
| 部分派 | 其餘 | 只派被擋的這一動＋同類批次，判斷留在主 session |

## 派工驗收閘與重驗

1. **派前**（PreToolUse）：`Agent(o-worker)` 的 prompt、`dcq add` 的工單，用 `wo-verify --dump` 抽 `## 驗收` 區塊，再 `--dry` 檢查語法。沒有區塊、語法錯、只有 echo／true／恆真比較、`|| true`、沒開 pipefail 卻用 `cmd | tail／head／tee`（rc 會是最後一段的）→ deny。`dcq add` 的工單要寫字面絕對路徑。過關就拍快照（sha256）進帳本，狀態 `proposed`。
2. **派出**（PostToolUse）：Agent 回 `agentId`；dcq 從 `~/.dcq/*/<job>.job` 的 `TASK=` 對工單。標 `launched`，解除改派要求，輸出重驗指令。派工失敗（PostToolUseFailure、dcq 沒給 job id）標 `launch-failed`，不算派出。
3. **完工**：SubagentStop 用 `agent_id` 配（先到的 stop 記 orphan，之後補配）；dcq 看 job 檔進 `done/` 或 `failed/`。
4. **重驗**：`node scripts/verify.mjs <sid> <id>` 跑 `wo-verify --pinned <快照>`。未完工 rc 75、快照 hash 被改 rc 3、工單驗收被改也是 rc 3（wo-verify 判定）。rc 記進帳本。
5. **作廢**：驗完之後在同一 cwd 又寫檔 → `stale`，要重驗（git add／commit／push／tag 不算）。
6. **Stop**：完工未重驗、作廢、重驗失敗 → `decision:block` 提醒，每筆最多 2 次；帳本損壞改名保留並明報一次。這是提醒，不是硬保證。

帳本 `~/.claude/state/delegate-guard/ledger-<sid>.json`，mkdir 鎖＋tmp→rename 原子寫。

S2：上下文 >100k token 時，S1 兩條線 ×0.6（6／11）。

## 訊號

| # | 訊號 | 線 | hook |
|---|---|---|---|
| S1 | 本段工具呼叫數 | 10 建議／18 改派 | PreToolUse 計數，UserPromptSubmit 歸零 |
| S2 | 上下文大小 | >100k ×0.6 | transcript 最後一筆 usage |
| S3 | 同工具改 ≥10 個不同檔 | 改派 | PreToolUse |
| S4 | 工具輸出 >40k 字元 | 第 2 次建議 | PostToolUse |
| S5 | 依賴升級、全套測試、rsync／ffmpeg／magick | 改派 | PreToolUse |
| S6 | prompt 打分（≥3 項清單、每個／全部、照範本、轉檔、搬移） | ≥3 建議；=2 問 Laya | UserPromptSubmit |

## 放行

- 已委派：Agent 呼叫、`dcq add|plan|run|…`、`DCQ_ORDER=`、o-worker；本段從這裡重新計數（改派要求要等派出確認才解除）。
- 唯讀：每一段（`;` `&&` `||` `|` 切開）都是唯讀指令且沒有寫檔重導向的 Bash、非寫入工具（Read／Grep／MCP…）。
- 明示自做：Bash 加 `# deguard:self <理由>`，理由進 log。
- 即時上下文：改的檔本段已 Read 成功（PostToolUse 記），且 S6 沒命中。
- 子代理內的工具呼叫（payload 帶 `agent_id`）不計。
- `/deguard off`。

Laya 只在 S6 平手時問；503、逾時、判不下一律放行。

## 跟設計稿的差異（回放校準後）

- S5 拿掉 for/while 批迴圈：60 個 transcript 裡命中 562 次，多半是短診斷迴圈，改派段會到 22.5%。
- 「已委派」不再認 `dispatch-router` 字面：`cd ~/dev/dispatch-router` 是在改派工系統本身，舊寫法會把計數歸零，大段漏判。
- v0.3（Codex 驗屍修正）：改派從「每段一次」改成「擋到派出為止，上限 3 次」；全權派只在 S6 命中時成立；`pytest x.py` 不算全套測試；S6 判斷型字眼（審查、根因、設計…）扣 2 分；配對用 tool_use_id／agentId，不靠順序。

## 開關

`/deguard on|off|status`。狀態檔 `~/.claude/delegate-guard.off`，存在＝off；hook 每次讀，切換立刻生效。
log：`~/.claude/logs/delegate-guard.log`。session 狀態：`~/.claude/state/delegate-guard/`。

## 驗收

- `node hooks/test/delegate-guard.test.mjs` → `ALL PASS`（S1–S6、三類、驗收閘、生命週期、帳本並發與損壞、端到端跑 hook 程序）
- `node scripts/replay.mjs 60` → 標準：改派段 ≤20%，改派段計費輸入 ≥50%。**2026-10-26 v0.3 FAIL**：11.3%／37.5%（無法派類另佔 9.8%）。同一語料 v0.2 也 FAIL（14.3%／47.5%，提交時是 51.3%），主因是語料漂移；S1 改派線調到 20 也只到 42.8%，閾值未動。

## 安裝（在一般終端，不帶隔離 CLAUDE_CONFIG_DIR）

```bash
env -u CLAUDE_CONFIG_DIR claude plugin marketplace add ~/dev/delegate-guard
env -u CLAUDE_CONFIG_DIR claude plugin install delegate-guard@delegate-guard --scope user
```

## 已知限制

- 即時上下文放行會讓多數 Edit 不觸發 S3（Edit 前必 Read）；S3 實際主要抓 Write 新檔與 S6 命中的任務。
- 計費輸入佔比目前未達 50%，要重新校準訊號（候選：S2 加權、長 context 少呼叫的段）。
- 假驗收檢查是啟發式，擋不住刻意的恆真變形；主 session 重驗時要看一眼驗收內容。
- 回放沒有 PostToolUse，派工一律視為成功。
