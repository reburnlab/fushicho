// fushicho — keeps Remote Control alive in the Claude desktop app (macOS).
// (fushicho = 不死鳥, Japanese for phoenix.)
//
// The Claude desktop app relaunches itself when it auto-updates. After that relaunch the
// Remote Control bridge of the session you were driving from your phone is gone, and it does
// not come back until someone types into that session on the Mac. This small agent watches the
// app's log, notices the relaunch, reopens that session and types /rc for you.
//
// It relies on two things that are NOT a documented, stable interface and may change with any
// app update:  (1) the lines the app writes to ~/Library/Logs/Claude/main.log, and
// (2) the claude://code/continue?session=… link.  If the app changes them, this stops working.
//
// It needs the Accessibility permission (to bring the app forward and type). Nothing leaves the
// Mac: no network listener, no telemetry.

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

let VERSION = "0.1.1"
let CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"
let CLAUDE_LOG_DIR = NSHomeDirectory() + "/Library/Logs/Claude/"
let CLAUDE_LOG = CLAUDE_LOG_DIR + "main.log"
let SUPPORT = NSHomeDirectory() + "/Library/Application Support/fushicho/"
let PAUSED_FLAG = SUPPORT + "paused"            // touch this file to pause the watcher
let NOW_FLAG = SUPPORT + "recover-now"          // created by `fushicho --now`
let STATUS_FILE = SUPPORT + "status.json"

let COMMAND = "/rc"                             // what gets typed into the session
let SETTLE_AFTER_START: TimeInterval = 30       // let the app finish starting before typing
let IDLE_REQUIRED: TimeInterval = 30            // never interrupt someone who is using the Mac
let MAX_TRIES = 2                               // per app relaunch
let TICK: TimeInterval = 30

// The log date must not follow the user's calendar (e.g. Japanese era years).
let stamp: DateFormatter = {
    let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()
func log(_ s: String) { print("\(stamp.string(from: Date())) \(s)"); fflush(stdout) }

// MARK: - Keyboard

let src = CGEventSource(stateID: .hidSystemState)

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}

func typeUnicode(_ s: String) {
    let u = Array(s.utf16)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
        u.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: $0.baseAddress) }
        e?.post(tap: .cghidEventTap)
    }
    usleep(8_000)
}

// With an input method active (Japanese, Chinese, …) typed characters would land in the
// composition buffer, so paste instead and put the clipboard back afterwards.
func typePaste(_ s: String) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents(); pb.setString(s, forType: .string)
        key(9, .maskCommand)                                   // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
            done.signal()
        }
    }
    done.wait()
}

func inputMethodActive() -> Bool {
    guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return false }
    let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    return id.contains(".inputmethod.") && !id.hasSuffix(".Roman")
}

func type(_ s: String) { if inputMethodActive() { typePaste(s) } else { typeUnicode(s) } }

// MARK: - Reading the Claude app log

func axValue(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
}

/// What one log line says about Remote Control, if anything.
func classify(_ line: Substring) -> (state: String, started: Bool, at: Date)? {
    let started = line.contains("[info] Starting app")
    var st: String? = nil
    if started || line.contains("Disabling remote control") { st = "off" }
    else if line.contains("bridge_state: \"connected\"") { st = "connected" }
    else if line.contains("Enabling remote control") || line.contains("Remote control enabled") { st = "on" }
    guard let s = st, line.count >= 19, let d = stamp.date(from: String(line.prefix(19))) else { return nil }
    return (s, started, d)
}

/// Newest Remote Control event at or after `after` (re-reads the tail of the log; used only while recovering).
func newestEvent(after: Date) -> String? {
    guard let h = FileHandle(forReadingAtPath: CLAUDE_LOG) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
    let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let c = classify(line) else { continue }
        return c.at < after.addingTimeInterval(-1) ? nil : c.state
    }
    return nil
}

func waitForEvent(after: Date, timeout: Double) -> String? {
    let until = Date().addingTimeInterval(timeout)
    while Date() < until { if let s = newestEvent(after: after) { return s }; usleep(300_000) }
    return nil
}

/// The session that last had Remote Control switched on or off ("local_…"), from the log.
func lastSession() -> String? {
    for name in ["main.log", "main1.log"] {
        guard let text = try? String(contentsOfFile: CLAUDE_LOG_DIR + name, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").reversed() {
            guard let r = line.range(of: "remote control for session local_") else { continue }
            let id = "local_" + line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            if id.count > 6 && id.count <= 70 { return id }
        }
    }
    return nil
}

/// Follows the log incrementally (only the bytes appended since the last look).
final class Watch {
    private let lock = NSLock()
    private var offset: UInt64 = 0, rest = ""
    private(set) var state = "unknown"          // connected / on / off / unknown
    private(set) var at: Date? = nil
    private(set) var lastStart: Date? = nil
    private(set) var cutByRelaunch = false      // it was on, then the app relaunched, and nobody has touched it since
    private var tries: (start: Date?, count: Int) = (nil, 0)
    private var saidWaiting: Date? = nil

    func refresh() {
        lock.lock(); defer { lock.unlock() }
        guard let h = FileHandle(forReadingAtPath: CLAUDE_LOG) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; rest = "" }             // the log was rotated
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        var lines = (rest + String(decoding: data, as: UTF8.self)).split(separator: "\n", omittingEmptySubsequences: false)
        rest = String(lines.removeLast())                      // keep a half-written last line for next time
        for line in lines {
            guard let c = classify(line) else { continue }
            if c.started {
                if state == "connected" || state == "on" { cutByRelaunch = true }
                lastStart = c.at
            } else { cutByRelaunch = false }                   // the user switched it on or off themselves
            state = c.state; at = c.at
        }
    }

    func snapshot() -> (state: String, at: Date?, cut: Bool, start: Date?) {
        lock.lock(); defer { lock.unlock() }; return (state, at, cutByRelaunch, lastStart)
    }

    /// True when it is time to reconnect (and counts the attempt).
    func shouldRecover() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard cutByRelaunch, state == "off", let start = lastStart else { return false }
        if FileManager.default.fileExists(atPath: PAUSED_FLAG) { return false }
        guard Date().timeIntervalSince(start) >= SETTLE_AFTER_START else { return false }
        if tries.start != start { tries = (start, 0) }
        guard tries.count < MAX_TRIES else { return false }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty else { return false }
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if locked || idle < IDLE_REQUIRED {
            if saidWaiting != start { saidWaiting = start
                log("Remote Control was cut by an app relaunch. Waiting: \(locked ? "the screen is locked" : "the Mac is in use").") }
            return false
        }
        tries.count += 1
        return true
    }
}
let watch = Watch()

// MARK: - Reconnecting

struct Failure: Error { let message: String }

/// Bring the app forward, open the session, type the command, and check the log for the outcome.
func recover() throws -> String {
    guard AXIsProcessTrusted() else { throw Failure(message: "no Accessibility permission (System Settings → Privacy & Security → Accessibility)") }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CLAUDE_BUNDLE) else { throw Failure(message: "the Claude app is not installed") }
    let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty
    let opened = DispatchSemaphore(value: 0)
    let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in opened.signal() }
    _ = opened.wait(timeout: .now() + 30)
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).first else { throw Failure(message: "could not start the Claude app") }
    if !wasRunning { sleep(12) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 1.0)
    func bringForward() -> Bool {
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<60 { if axValue(ax, kAXFrontmostAttribute) as? Bool == true { return true }; usleep(50_000) }
        return false
    }
    guard bringForward() else { throw Failure(message: "could not bring the Claude app to the front") }
    usleep(400_000)

    // After a plain quit-and-reopen the app shows its start screen, where the command does nothing.
    // Open the session that had Remote Control first.
    let session = lastSession() ?? "last"
    if let link = URL(string: "claude://code/continue?session=\(session)&source=desktop_action") {
        NSWorkspace.shared.open(link)
        usleep(2_500_000)
        _ = bringForward()
        usleep(300_000)
    }

    func send() {
        key(0, .maskCommand); usleep(80_000); key(51); usleep(150_000)   // clear any draft: ⌘A, delete
        type(COMMAND)
        // The first Return only picks "/remote-control" from the suggestion list; the second one sends it.
        usleep(400_000); key(36); usleep(700_000); key(36)
    }
    var note = ""
    let t0 = Date()
    send()
    var st = waitForEvent(after: t0, timeout: 5)
    if st == nil { key(36); note += " (+Return)"; st = waitForEvent(after: t0, timeout: 5) }
    // The command is a toggle. If it was actually still on, that just switched it off: send it again.
    if st == "off" {
        note += " (toggled off, sent again)"
        usleep(800_000)
        let t1 = Date(); send()
        st = waitForEvent(after: t1, timeout: 6)
        if st == nil { key(36); note += " (+Return)"; st = waitForEvent(after: t1, timeout: 5) }
    }
    if st == "on" {
        let until = Date().addingTimeInterval(10)
        while Date() < until { if newestEvent(after: t0) == "connected" { st = "connected"; break }; usleep(300_000) }
    }
    let result = st ?? "unknown"
    log("Opened session \(session.prefix(14))… and sent \(COMMAND) → \(result)\(note)")
    return result
}

let work = DispatchQueue(label: "fushicho")
var lastAction = ""

func writeStatus() {
    let s = watch.snapshot()
    let j: [String: Any] = [
        "version": VERSION, "accessibility": AXIsProcessTrusted(),
        "claude_running": !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty,
        "remote_control": s.state, "since": s.at.map { stamp.string(from: $0) } ?? "",
        "cut_by_relaunch": s.cut, "paused": FileManager.default.fileExists(atPath: PAUSED_FLAG),
        "last_action": lastAction, "checked": stamp.string(from: Date()),
    ]
    if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: STATUS_FILE), options: .atomic)
    }
}

func runRecover(_ why: String) {
    work.async {
        log(why)
        do { let r = try recover(); lastAction = "\(stamp.string(from: Date())) \(r)" }
        catch let f as Failure { log("Could not reconnect: \(f.message)"); lastAction = "\(stamp.string(from: Date())) failed: \(f.message)" }
        catch { log("Could not reconnect."); lastAction = "\(stamp.string(from: Date())) failed" }
        watch.refresh(); writeStatus()
    }
}

func tick() {
    watch.refresh()
    if watch.shouldRecover() {
        let started = watch.snapshot().start.map { stamp.string(from: $0) } ?? "?"
        runRecover("The Claude app relaunched at \(started) and Remote Control is off. Reconnecting.")
    }
    writeStatus()
}

// MARK: - Command line

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--version") { print("fushicho \(VERSION)"); exit(0) }
if args.contains("--status") {
    if let d = try? String(contentsOfFile: STATUS_FILE, encoding: .utf8) { print(d) }
    else { print("No status yet. Is the agent running?  (launchctl print gui/$(id -u)/local.fushicho)") }
    exit(0)
}
if args.contains("--now") {
    // Ask the running agent to reconnect right away (it holds the Accessibility permission; this command does not need it).
    try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: NOW_FLAG, contents: nil)
    print("Asked the agent to reconnect now. See: fushicho --status"); exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print("""
    fushicho \(VERSION) — keeps Remote Control alive in the Claude desktop app.
      (no arguments)  run the watcher (this is what the login agent runs)
      --status        show what the agent last saw
      --now           ask the running agent to reconnect right away
      --version
    Pause:  touch "\(PAUSED_FLAG)"      Resume: delete that file.
    """); exit(0)
}

// MARK: - Agent

try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
try? FileManager.default.removeItem(atPath: NOW_FLAG)
let prompt = ProcessInfo.processInfo.environment["FUSHICHO_NOPROMPT"] == nil
let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
log("fushicho \(VERSION) started. Accessibility: \(trusted ? "granted" : "NOT granted — turn it on in System Settings → Privacy & Security → Accessibility")")
watch.refresh()
let first = watch.snapshot()
// Right after the Mac boots, the Claude app has not started yet and the log still ends with the previous run.
// Say so instead of reporting a stale "connected" as if it were current.
let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty
log(appRunning ? "Remote Control is currently: \(first.state)\(first.cut ? " (cut by an app relaunch)" : "")"
               : "The Claude app is not running yet. Last known Remote Control state: \(first.state)")
writeStatus()

Timer.scheduledTimer(withTimeInterval: TICK, repeats: true) { _ in DispatchQueue.global().async { tick() } }
// `fushicho --now` drops a flag file; pick it up quickly.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    guard FileManager.default.fileExists(atPath: NOW_FLAG) else { return }
    try? FileManager.default.removeItem(atPath: NOW_FLAG)
    runRecover("Asked to reconnect now.")
}
RunLoop.main.run()
