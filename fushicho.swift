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

let VERSION = "0.2.1"
let CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"
let CLAUDE_LOG_DIR = NSHomeDirectory() + "/Library/Logs/Claude/"
let CLAUDE_LOG = CLAUDE_LOG_DIR + "main.log"
let SUPPORT = NSHomeDirectory() + "/Library/Application Support/fushicho/"
let PAUSED_FLAG = SUPPORT + "paused"            // touch this file to pause the watcher
let NOW_FLAG = SUPPORT + "recover-now"          // created by `fushicho --now`
let STATUS_FILE = SUPPORT + "status.json"
let LOG_FILE = NSHomeDirectory() + "/Library/Logs/fushicho.log"
let DAWN_FILE = SUPPORT + "dawn-last"            // the morning relay's last report (fushicho --report)
let SHARE_FILE = SUPPORT + "share-to"            // optional: a folder path; the status is also written there as <Mac name>.json

let COMMAND = "/rc"                             // what gets typed into the session
let SETTLE_AFTER_START: TimeInterval = 30       // let the app finish starting before typing
let IDLE_REQUIRED: TimeInterval = 30            // never interrupt someone who is using the Mac
let MAX_TRIES = 4                               // per app relaunch
let RETRY_AFTER: [TimeInterval] = [0, 60, 180, 600]  // wait this long after the previous try (1 min, 3 min, 10 min)
let TICK: TimeInterval = 30
let STUCK_AFTER_UPDATE: TimeInterval = 600      // the app quit to update and has not come back for this long
let RELAUNCHED_FLAG = SUPPORT + "relaunched-after"  // remembers which update quit was already handled

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

/// One Remote Control event in the app log. Lines that name a session carry its id ("local_…").
enum Event {
    case start(Date)                    // the app (re)started
    case enabling(String, Date)         // Remote Control switched on for a session
    case disabling(String, Date)        // switched off for a session (by the user, or by the toggle)
    case archived(String, Date)         // the session was archived: never bring it back
    case connected(Date)                // the bridge came up (belongs to the last session switched on)
}

func sessionId(_ line: Substring, after marker: String) -> String? {
    guard let r = line.range(of: marker) else { return nil }
    let id = "local_" + line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
    return id.count > 6 && id.count <= 70 ? id : nil
}

func parse(_ line: Substring) -> Event? {
    guard line.count >= 19, let d = stamp.date(from: String(line.prefix(19))) else { return nil }
    if line.contains("[info] Starting app") { return .start(d) }
    if line.contains("Enabling remote control"), let id = sessionId(line, after: "for session local_") { return .enabling(id, d) }
    if line.contains("Disabling remote control"), let id = sessionId(line, after: "for session local_") { return .disabling(id, d) }
    if line.contains("[info] Archived session local_"), let id = sessionId(line, after: "Archived session local_") { return .archived(id, d) }
    if line.contains("bridge_state: \"connected\"") { return .connected(d) }
    return nil
}

func readTail(_ bytes: UInt64 = 300_000) -> [Substring] {
    guard let h = FileHandle(forReadingAtPath: CLAUDE_LOG) else { return [] }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > bytes ? size - bytes : 0)
    let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    return text.split(separator: "\n")
}

/// What happened to one session's Remote Control since `after`: on / connected / off, or nil if nothing yet.
func sessionEvent(_ id: String, after: Date) -> String? {
    var st: String? = nil, mine = false
    for line in readTail() {
        guard let e = parse(line) else { continue }
        switch e {
        case .enabling(let s, let d): mine = (s == id); if mine && d >= after.addingTimeInterval(-1) { st = "on" }
        case .disabling(let s, let d): if s == id && d >= after.addingTimeInterval(-1) { st = "off" }; if s == id { mine = false }
        case .connected(let d): if mine && d >= after.addingTimeInterval(-1) && st != nil { st = "connected" }
        case .start: mine = false
        case .archived: break
        }
    }
    return st
}

/// True when, after the relaunch at `start`, the app selected this session on its own before `before`
/// (it does that while its window is still hidden after an update). Keys typed then do not reach the box.
func selectedWhileHidden(_ session: String, start: Date, before: Date) -> Bool {
    for line in readTail(400_000) {
        guard line.count >= 19, let d = stamp.date(from: String(line.prefix(19))), d >= start, d < before else { continue }
        if line.contains("setFocusedSession: sessionId=\(session)") { return true }
    }
    return false
}

/// Waits for a line in the app log, written at or after `after`, that contains any of `needles`.
func waitForLine(_ needles: [String], after: Date, timeout: Double) -> Bool {
    let until = Date().addingTimeInterval(timeout)
    repeat {
        for line in readTail(150_000) {
            guard line.count >= 19, let d = stamp.date(from: String(line.prefix(19))), d >= after.addingTimeInterval(-1) else { continue }
            if needles.contains(where: { line.contains($0) }) { return true }
        }
        usleep(400_000)
    } while Date() < until
    return false
}

func waitFor(_ id: String, after: Date, timeout: Double) -> String? {
    let until = Date().addingTimeInterval(timeout)
    while Date() < until { if let s = sessionEvent(id, after: after) { return s }; usleep(300_000) }
    return nil
}

// MARK: - The screen

func screenLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
}

/// True when this Mac does not ask for a password after the screen saver or display sleep
/// ("screenLock is off"). Only then may fushicho wake the screen by itself: it is the same as a person
/// touching the mouse. On a Mac that asks for a password it never tries. Checked at most every 10 minutes.
private var lockCheck: (at: Date, free: Bool)? = nil
func passwordFreeLock() -> Bool {
    if let c = lockCheck, Date().timeIntervalSince(c.at) < 600 { return c.free }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl"); p.arguments = ["-screenLock", "status"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    var free = false
    if (try? p.run()) != nil {
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        free = out.contains("screenLock is off")
    }
    lockCheck = (Date(), free)
    return free
}

/// Ends the screen saver the way a person would, with a tap of the Shift key alone (it types nothing).
/// Tested on a Mac that does not ask for a password (2026-10-19): Shift or a click ends it, a pointer move
/// (with or without distance) or a middle click does not. Returns true once the screen is no longer locked.
func wakeScreen() -> Bool {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: down)   // 56 = left Shift
        e?.type = .flagsChanged
        e?.flags = down ? .maskShift : []
        e?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    for _ in 0..<40 { if !screenLocked() { return true }; usleep(150_000) }
    return !screenLocked()
}

/// Follows the log incrementally (only the bytes appended since the last look) and keeps
/// Remote Control state per session, so switching another session on or off never confuses it.
final class Watch {
    private let lock = NSLock()
    private var offset: UInt64 = 0, rest = ""
    private(set) var states: [String: String] = [:]   // session → on / connected / off
    private var changed: [String: Date] = [:]
    private var pending: String? = nil                 // the session whose bridge is coming up
    private(set) var cut: [String] = []                // on before the last relaunch, not back since (newest first)
    private(set) var lastStart: Date? = nil
    private(set) var at: Date? = nil
    private var tries: (start: Date?, count: Int, last: Date?) = (nil, 0, nil)
    private var saidWaiting: Date? = nil

    func apply(_ e: Event) {
        switch e {
        case .start(let d):
            // Sessions still waiting from an earlier relaunch stay on the list: a second relaunch
            // (an update, or the user quitting the app) must not make the agent forget them.
            let now = states.filter { $0.value != "off" }.keys.sorted { (changed[$0] ?? .distantPast) > (changed[$1] ?? .distantPast) }
            cut = now + cut.filter { !now.contains($0) }
            for k in states.keys { states[k] = "off" }
            pending = nil; lastStart = d; at = d
        case .enabling(let id, let d):
            states[id] = "on"; changed[id] = d; pending = id; cut.removeAll { $0 == id }; at = d
        case .disabling(let id, let d):
            states[id] = "off"; changed[id] = d; cut.removeAll { $0 == id }; if pending == id { pending = nil }; at = d
        case .archived(let id, _):
            states[id] = nil; changed[id] = nil; cut.removeAll { $0 == id }; if pending == id { pending = nil }
        case .connected(let d):
            if let p = pending { states[p] = "connected"; changed[p] = d; at = d }
        }
    }

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
        for line in lines { if let e = parse(line) { apply(e) } }
    }

    /// Replays the older, rotated logs (main2.log, main1.log) so a session that was switched on long ago is known.
    func primeFromRotated() {
        for name in ["main2.log", "main1.log"] {
            guard let text = try? String(contentsOfFile: CLAUDE_LOG_DIR + name, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") { if let e = parse(line) { apply(e) } }
        }
        cut = []; lastStart = nil                    // only relaunches seen in main.log count
    }

    /// Overall state for --status: connected if any session is, else on, else off.
    func summary() -> String {
        let v = Set(states.values)
        return v.contains("connected") ? "connected" : v.contains("on") ? "on" : states.isEmpty ? "unknown" : "off"
    }

    func snapshot() -> (state: String, at: Date?, cut: [String], start: Date?, sessions: [String: String]) {
        lock.lock(); defer { lock.unlock() }; return (summary(), at, cut, lastStart, states)
    }

    /// The most recently switched-on session (for --now when nothing was cut).
    func latestOn() -> String? {
        lock.lock(); defer { lock.unlock() }
        return states.filter { $0.value != "off" }.keys.max { (changed[$0] ?? .distantPast) < (changed[$1] ?? .distantPast) }
            ?? changed.keys.max { changed[$0]! < changed[$1]! }
    }

    /// The sessions to reconnect now (and counts the attempt), or nil when it is not time.
    func toRecover() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard !cut.isEmpty, let start = lastStart else { return nil }
        if FileManager.default.fileExists(atPath: PAUSED_FLAG) { return nil }
        guard Date().timeIntervalSince(start) >= SETTLE_AFTER_START else { return nil }
        if tries.start != start { tries = (start, 0, nil) }
        guard tries.count < MAX_TRIES else { return nil }
        if let last = tries.last, Date().timeIntervalSince(last) < RETRY_AFTER[tries.count] { return nil }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty else { return nil }
        // A screen that is "locked" without a password (the screen saver on a Mac set to never ask) is fine:
        // recover() wakes it first. A lock that asks for a password is waited out.
        let locked = screenLocked() && !passwordFreeLock()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if locked || idle < IDLE_REQUIRED {
            if saidWaiting != start { saidWaiting = start
                log("Remote Control was cut by an app relaunch. Waiting: \(locked ? "the screen is locked" : "the Mac is in use").") }
            return nil
        }
        tries.count += 1; tries.last = Date()
        return cut
    }

    /// Stop trying for this relaunch (the keys did not reach the app); the morning relay takes over.
    func giveUp() { lock.lock(); tries.count = MAX_TRIES; lock.unlock() }

    /// True when sessions are still cut and no tries are left for this relaunch: the morning relay's turn.
    func exhausted() -> Bool { lock.lock(); defer { lock.unlock() }; return !cut.isEmpty && tries.start == lastStart && tries.count >= MAX_TRIES }
}
let watch = Watch()

// MARK: - Reconnecting

struct Failure: Error { let message: String }

/// Bring the app forward and, for each session, open it, type the command, and check the log for the outcome.
func recover(_ sessions: [String], checkOpened: Bool = true) throws -> String {
    guard AXIsProcessTrusted() else { throw Failure(message: "no Accessibility permission (System Settings → Privacy & Security → Accessibility)") }
    if screenLocked() {
        guard passwordFreeLock() else { throw Failure(message: "the screen is locked (this Mac asks for a password)") }
        guard wakeScreen() else { throw Failure(message: "could not wake the screen") }
        log("Woke the screen first (this Mac does not ask for a password).")
        usleep(800_000)
    }
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
    let broughtAt = Date()
    guard bringForward() else { throw Failure(message: "could not bring the Claude app to the front") }
    usleep(400_000)

    func send() {
        key(0, .maskCommand); usleep(80_000); key(51); usleep(150_000)   // clear any draft: ⌘A, delete
        type(COMMAND)
        // The first Return only picks "/remote-control" from the suggestion list; the second one sends it.
        usleep(400_000); key(36); usleep(700_000); key(36)
    }
    var results: [String] = []
    for session in sessions {
        var note0 = ""
        // After a relaunch the app shows its start screen or another session; open this one first.
        // Right after an update the app starts with its window hidden; when it is first shown, the page inside
        // is not ready and the link does nothing, so the keys land on the page (2026-10-21). Type only once the
        // app has written that it opened this session; otherwise leave it for the next try.
        var opened = !checkOpened
        // Selected while the window was hidden: go to the new-session screen first, then back, so the app
        // selects it again with the window shown (2026-10-22). The new-session screen creates nothing by itself.
        if checkOpened, let start = watch.snapshot().start, selectedWhileHidden(session, start: start, before: broughtAt),
           let away = URL(string: "claude://code/new?source=desktop_action") {
            NSWorkspace.shared.open(away)
            _ = waitForLine(["setFocusedSession: sessionId=null"], after: Date(), timeout: 5)
            usleep(800_000)
            note0 = " (selected while hidden; reopened)"
        }
        for attempt in 0..<3 {
            guard let link = URL(string: "claude://code/continue?session=\(session)&source=desktop_action") else { break }
            let tl = Date()
            NSWorkspace.shared.open(link)
            if checkOpened {
                opened = waitForLine(["setFocusedSession: sessionId=\(session)", "Warming session \(session)", "Warming up session \(session)"], after: tl, timeout: 8)
            } else { usleep(2_500_000) }
            _ = bringForward()
            usleep(300_000)
            if opened { break }
            if attempt < 2 { sleep(8) }
        }
        if !opened {
            log("Session \(session.prefix(14))… did not open (the app may still be loading). Not typing; will try again later.")
            results.append("not opened")
            continue
        }
        usleep(1_500_000)
        var note = note0
        let t0 = Date()
        send()
        var st = waitFor(session, after: t0, timeout: 5)
        if st == nil { key(36); note += " (+Return)"; st = waitFor(session, after: t0, timeout: 5) }
        // The command is a toggle. If it was actually still on, that just switched it off: send it again.
        if st == "off" {
            note += " (toggled off, sent again)"
            usleep(800_000)
            let t1 = Date(); send()
            st = waitFor(session, after: t1, timeout: 6)
            if st == nil { key(36); note += " (+Return)"; st = waitFor(session, after: t1, timeout: 5) }
        }
        if st == "on" {
            let until = Date().addingTimeInterval(10)
            while Date() < until { if sessionEvent(session, after: t0) == "connected" { st = "connected"; break }; usleep(300_000) }
        }
        if st == nil, checkOpened, !waitForLine(["LocalSessions.sendMessage: sessionId=\(session)", "Enabling remote control for session \(session)"], after: t0, timeout: 0) {
            note += " (nothing reached the app; no more tries for this relaunch)"
            watch.giveUp()
        }
        let result = st ?? "unknown"
        log("Opened session \(session.prefix(14))… and sent \(COMMAND) → \(result)\(note)")
        results.append(result)
    }
    return results.count == 1 ? results[0] : results.joined(separator: ", ")
}

let work = DispatchQueue(label: "fushicho")
var lastAction = ""

var sharedAt = Date.distantPast, sharedBody = ""

func writeStatus() {
    let s = watch.snapshot()
    var j: [String: Any] = [
        "version": VERSION, "accessibility": AXIsProcessTrusted(),
        "claude_running": !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty,
        "remote_control": s.state, "since": s.at.map { stamp.string(from: $0) } ?? "",
        "cut_by_relaunch": !s.cut.isEmpty, "waiting_to_reconnect": s.cut,
        "sessions": s.sessions, "paused": FileManager.default.fileExists(atPath: PAUSED_FLAG),
        "last_action": lastAction,
        // The sessions the morning relay (dawn) should wake by sending a message. Same as waiting_to_reconnect:
        // it also covers a Mac whose screen asks for a password, where fushicho itself cannot type.
        "dawn_needed": s.cut, "dawn_last": ((try? String(contentsOfFile: DAWN_FILE, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        "mac": Host.current().localizedName ?? "",
    ]
    // Optional shared copy (e.g. a synced folder), so one place shows every Mac. Written when something
    // changes, or every 15 minutes, not on every check.
    if let dir = (try? String(contentsOfFile: SHARE_FILE, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty,
       let body = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
        let text = String(decoding: body, as: UTF8.self)
        if text != sharedBody || Date().timeIntervalSince(sharedAt) > 900 {
            var k = j; k["checked"] = stamp.string(from: Date())
            if let d = try? JSONSerialization.data(withJSONObject: k, options: [.prettyPrinted, .sortedKeys]) {
                let name = (Host.current().localizedName ?? "mac").replacingOccurrences(of: "/", with: "-")
                if (try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".json"), options: .atomic)) != nil {
                    sharedBody = text; sharedAt = Date()
                }
            }
        }
    }
    j["checked"] = stamp.string(from: Date())
    if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: STATUS_FILE), options: .atomic)
    }
}

func runRecover(_ why: String, _ sessions: [String], checkOpened: Bool = true) {
    work.async {
        log(why)
        do { let r = try recover(sessions, checkOpened: checkOpened); lastAction = "\(stamp.string(from: Date())) \(r)" }
        catch let f as Failure { log("Could not reconnect: \(f.message)"); lastAction = "\(stamp.string(from: Date())) failed: \(f.message)" }
        catch { log("Could not reconnect."); lastAction = "\(stamp.string(from: Date())) failed" }
        watch.refresh()
        if watch.exhausted() { log("No tries left for this relaunch. Leaving it to the morning relay (dawn).") }
        watch.refresh(); writeStatus()
    }
}

/// When the app quit to install an update, the time of that quit, if it has not started again since.
/// A plain quit (⌘Q, or quitting from the menu) writes no "beforeQuitForUpdate" line, so it never counts.
func updateQuitWithoutStart() -> Date? {
    var quit: Date? = nil
    for line in readTail() {
        guard line.count >= 19, let d = stamp.date(from: String(line.prefix(19))) else { continue }
        if line.contains("[info] Starting app") { quit = nil }
        else if line.contains("beforeQuitForUpdate handler fired"), quit == nil { quit = d }
    }
    return quit
}

/// If the app went down for an update and never came back, start it once. Only when the Mac is left alone,
/// only once per update, and never after a plain quit.
func relaunchIfStuck() {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty,
          !FileManager.default.fileExists(atPath: PAUSED_FLAG),
          let quit = updateQuitWithoutStart(), Date().timeIntervalSince(quit) >= STUCK_AFTER_UPDATE else { return }
    let mark = stamp.string(from: quit)
    if (try? String(contentsOfFile: RELAUNCHED_FLAG, encoding: .utf8)) == mark { return }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    guard idle >= STUCK_AFTER_UPDATE, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CLAUDE_BUNDLE) else { return }
    try? mark.write(toFile: RELAUNCHED_FLAG, atomically: true, encoding: .utf8)
    log("The Claude app quit to update at \(mark) and has not come back. Starting it (once for this update).")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
        if let err { log("Could not start the Claude app: \(err.localizedDescription)") }
    }
}

func tick() {
    relaunchIfStuck()
    watch.refresh()
    if let sessions = watch.toRecover() {
        let started = watch.snapshot().start.map { stamp.string(from: $0) } ?? "?"
        runRecover("The Claude app relaunched at \(started) and Remote Control is off for \(sessions.count) session(s). Reconnecting.", sessions)
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
if args.contains("--explain") {
    // Replays the app log and shows, for each relaunch, which sessions would be reconnected.
    let w = Watch()
    w.primeFromRotated()
    if let text = try? String(contentsOfFile: CLAUDE_LOG, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            guard let e = parse(line) else { continue }
            w.apply(e)
            if case .start(let d) = e {
                let c = w.snapshot().cut
                print("\(stamp.string(from: d))  relaunch → reconnect: \(c.isEmpty ? "(nothing)" : c.map { String($0.prefix(14)) + "…" }.joined(separator: ", "))") }
        }
    }
    exit(0)
}
if let i = args.firstIndex(of: "--report") {
    // The morning relay (dawn) reports what it did, so fushicho's log tells the whole story.
    let text = args.dropFirst(i + 1).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
    guard !text.isEmpty else { print("Usage: fushicho --report \"what the morning relay did\""); exit(1) }
    let line = "\(stamp.string(from: Date())) [dawn] \(text)\n"
    if let h = FileHandle(forWritingAtPath: LOG_FILE) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: LOG_FILE, atomically: true, encoding: .utf8) }
    try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
    try? "\(stamp.string(from: Date())) \(text)".write(toFile: DAWN_FILE, atomically: true, encoding: .utf8)
    print("Reported."); exit(0)
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
      --report TEXT   record what the morning relay (a scheduled Claude task) did, in fushicho's log
      --version
    Pause:  touch "\(PAUSED_FLAG)"      Resume: delete that file.
    """); exit(0)
}
if !args.isEmpty {
    // Anything else (a typo such as "status" without the dashes) must not start a second watcher.
    print("Unknown option: \(args.joined(separator: " "))  See: fushicho --help"); exit(2)
}

// MARK: - Agent

try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true)
try? FileManager.default.removeItem(atPath: NOW_FLAG)
let prompt = ProcessInfo.processInfo.environment["FUSHICHO_NOPROMPT"] == nil
let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
log("fushicho \(VERSION) started. Accessibility: \(trusted ? "granted" : "NOT granted — turn it on in System Settings → Privacy & Security → Accessibility")")
watch.primeFromRotated()
watch.refresh()
let first = watch.snapshot()
// Right after the Mac boots, the Claude app has not started yet and the log still ends with the previous run.
// Say so instead of reporting a stale "connected" as if it were current.
let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: CLAUDE_BUNDLE).isEmpty
log(appRunning ? "Remote Control is currently: \(first.state)\(first.cut.isEmpty ? "" : " (cut by an app relaunch: \(first.cut.count) session(s))")"
               : "The Claude app is not running yet. Last known Remote Control state: \(first.state)")
writeStatus()

Timer.scheduledTimer(withTimeInterval: TICK, repeats: true) { _ in DispatchQueue.global().async { tick() } }
// `fushicho --now` drops a flag file; pick it up quickly.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    guard FileManager.default.fileExists(atPath: NOW_FLAG) else { return }
    try? FileManager.default.removeItem(atPath: NOW_FLAG)
    let s = watch.snapshot().cut
    let targets = s.isEmpty ? (watch.latestOn().map { [$0] } ?? []) : s
    if targets.isEmpty { log("Asked to reconnect now, but no session has had Remote Control yet."); return }
    runRecover("Asked to reconnect now.", targets, checkOpened: false)
}
RunLoop.main.run()
