// capslock-monitor — 記錄 Caps Lock 狀態變化與當時的前景 app
// 原始版本原始碼遺失;本檔依 binary strings 與 log 格式重建,行為等價。
// log 格式:`2026-06-11 13:48:53 [iTerm2] caps_lock=ON`
import AppKit
import CoreGraphics

let logPath = NSString(string: "~/.local/log/capslock-state.log").expandingTildeInPath
let fmt = DateFormatter()
fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

func appendLog(_ line: String) {
    let data = (line + "\n").data(using: .utf8)!
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(data)
        h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

func capsLockOn() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
}

var prev = capsLockOn()
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let now = capsLockOn()
    guard now != prev else { return }
    prev = now
    let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    appendLog("\(fmt.string(from: Date())) [\(app)] caps_lock=\(now ? "ON" : "OFF")")
}
RunLoop.current.run()
