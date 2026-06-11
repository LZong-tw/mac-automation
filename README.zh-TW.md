# mac-automation

[English](README.md) | **繁體中文**

個人 macOS 自動化工具集:shell + Swift 工具與對應的 LaunchAgents。
換機時跑 `./install.sh` 即可全部還原(編譯 → symlink → bootstrap agents)。

## 工具清單

| 工具 | LaunchAgent | 用途 |
|---|---|---|
| `memory-guardian` | ✓ 每 120s | 記憶體壓力警戒/危急通知,危急時自動停深度閒置的 podman VM |
| `input-source-restorer` | ✓ 常駐 | 輸入法防亂切換守護程式(Swift,見下方說明) |
| `input-source-monitor.sh` | ✓ 常駐 | 記錄輸入法切換與當時的前景 app |
| `input-tap` | — | 輸入事件診斷工具:記錄 Caps Lock 事件與輸入法切換(Swift) |
| `capslock-monitor` | ✓ 常駐 | 記錄 Caps Lock 狀態變化與前景 app(Swift) |
| `daily-work-report-reminder` | ✓ | 17:00 工作回報通知 |
| `kubectl-eks-token` | — | kubectl exec plugin:AWS/Granted 憑證鏈 fallback(ambient → AWS_PROFILE → assume → assume --no-cache) |

## 安裝

```bash
./install.sh        # build.sh 編譯 Swift 工具,symlink bin/* → ~/.local/bin,複製 plist 並 bootstrap
```

## input-source-restorer:輸入法防亂切換(v11 policy)

macOS 會在 secure input(密碼框)或不明原因下把輸入法切到 ABC。這支
daemon 監聽 TIS 切換通知並自動還原使用者意圖的輸入法:

- **secure input 白名單**:loginwindow / SecurityAgent / CoreAuthentication.agent
  持有 secure input 時切到 ABC 屬預期行為,等 `SECURE_OFF` 再還原
- **MYSTERY_DETECTED**:無 secure 情境卻被切走 → 記下當下高 CPU 程序做鑑識,
  長期累積 log 就能比對出是哪個背景程式在亂動輸入法
- **BACKOFF**:連續還原 ≥3 次暫停 5 秒,避免和別的程式打架成無限迴圈
- **TIS vs TIS_OWN**:事件標籤區分「外部造成的切換」與「自己還原造成的切換」,
  log 才能拿來鑑識而不是自我污染

### Binary archaeology:這三支 Swift 工具的重生記

原始版本的原始碼曾經遺失,只剩 arm64 編譯成品在 `~/.local/bin` 跑了幾個月。
2026-06 要公開此 repo 時,用三個資訊源把規格反推回來重寫:

1. `strings` 抽出 log 訊息模板、defaults key、白名單 bundle id、內嵌的 ps 指令
2. `otool -L` 確認 linked frameworks(Carbon/AppKit/CoreGraphics)
3. **數月的實際 log** 反推每個事件的觸發條件與輸出格式

重寫版與舊版並跑比對行為一致後才替換。教訓:**編譯完就刪原始碼的 binary
是負債** — 這次花在考古的時間比當初寫它還多。

## memory-guardian 背景與設計決策

2026-06-11 起源:16GB MBP 重度工作負載下,WindowServer 因記憶體壓力死亡
→ loginwindow 觸發「善後型登出」(`Logout triggered by windowserver exit`)
→ 整個 GUI session 拆除重建,一天三次。guardian 在壓力到頂前介入。

- WARN(free<25% 或 swap>75%):通知,30 分鐘冷卻
- CRIT(free<15% 或 swap>90%):通知 + 自動停「深度閒置」的 podman VM
- `SACRIFICE_APPS` 預設留空(刻意:不自動關使用者的 app)

### 深度閒置判定(全部成立才停 VM)

1. host 上沒有 podman CLI process(`ps -axo comm=` 比對 binary 名稱)
2. `podman ps` 查詢**成功且**結果為空,或——
3. 每個運行中容器:postgres 查 `pg_stat_activity` 最後 client 活動 > 2h,
   其他容器 CPU < 1%
4. **任何查詢失敗一律視為非閒置** — 寧可漏判,不可誤殺

### 踩過的坑(改這支腳本前必讀)

- **launchd 的 PATH 沒有 `/opt/podman/bin`** — 腳本必須自己 export PATH,
  否則 `command -v podman` 靜默失敗,排程跑起來像沒事一樣
- **`pgrep -f 'podman exec'` 會誤觸** — 任何 argv 剛好含這字串的無關
  process(例如測試指令本身)都會 match,要用 `ps -axo comm=` 比對真實 binary
- **`pg_stat_activity` 要排除自己** — `pid <> pg_backend_pid()`,
  不然查詢本身就是「最近活動」,永遠判定為使用中
- 所有靜默路徑都要 log — `2>/dev/null` 吞掉的錯誤會浪費一小時 debug

## kubectl-eks-token 設計

kubectl exec plugin 的 stdout 必須是純 ExecCredential JSON,任何人類可讀訊息
洩漏到 stdout 都會讓 kubectl 失敗 — 所以所有 fallback 嘗試都先寫暫存檔驗證
格式再輸出。憑證來源優先序:已 assume 的 ambient session → AWS_PROFILE →
Granted assume → assume --no-cache(處理 Granted 偶發的過期快取)。
