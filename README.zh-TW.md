# ds-claude

[English](README.md) | **繁體中文**

讓 Claude 盡量不動手的 skill。Claude 寫規格和驗收腳本，DeepSeek 經 [OpenCode](https://opencode.ai) Go 動手。驗收結果看 exit code（程式結束時回傳的數字，0 代表成功），最後由 Claude 裁決。

## 為什麼要做

寫程式時最貴的通常是 Claude 的 token，而很多 token 花在把已經想清楚的計畫打出來。這個 skill 把打字的部分交給便宜的模型，Claude 只留在需要判斷的地方。

便宜的 worker 需要一道它唬不過去的檢查。所以驗收腳本在動工前就寫好，結果由 exit code 決定。worker 自己的回報不算數。

## 運作方式

```
Claude 寫好 task/SPEC.md、task/scope.txt、task/verify.sh
   │
   ▼
ds-run.sh
   ├─ 1. 工作目錄有未提交的改動就拒絕
   ├─ 2. 基線：動工前 verify.sh 必須失敗
   ├─ 3. opencode run 交給 DeepSeek flash
   ├─ 4. 竄改檢查：task 的檔案必須沒變
   ├─ 5. 範圍檢查：每個改動的路徑都要符合 scope.txt
   └─ 6. 用 worker 動工前留的副本跑 verify.sh，再做一次第 4、5 步
   │
   ▼
Claude 看 diff，決定放行、重做、升級或接手
```

含機密或個資的工作、不可逆或對外的動作，要使用者同意該張工單才派，不同意就由 Claude 做。純判斷、一條指令或改一行就完成的事，也由 Claude 做。

## 安裝

### Claude Code

```bash
git clone https://github.com/royalskynet/ds-claude
cp -R ds-claude/skills/ds-claude ~/.claude/skills/
npm i -g opencode-ai
opencode auth login   # 選 OpenCode Go
```

### claude.ai／Cowork

1. 打包：`cd skills && zip -r ds-claude.skill ds-claude`
2. 在 Claude 設定的 Skills 區上傳 `ds-claude.skill`。
3. Claude 要 `OPENCODE_API_KEY` 時提供給它。雲端沙箱沒有本機登入。

## 需求

- [OpenCode Go](https://opencode.ai) 訂閱
- `git`、`bash` 3.2 以上、`opencode` v2 以上
- 工作目錄是 git repo 的根目錄，而且至少有一個 commit

## 使用方式

請 Claude 做實作工作，或直接點名：「用 ds-claude 加上 CSV 匯出」。Claude 會在工作目錄寫三個檔。

`task/SPEC.md` 寫目標、關鍵決定、worker 不准做的事：

```markdown
# 在 slug.py 實作 slug(s)
轉小寫，連續的非英數字元換成一個連字號，去掉頭尾的連字號。只用標準函式庫。
```

`task/scope.txt` 列出 worker 可以改的路徑，一行一個 glob。`*` 會跨目錄比對。

```
slug.py
```

`task/verify.sh` 是驗收腳本，在工作目錄執行，exit 0 才算通過：

```bash
set -e
python3 -c "from slug import slug; assert slug('  Hello, World!! ')=='hello-world'"
```

接著 Claude 執行派工腳本：

```bash
bash skills/ds-claude/scripts/ds-run.sh <工作目錄>
```

| 參數 | 作用 |
|---|---|
| `--retry` | 保留上一輪的改動，並叫 worker 讀 `task/verify.log` |
| `--pro` | 改用最新的 DeepSeek pro |
| `--no-baseline` | 跳過「動工前必須失敗」的檢查。用於行為不變的重構 |
| `--model <provider/model>` | 指定模型 |

| 環境變數 | 預設值 | 作用 |
|---|---|---|
| `DS_TIMEOUT` | `900` | worker 的時間上限（秒） |
| `DS_MODEL` | 最新的 flash | 等同 `--model` |

### 結果

| exit | 最後一行 | 意思 |
|---|---|---|
| 0 | `PASS` | 驗收通過，改動都在範圍內 |
| 1 | `FAIL verify` | 驗收失敗，看 `task/verify.log` |
| 2 | `FAIL scope` | 改到範圍外，或 worker 動了 task 的檔案 |
| 3 | `FAIL setup` | 前置條件不符，worker 沒有啟動 |
| 4 | `FAIL worker` | opencode 報錯或逾時，看 `task/exec.log` |

### 唯讀查詢

```bash
bash skills/ds-claude/scripts/ds-run.sh <工作目錄> --ask "問題"
```

worker 只讀檔，答案寫到 `task/notes.md`。不用寫 task 檔，工作目錄也不必是 git repo。答案是空的，或 `git status` 顯示有檔案被改，腳本就判失敗。

### 工單大小檢查

派工前腳本會拒絕兩種工單：`SPEC.md` 超過 40 行而且 `scope.txt` 超過 2 個 glob 的，以及 `verify.sh` 裡有單獨一行 `! cmd` 的。拆成多張，或加 `--no-lint`。

### 失敗時

Claude 一次升一級：

1. 失敗來自規格不清，就修規格。
2. 用 flash 重做一次。
3. 用 pro 重做一次。
4. Claude 接手完成。要先收起 worker 的改動時，執行 `git stash push -u -m ds-claude-rollback`，之後還拿得回來。

## 腳本會動到你電腦上的什麼

- 把 `task/` 加進 `.git/info/exclude`，讓 log 不出現在 diff 裡。
- 寫入 `task/base`、`task/exec.log`、`task/verify.log`、`task/artifacts`、`task/dispatch-log.tsv`。
- 在你的電腦上執行 `task/verify.sh`，每次派工最多兩次。
- 替 worker 和 `verify.sh` 設定 `PYTHONDONTWRITEBYTECODE=1`，避免 Python 快取檔造成範圍檢查失敗。
- 用 `opencode run --auto` 跑 worker，工具呼叫不會逐一詢問。
- 不會 commit、push 或 reset。改動留在工作目錄，等 Claude 審查。

## 注意事項

- **worker 沒有沙箱。** 這些檢查抓得到失誤和取巧，擋不住存心破解檢查的 worker。實測時不論有沒有 `--auto`，`opencode run` 都能寫到 repo 外，`OPENCODE_PERMISSION={"external_directory":"deny"}` 也擋不住。範圍檢查只看得到 repo 內的改動。只在寫錯還救得回來的地方使用。
- **你的程式碼會送到第三方模型。** 派出去的工作不要含機密或個資。
- **範圍檢查看不到 `.gitignore` 裡的檔案。**

## 目前狀態

| 環境 | 狀態 |
|---|---|
| macOS 上的 Claude Code | 已實測：opencode v2.2.5 真實派工給 `opencode-go/deepseek-v4.1-flash`，通過 |
| claude.ai／Cowork | 尚未測試。需要沙箱能用 npm 安裝 opencode，而且連得到 OpenCode |

## 與 Genie 並用

已在同時裝有 [Genie Harness](https://github.com/royalskynet/genie-harness) 的機器上檢查。裝了 ds-claude 後，派工規則以 ds-claude 為準，衝突的 Genie 部分要關掉。

- **wheel gate：Genie 0.5.8 已解決。** 裝了 ds-claude 時，它不再擋 `task/verify.sh`。更舊的 Genie 可能在同一輪擋一次第一次寫入，再寫一次就過。
- **guard：沒有衝突，保持開啟。** 裝了 Genie 的 OpenCode 外掛時，它也會在 worker 裡運作。實測 worker 的 `git clean -fd` 被擋，檔案還在。它是 worker 唯一的安全檢查。
- **還原。** 改用 `git stash`，因為 Genie 會擋 `git clean -f`。
- **「派工」這個詞。** ds-claude 不用它觸發，留給你本機已有的路由。

## 常見問題

**為什麼用腳本，不用第二個模型驗收？** 同一個模型當驗收員，盲點和 worker 一樣，還要多花一輪。腳本每次給的答案都一樣。

**為什麼 `verify.sh` 要先失敗？** 動工前就通過的檢查，證明不了工作有做對。

**`opencode run` 會卡住嗎？** stdin（程式的標準輸入）一直開著就會，因為它在等輸入結束。`ds-run.sh` 已經關掉 stdin。自己呼叫時要加 `</dev/null`。

## 測試

```bash
bash tests/test.sh
```

測試不連網，用假的 `opencode` 代替。

## 相關專案

[aashahin/claude-opencode-delegate](https://github.com/aashahin/claude-opencode-delegate) 是 MCP server，讓 Claude 把工作派給 OpenCode 裡的任何模型。想用多種模型、不需要驗收閘時適合它。

`SKILL.md` 的分流表與兩條守則（任務中途不換主模型；規格明確不保證小模型夠用）改寫自 [Rajvardhman05/claude-model-router](https://github.com/Rajvardhman05/claude-model-router)（MIT）。

## 授權

[MIT](LICENSE)
