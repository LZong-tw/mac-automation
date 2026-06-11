// input-source-restorer v11 — input source hijack guard daemon
//
// Problem: macOS switches the input source to ABC during secure input
// (password fields) or for no visible reason, forcing the user (on the
// Squirrel IME) to switch back by hand every time. This daemon detects
// the hijack and restores automatically.
//
// The original source was lost; this file is a behavior-equivalent
// rebuild from binary strings and months of observed logs
// (the "secure owner context policy" of v11):
//   - track the input source the user actually wants (tracked)
//   - secure input held by a whitelisted process (loginwindow /
//     SecurityAgent / CoreAuthentication.agent): expected behavior,
//     restore after SECURE_OFF
//   - switched to ABC with no secure context: MYSTERY_DETECTED — capture
//     the top-CPU processes for forensics (to identify which background
//     process keeps touching the input source), then ENFORCE a restore
//   - >= 3 consecutive restores: BACKOFF 5s, never fight another
//     program in an infinite loop
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

// Secure input owner: kCGSSessionSecureInputPID from the CGSession dictionary
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

// ---- State ----
var tracked = currentSourceID()          // the input source the user intends to use
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
    // After TISSelectInputSource succeeds, TISCopyCurrentKeyboardInputSource
    // lags asynchronously — trust noErr as success instead of reading back
    // immediately (which falsely reports failure). If the switch did not
    // stick, the next TIS change notification re-triggers ENFORCE.
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

// ---- TIS change events ----
var prevSource = tracked
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil, queue: .main
) { _ in
    let now = currentSourceID()
    // TIS_OWN = this change was caused by our own restore (back to tracked within 1s)
    let selfCaused = now == tracked && Date().timeIntervalSince(lastRestoreAt) < 1.0
    appendLog("\(selfCaused ? "TIS_OWN" : "TIS") \(frontmostContext()) secure=\(secureFlag()) Δt=\(deltaT())s, prev=\(prevSource) | → \(now)")
    lastTISEvent = Date()
    defer { prevSource = now }
    guard now != tracked else {
        consecutiveRestores = max(0, consecutiveRestores)  // back on track; let the backoff window expire naturally
        return
    }
    if now == abcID {
        let owner = secureInputOwner()
        let ownerWhitelisted = owner?.bundleIdentifier.map { secureOwnerWhitelist.contains($0) } ?? false
        if IsSecureEventInputEnabled() && ownerWhitelisted {
            // password-field context: expected, restore after SECURE_OFF
            return
        }
        appendLog("MYSTERY_DETECTED procs=[\(topProcs())]")
        restore(reason: "mystery-abc")
    } else {
        // the user deliberately switched: update intent
        tracked = now
        consecutiveRestores = 0
    }
}

// ---- Secure input polling (SECURE_ON / SECURE_OFF edge detection) ----
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

// ---- App activation context (APP_FOCUS) ----
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    appendLog("APP_FOCUS \(appContext(app)) Δt=\(deltaT())s_after_TIS")
}

appendLog("STARTED v11 (secure owner context policy) initial=\(currentSourceID()) tracked=\(tracked)")
RunLoop.current.run()
