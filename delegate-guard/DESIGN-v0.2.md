# delegate-guard v0.2 設計（2026-10-26，wheel 卡：借鏡｜自造）

## 為什麼改

v0.1 每次工具呼叫都問 Laya「這一動要不要派」，判不下就 deny。有三個問題：

1. 單次 Edit／Bash 看不出整個任務多大。這是判斷顆粒度錯了。
2. Laya 目前常態回 503（fixindex 11413），等於非唯讀的呼叫全部被擋，主 session 會被鎖死。
3. 預估時間在事前量不到。Anthropic 實測 token 用量單獨就解釋 80% 的效能變異，所以改看 token 和工具呼叫數。
   出處：https://www.anthropic.com/engineering/multi-agent-research-system

## 本機校準（60 個 transcript，572 段「一則使用者訊息→下一則」）

| 每段工具呼叫數 | p50 7 | p75 16 | p90 37 | p95 57 |
|---|---|---|---|---|

- 呼叫數 ≥25 的段佔 17%，吃掉 57% 的計費輸入；這 96 段裡只有 10 段有派子代理。
- 呼叫數 ≥15 的段吃掉 72%。
- 每次呼叫都要重送一次上下文，所以一段的消耗 ≈ 呼叫數 × 當下上下文大小。

## 訊號（全部零 token，hook 可取得）

| # | 訊號 | 閾值 | 取得方式 |
|---|---|---|---|
| S1 | 本段已發生的工具呼叫數 | ≥15 提醒；≥25 deny 一次 | PreToolUse 按 session 計數，UserPromptSubmit 歸零 |
| S2 | 上下文大小（加權） | ctx >100k 時 S1 閾值 ×0.6 | transcript 最後一筆 assistant usage：input＋cache_read＋cache_creation |
| S3 | 同一動作套多個檔 | 同工具、≥10 個不同路徑 | PreToolUse 記 (tool, path) 集合；Anthropic「探索 ≥10 檔＝強訊號」 |
| S4 | 大輸出 | tool_response >40k 字元（約 10k token），本段第 2 次起 | PostToolUse 量長度；MCP 文件 10k 警告線 |
| S5 | 硬關鍵字 | 依賴升級、全套測試（沿用 v0.1 regex，拿掉 `sed -i` 與 Edit 內文關鍵字） | PreToolUse 讀指令 |
| S6 | 任務層打分 | prompt 有 ≥3 個獨立項、「每個／全部／N 個檔」、照範本、轉檔、搬移 | UserPromptSubmit 規則打分（借鏡 LiteLLM complexity router） |

## 放行（任何一條成立就不擋）

- 已經委派：指令或 Agent 呼叫含 o-worker、dcq、dispatch-router。
- 唯讀指令。
- 本段已經派過子代理：只計之後的呼叫。
- 明示自做：Bash 指令含 `# deguard:self <理由>`，寫進 log 供稽核。
- 需要即時上下文：改的檔本 session 已經 Read 過，而且 S6 沒命中。
- `/deguard off`。

## 動作分級

- S6 命中，或 S1 達提醒線：UserPromptSubmit／PreToolUse 回 `additionalContext`，叫模型派 o，主 session 只寫工單和驗收。不擋。
- S1 達 deny 線、S3、S5 命中：deny 一次並附 reason，同一段之後不再 deny，避免把 session 鎖死。
- System 1（Laya）只在 UserPromptSubmit 當 S6 的平手裁判：分數落在中間時才問。判不下就放行，不 deny。

## 反方（何時委派更貴）

- 子代理是冷啟動，要重讀上下文；agent 約用聊天的 4 倍 token。
- 小修、要來回迭代、多個階段共用大量上下文的工作，留在主 session。
- 寫程式碼可平行的部分比研究少（Cognition〈Don't build multi-agents〉）。

所以 deny 只用在高精度訊號（S1 deny 線、S3、S5），其餘一律只提醒。

## 驗收

- 單元測試涵蓋 S1–S6 加上全部放行條件。
- 回放測試：把校準語料的 572 段重播進 judge。
  - 標準一：deny 段數 ≤20%。
  - 標準二：deny 命中的段要佔計費輸入 ≥50%。
- 端到端：餵假 payload，Laya 回 503 時要放行，不可 deny。
