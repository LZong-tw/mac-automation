// input-source-restorer v11 — 輸入法防亂切換守護程式
//
// 問題:macOS 會在 secure input(密碼框)或不明原因下把輸入法切到 ABC,
// 使用者(Squirrel 鼠鬚管)需要每次手動切回。本工具自動偵測並還原。
//
// 原始版本原始碼遺失;本檔依 binary strings 與既有 log 行為重建
// (secure owner context policy,與原 v11 行為等價):
//   - 追蹤使用者「真正想用」的輸入法(tracked)
//   - secure input 由白名單程序(loginwindow / SecurityAgent /
//     CoreAuthentication.agent)持有時:屬預期行為,等 SECURE_OFF 後還原
//   - 無 secure 情境卻被切到 ABC:MYSTERY_DETECTED,記下當下高 CPU 程序
//     做鑑識(供事後比對是哪個背景程式在亂動輸入法),並 ENFORCE 還原
//   - 連續還原 >= 3 次:BACKOFF 暫停 5 秒,避免和其他程式打架成迴圈
import AppKit
import Carbon

let logPath = NSString(string: "~/.local/log/input-source-restorer.log").expandingTildeInPath
let secureOwnerWhitelist: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.SecurityAgent",
    "com.apple.CoreAuthentication.agent",
]
let abcID = "com.apple.keylayout.ABC"
let maxRestoreAttempts = 3
let backoffThreshold = 3
let backoffSeconds = 5.0

let fmt = DateFormatter()
fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

func appendLog(_ line: String) {
    let data = ("\(fmt.string(from: Date())) \(line)\n").data(using: .utf8)!
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(data)
        h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

func currentSourceID() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "unknown" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func appContext(_ app: NSRunningApplication?) -> String {
    let name = app?.localizedName ?? "unknown"
    let bundle = app?.bundleIdentifier ?? "-"
    let pid = app.map { String($0.processIdentifier) } ?? "-"
    return "[\(name)|\(bundle)|pid=\(pid)|win=-]"
}

func frontmostContext() -> String { appContext(NSWorkspace.shared.frontmostApplication) }

// secure input 擁有者:從 CGSession dictionary 的 kCGSSessionSecureInputPID 取得
func secureInputOwner() -> NSRunningApplication? {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
          let pid = dict["kCGSSessionSecureInputPID"] as? Int32 else { return nil }
    return NSRunningApplication(processIdentifier: pid)
}

func ownerContext() -> String {
    guard let owner = secureInputOwner() else { return "[nil]" }
    return appContext(owner)
}

func topProcs() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", #"ps -arcwwxo pid,%cpu,comm -r 2>/dev/null | head -6 | tail -5 | awk '{printf "%s(%s%%) ", $3, $2}'"#]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

func selectSource(id: String) -> Bool {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let src = list.first else {
        appendLog("WARN source not found in enabled list: \(id)")
        return false
    }
    let status = TISSelectInputSource(src)
    if status != noErr {
        appendLog("WARN TISSelectInputSource status=\(status)")
        return false
    }
    return true
}

// ---- 狀態 ----
var tracked = currentSourceID()          // 使用者意圖的輸入法
var lastTISEvent = Date()
var lastSecure = IsSecureEventInputEnabled()
var consecutiveRestores = 0
var backoffUntil = Date.distantPast

func deltaT() -> String { String(format: "%.2f", Date().timeIntervalSince(lastTISEvent)) }
func secureFlag() -> String { IsSecureEventInputEnabled() ? "1" : "0" }

var lastRestoreAt = Date.distantPast

func restore(reason: String) {
    guard Date() >= backoffUntil else { return }
    consecutiveRestores += 1
    appendLog("ENFORCE \(frontmostContext()) secure=\(secureFlag()) Δt=\(deltaT())s | restoring \(tracked) (consec=\(consecutiveRestores))")
    // TISSelectInputSource 成功後,TISCopyCurrentKeyboardInputSource 的回讀有
    // 非同步延遲 — 信任 noErr 即視為成功,別立即回讀驗證(會誤報失敗)。
    // 若實際沒切成功,下一個 TIS 變更通知會再次觸發 ENFORCE 自我修正。
    for attempt in 1...maxRestoreAttempts {
        if selectSource(id: tracked) {
            appendLog("RESTORED \(tracked) attempt=\(attempt)")
            lastRestoreAt = Date()
            break
        }
        if attempt == maxRestoreAttempts {
            appendLog("ERROR failed to restore \(tracked) after \(maxRestoreAttempts) attempts")
        }
    }
    if consecutiveRestores >= backoffThreshold {
        appendLog("BACKOFF \(consecutiveRestores) consecutive restores, pausing 5s")
        backoffUntil = Date().addingTimeInterval(backoffSeconds)
        consecutiveRestores = 0
    }
}

// ---- TIS 切換事件 ----
var prevSource = tracked
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil, queue: .main
) { _ in
    let now = currentSourceID()
    // TIS_OWN = 這次切換是自己的還原動作造成的(restore 後 1 秒內回到 tracked)
    let selfCaused = now == tracked && Date().timeIntervalSince(lastRestoreAt) < 1.0
    appendLog("\(selfCaused ? "TIS_OWN" : "TIS") \(frontmostContext()) secure=\(secureFlag()) Δt=\(deltaT())s, prev=\(prevSource) | → \(now)")
    lastTISEvent = Date()
    defer { prevSource = now }
    guard now != tracked else {
        consecutiveRestores = max(0, consecutiveRestores)  // 回到正軌,讓 backoff 視窗自然過期
        return
    }
    if now == abcID {
        let owner = secureInputOwner()
        let ownerWhitelisted = owner?.bundleIdentifier.map { secureOwnerWhitelist.contains($0) } ?? false
        if IsSecureEventInputEnabled() && ownerWhitelisted {
            // 密碼框情境:預期行為,等 SECURE_OFF 再還原
            return
        }
        appendLog("MYSTERY_DETECTED procs=[\(topProcs())]")
        restore(reason: "mystery-abc")
    } else {
        // 使用者主動切到別的輸入法:更新意圖
        tracked = now
        consecutiveRestores = 0
    }
}

// ---- secure input 狀態輪詢(SECURE_ON / SECURE_OFF 邊緣偵測)----
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    let secure = IsSecureEventInputEnabled()
    guard secure != lastSecure else { return }
    lastSecure = secure
    if secure {
        appendLog("SECURE_ON \(frontmostContext()) secure=\(secureFlag()) Δt=\(deltaT())s | target=\(tracked) owner=\(ownerContext()) procs=[\(topProcs())]")
    } else {
        let current = currentSourceID()
        appendLog("SECURE_OFF \(frontmostContext()) secure=\(secureFlag()) Δt=\(deltaT())s | current=\(current) target=\(tracked) owner=\(ownerContext())")
        if current != tracked {
            restore(reason: "secure-off")
        }
    }
}

// ---- App 切換脈絡(APP_FOCUS)----
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    appendLog("APP_FOCUS \(appContext(app)) Δt=\(deltaT())s_after_TIS")
}

appendLog("STARTED v11 (secure owner context policy) initial=\(currentSourceID()) tracked=\(tracked)")
RunLoop.current.run()
