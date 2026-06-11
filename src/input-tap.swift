// input-tap — 輸入事件診斷工具:記錄 Caps Lock 按鍵事件與輸入法切換
// 原始版本原始碼遺失;本檔依 binary strings 與 log 格式重建,行為等價。
// log 格式:
//   `2026-04-10 15:42:41.184 [loginwindow] INPUT_SOURCE_CHANGED to=ABC`
//   `... FLAGS capslock=ON keycode=57`
// 需要輔助使用權限(Accessibility)才能建立 event tap。
import AppKit
import Carbon
import CoreGraphics

let logPath = NSString(string: "~/.local/log/input-tap.log").expandingTildeInPath
let fmt = DateFormatter()
fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

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

func frontApp() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
}

func currentInputSourceName() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return "unknown" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

// 輸入法切換通知
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
    object: nil, queue: .main
) { _ in
    appendLog("\(fmt.string(from: Date())) [\(frontApp())] INPUT_SOURCE_CHANGED to=\(currentInputSourceName())")
}

// Caps Lock 按鍵事件(flagsChanged)
let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, _, event, _ in
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == 57 {  // Caps Lock
            let on = event.flags.contains(.maskAlphaShift)
            appendLog("\(fmt.string(from: Date())) [\(frontApp())] FLAGS capslock=\(on ? "ON" : "OFF") keycode=\(keycode)")
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    appendLog("\(fmt.string(from: Date())) ERROR: Failed to create event tap - need accessibility permissions")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
appendLog("\(fmt.string(from: Date())) Monitor started")
CFRunLoopRun()
