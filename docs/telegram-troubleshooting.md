# Telegram Channel 連線問題排查指南

## 一、快速診斷清單

- [ ] Bot Token 是否正確且有效？
- [ ] Bot 是否已加入頻道且具備管理員權限？
- [ ] Channel ID 格式是否正確（supergroup/channel 需加負號）？
- [ ] 網路是否可存取 `api.telegram.org`？
- [ ] 是否有 Webhook 與 polling 同時運作的衝突？

---

## 二、常見問題與解法

### 1. Bot Token 無效或過期

**症狀：** `{"ok":false,"error_code":401,"description":"Unauthorized"}`

**原因：**
- Token 複製錯誤（多/少空格、換行）
- Bot 被 @BotFather 撤銷或重設

**解法：**
```bash
# 驗證 Token 是否有效
curl https://api.telegram.org/bot<YOUR_TOKEN>/getMe
```
- 若回傳 `Unauthorized`，到 @BotFather 用 `/token` 重新取得 Token。
- 確認 Token 格式：`123456789:AABBccdd...`（數字:字串）。

---

### 2. Channel ID 錯誤

**症狀：** `{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}`

**原因：**
- 公開頻道可用 `@channel_username`，私人頻道必須用數字 ID。
- Supergroup 與 Channel 的 ID 是**負數**（如 `-1001234567890`）。

**取得正確 Channel ID 的方法：**
```bash
# 1. 把 Bot 加入頻道，發一則訊息，然後查詢 updates
curl https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates

# 2. 從回傳的 JSON 中找 "chat":{"id": -100XXXXXXXXXX}
```

**注意：** 舊式群組 ID 為負數（如 `-123456`），升級為 supergroup 後 ID 格式變為 `-100XXXXXXXXXX`。

---

### 3. Bot 未加入頻道 / 權限不足

**症狀：** `{"ok":false,"error_code":400,"description":"Bad Request: have no rights to send a message"}`

**原因：**
- Bot 未被加入頻道。
- Bot 在頻道中不是管理員，或缺少「發送訊息」權限。

**解法：**
1. 進入頻道 → 管理員 → 新增管理員 → 搜尋你的 Bot。
2. 開啟「發送訊息」（Post Messages）權限。
3. 若頻道設為私人，確認 Bot 有存取權限。

---

### 4. 網路連線問題 / 無法存取 Telegram API

**症狀：** `Connection refused`、`Connection timed out`、`SSL handshake failed`

**診斷：**
```bash
# 測試 API 連通性
curl -v https://api.telegram.org/bot<TOKEN>/getMe

# 測試 DNS 解析
nslookup api.telegram.org

# 測試端口
telnet api.telegram.org 443
```

**常見原因與解法：**

| 原因 | 解法 |
|------|------|
| 防火牆封鎖 443/80 port | 開放出站連線至 `api.telegram.org` |
| 伺服器 IP 被 Telegram 封鎖（部分國家） | 使用代理或 SOCKS5 |
| SSL 憑證問題 | 更新 CA 憑證：`apt-get install ca-certificates` |
| 企業網路 proxy 攔截 | 設定 `HTTPS_PROXY` 環境變數 |

**使用代理設定範例（Python）：**
```python
import httpx
from telegram import Bot

proxy = "socks5://user:pass@proxy_host:port"
bot = Bot(token=TOKEN, request=httpx.AsyncHTTPTransport(proxy=proxy))
```

---

### 5. Webhook 與 Polling 衝突

**症狀：** Bot 無回應，或收到 `{"ok":false,"error_code":409,"description":"Conflict"}`

**原因：** 同時啟動了 `bot.polling()` 和已設定的 Webhook，兩者互斥。

**解法：**
```bash
# 先刪除現有 Webhook
curl https://api.telegram.org/bot<TOKEN>/deleteWebhook

# 確認 Webhook 狀態
curl https://api.telegram.org/bot<TOKEN>/getWebhookInfo
```

選擇其中一種模式：
- **Polling**：適合本機開發，不需公開 IP。
- **Webhook**：適合生產環境，需 HTTPS + 公開網址。

---

### 6. Rate Limiting（請求頻率限制）

**症狀：** `{"ok":false,"error_code":429,"description":"Too Many Requests: retry after X"}`

**Telegram Bot API 限制：**
- 對同一個 chat：每秒最多 1 則訊息。
- 對不同 chat：每分鐘最多 30 則訊息（廣播時）。
- 頻道發文相對寬鬆，但仍有上限。

**解法：**
```python
import time

def send_with_retry(bot, chat_id, text, retries=3):
    for i in range(retries):
        try:
            bot.send_message(chat_id=chat_id, text=text)
            return
        except Exception as e:
            if "429" in str(e):
                wait = int(str(e).split("retry after ")[-1])
                time.sleep(wait + 1)
            else:
                raise
```

---

### 7. 頻道訊息接收不到（getUpdates 為空）

**症狀：** `getUpdates` 回傳空陣列，頻道有新訊息卻收不到。

**原因：**
- 頻道訊息預設**不會**出現在 `getUpdates`，只有群組和私聊會。
- 需要將 Bot 設為頻道管理員，並使用 `channel_post` 事件類型。

**Handler 設定（python-telegram-bot）：**
```python
from telegram.ext import Application, MessageHandler, filters

app = Application.builder().token(TOKEN).build()

# 監聽頻道貼文，而非一般訊息
app.add_handler(MessageHandler(filters.ChatType.CHANNEL, handle_channel_post))
```

---

### 8. MTProto 協議問題（使用 Telethon / Pyrogram）

**症狀：** `AuthKeyError`、`FloodWaitError`、`UserDeactivatedBanError`

**原因與解法：**

| 錯誤 | 原因 | 解法 |
|------|------|------|
| `AuthKeyError` | Session 檔案損毀或過期 | 刪除 `.session` 檔，重新登入 |
| `FloodWaitError` | 操作過於頻繁 | 等待指定秒數後重試 |
| `UserDeactivatedBanError` | 帳號被封鎖 | 換帳號或聯繫 Telegram 申訴 |
| `ChannelPrivateError` | 未加入私人頻道 | 先用帳號加入頻道 |

**Telethon 連線範例：**
```python
from telethon import TelegramClient
from telethon.errors import FloodWaitError
import asyncio

async def main():
    client = TelegramClient('session', API_ID, API_HASH)
    await client.start()
    try:
        await client.send_message('@channel_username', 'Hello')
    except FloodWaitError as e:
        await asyncio.sleep(e.seconds)
```

---

## 三、環境變數設定建議

```env
TELEGRAM_BOT_TOKEN=123456789:AABBccdd...
TELEGRAM_CHANNEL_ID=-1001234567890
TELEGRAM_API_BASE_URL=https://api.telegram.org  # 可替換為自架 API server
HTTPS_PROXY=socks5://127.0.0.1:1080             # 若需要代理
```

---

## 四、自我檢測腳本

```python
import requests

TOKEN = "YOUR_BOT_TOKEN"
CHANNEL_ID = "YOUR_CHANNEL_ID"
BASE = f"https://api.telegram.org/bot{TOKEN}"

def check():
    # 1. 驗證 Token
    r = requests.get(f"{BASE}/getMe", timeout=10)
    if not r.json().get("ok"):
        print("❌ Token 無效")
        return
    print(f"✅ Bot: {r.json()['result']['username']}")

    # 2. 驗證 Webhook 狀態
    r = requests.get(f"{BASE}/getWebhookInfo", timeout=10)
    info = r.json()["result"]
    if info.get("url"):
        print(f"⚠️  Webhook 已設定: {info['url']}")
    else:
        print("✅ 無 Webhook（使用 polling）")

    # 3. 嘗試傳送測試訊息
    r = requests.post(f"{BASE}/sendMessage", json={
        "chat_id": CHANNEL_ID,
        "text": "🔧 連線測試"
    }, timeout=10)
    if r.json().get("ok"):
        print("✅ 訊息傳送成功")
    else:
        print(f"❌ 傳送失敗: {r.json()['description']}")

check()
```

---

## 五、參考資源

- [Telegram Bot API 官方文件](https://core.telegram.org/bots/api)
- [python-telegram-bot 文件](https://python-telegram-bot.readthedocs.io/)
- [Telethon 文件](https://docs.telethon.dev/)
- [Pyrogram 文件](https://docs.pyrogram.org/)
