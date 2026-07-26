//
//  OpenTrace.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 25.07.26.
//
//  TEMP diagnostics for the document OPEN path (PerfTrace covers keystrokes only —
//  its frame primitives short-circuit on `active == false`, so an open is currently
//  invisible). One nested trace per open, buffered and printed as a block when the
//  main run loop first goes idle afterwards: printing inline would cost more than
//  the leaves being measured (a `styleCodeBlock` probe fires ~200× per open).
//
//  Runtime-gated, deliberately NOT `#if DEBUG`: Debug is -Onone and inflates the
//  Swift phases (parse, style, regex) roughly 10× while the AppKit/TextKit phases
//  are prebuilt framework code and stay flat — a Debug-only trace therefore
//  systematically over-ranks engine work against TextKit layout.
//
//  ON BY DEFAULT. Silence with MD_OPEN_TRACE=0.
//  ⚠️ Remove before shipping (this file + every `OpenTrace.` call site) — being
//  default-on and not DEBUG-gated, it would otherwise print in a release build.
//

import Foundation

public enum OpenTrace {

    /// ON by default, off via `MD_OPEN_TRACE=0` — the same inverted gate `PerfTrace`
    /// uses. Opt-IN was tried first and silently produced nothing: a scheme
    /// environment variable simply never reached the process, and an unset flag is
    /// indistinguishable from a broken probe. Default-on removes that whole class of
    /// failure. This is why the file must be deleted before shipping.
    public static let enabled: Bool =
        ProcessInfo.processInfo.environment["MD_OPEN_TRACE"] != "0"

    /// Prints once, whatever the outcome, so "no output" can never be ambiguous
    /// between "tracing is off" and "tracing is on but nothing fired".
    /// Uptime at first touch — as close to process start as the engine can observe.
    private static let launchUptime = ProcessInfo.processInfo.systemUptime
    private static var announced = false
    public static func announce(_ site: String) {
        guard !announced else { return }
        announced = true
        let env = ProcessInfo.processInfo.environment["MD_OPEN_TRACE"] ?? "<unset>"
        print("🅾️ OpenTrace \(enabled ? "ARMED" : "OFF") — MD_OPEN_TRACE=\(env) (set 0 to silence) via=\(site)")
    }

    // MARK: - Buffered row model

    private struct Row {
        let id: String
        let depth: Int
        let offset: Double      // ms from trace start — the print order
        var ms: Double
        var selfMs: Double
        var count: Int          // >1 for accumulating rows
        let onMain: Bool
        let detail: String
        let isMark: Bool
    }

    // All span/mark call sites are main-actor by construction; plain static state
    // is safe under the package's Swift 5 mode. Only `heartbeat`/`stallMax` cross
    // threads, and those take the lock.
    private static var open = false
    private static var t0: UInt64 = 0
    private static var rows: [Row] = []
    private static var stack: [(id: String, start: Double, offset: Double, childMs: Double)] = []
    private static var accumIndex: [String: Int] = [:]
    private static var header = ""
    private static var interactiveAt: Double = -1
    private static var idlesSinceInteractive = 0

    // MARK: - Main-thread stall watchdog

    private static let lock = NSLock()
    private static var heartbeat: Double = 0
    private static var stallMax: Double = 0
    private static var observer: CFRunLoopObserver?
    private static var watchdog: DispatchSourceTimer?

    /// CPU time actually burned by the calling thread, in ms. Compared against wall
    /// clock this separates "computing" from "blocked" — the one question a timing
    /// probe alone can never answer, and the reason a 14s span can be a mystery.
    public static func threadCPUms() -> Double {
        var info = thread_basic_info()
        // THREAD_BASIC_INFO_COUNT is a C macro and not imported into Swift.
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                thread_info(mach_thread_self(), thread_flavor_t(THREAD_BASIC_INFO), raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
            + Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
    }

    /// Page faults and resident-memory high-water mark, process-wide.
    public static func faults() -> (minor: Int, major: Int, maxRSSMB: Int) {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return (-1, -1, -1) }
        return (Int(ru.ru_minflt), Int(ru.ru_majflt), Int(ru.ru_maxrss) / 1_048_576)
    }

    @inline(__always) private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    @inline(__always) private static func offsetNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    // MARK: - Trace lifecycle

    /// Opens a trace. A trace already running is NOT restarted (a re-entrant open
    /// would otherwise truncate the one in flight); it is force-closed after 10s.
    public static func beginOpen(_ label: @autoclosure () -> String) {
        announce("beginOpen")
        guard enabled else { return }
        // A trace still in flight is FLUSHED, not discarded: swallowing it would
        // hide exactly the open we were asked to measure.
        if open { end(reason: "superseded") }
        open = true
        t0 = DispatchTime.now().uptimeNanoseconds
        rows.removeAll(keepingCapacity: true)
        stack.removeAll(keepingCapacity: true)
        accumIndex.removeAll(keepingCapacity: true)
        header = label()
        interactiveAt = -1
        idlesSinceInteractive = 0
        generation &+= 1
        let mine = generation
        lock.lock(); heartbeat = now(); stallMax = 0; lock.unlock()
        installWatchdog()
        // Print the header NOW rather than only as part of the final block, so a
        // trace that never reaches its close condition is still visible.
        // `sinceLaunch` matters: the first open of a process is 16× slower than
        // every later one, so the age of the process is part of the measurement.
        header += String(format: "  sinceLaunch=%.1fs", ProcessInfo.processInfo.systemUptime - launchUptime)
        print("🅾️ OPEN begin  \(header)")
        // Guaranteed flush. `markInteractive` closes the trace far sooner on a
        // healthy open; this is what makes "no output at all" impossible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if generation == mine { end(reason: "timeout") }
        }
    }

    /// Bumped per trace so a stale timeout can't close a newer trace.
    private static var generation = 0

    /// True while a trace is collecting. Lets the engine arm a fallback trace when
    /// the embedder's open funnel never fired.
    public static var isOpen: Bool { open }

    /// The heavy synchronous pass is done. The trace closes on the first main-loop
    /// idle AFTER this, so the async post-paint work (wide-table overlays,
    /// code-block selection) still lands inside it.
    public static func markInteractive() {
        guard enabled, open, interactiveAt < 0 else { return }
        interactiveAt = offsetNow()
        // Backstop: if the run loop never reports an idle (busy app, modal loop),
        // print anyway rather than silently swallowing the whole trace.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { end(reason: "interactive+1s") }
    }

    // MARK: - Probes

    /// Time one nested phase. `detail` is an autoclosure — size counters cost
    /// nothing when the trace is off.
    @discardableResult
    public static func span<T>(_ id: String,
                               _ detail: @autoclosure () -> String = "",
                               _ body: () -> T) -> T {
        guard enabled, open else { return body() }
        push(id)
        let result = body()
        pop(id, detail())
        return result
    }

    /// Manual span for a function that has early returns — pair with `defer`:
    ///
    ///     OpenTrace.push("ENG-1 updateNSView")
    ///     defer { OpenTrace.pop("ENG-1 updateNSView", "pass=\(n)") }
    ///
    /// `defer` covers every exit, so no return path can leave the stack unbalanced.
    public static func push(_ id: String) {
        guard enabled, open else { return }
        stack.append((id, now(), offsetNow(), 0))
    }

    /// Closes the innermost span. A mismatched id unwinds to it rather than
    /// corrupting the stack, so a stray `pop` degrades the trace instead of the run.
    public static func pop(_ id: String, _ detail: @autoclosure () -> String = "") {
        guard enabled, open, !stack.isEmpty else { return }
        guard let target = stack.lastIndex(where: { $0.id == id }) else { return }
        // Stop the clock BEFORE building the detail string: several call sites put
        // an `(x as NSString).length` in there, which is O(n) on a 350k-char
        // document and would otherwise be charged to the phase being measured.
        let stop = now()
        let text = detail()
        while stack.count > target {
            let frame = stack.removeLast()
            let ms = stop - frame.start
            if !stack.isEmpty { stack[stack.count - 1].childMs += ms }
            rows.append(Row(id: frame.id, depth: stack.count, offset: frame.offset, ms: ms,
                            selfMs: ms - frame.childMs, count: 1, onMain: Thread.isMainThread,
                            detail: frame.id == id ? text : "(unwound)", isMark: false))
        }
    }

    /// Sums repeated inner work (per code block, per formula, per table) under one
    /// row printed with `×n`, instead of emitting hundreds of rows.
    @discardableResult
    public static func accumulate<T>(_ id: String, _ body: () -> T) -> T {
        guard enabled, open else { return body() }
        let depth = stack.count
        let startOffset = offsetNow()
        let start = now()
        let result = body()
        let ms = now() - start
        if !stack.isEmpty { stack[stack.count - 1].childMs += ms }
        if let i = accumIndex[id] {
            rows[i].ms += ms
            rows[i].selfMs += ms
            rows[i].count += 1
        } else {
            accumIndex[id] = rows.count
            rows.append(Row(id: id, depth: depth, offset: startOffset, ms: ms,
                            selfMs: ms, count: 1, onMain: Thread.isMainThread,
                            detail: "", isMark: false))
        }
        return result
    }

    /// Zero-duration marker (early returns, "this branch fired", counters).
    public static func mark(_ id: String, _ detail: @autoclosure () -> String = "") {
        guard enabled, open else { return }
        rows.append(Row(id: id, depth: stack.count, offset: offsetNow(), ms: 0,
                        selfMs: 0, count: 1, onMain: Thread.isMainThread,
                        detail: detail(), isMark: true))
    }

    /// Attach a size counter to the row a probe already emitted (for numbers only
    /// known after the span closed, e.g. a fragment-count delta).
    public static func annotateLast(_ id: String, _ detail: @autoclosure () -> String) {
        guard enabled, open else { return }
        guard let i = rows.lastIndex(where: { $0.id == id }) else { return }
        let text = detail()
        rows[i] = Row(id: rows[i].id, depth: rows[i].depth, offset: rows[i].offset,
                      ms: rows[i].ms, selfMs: rows[i].selfMs, count: rows[i].count,
                      onMain: rows[i].onMain,
                      detail: rows[i].detail.isEmpty ? text : rows[i].detail + " " + text,
                      isMark: rows[i].isMark)
    }

    // MARK: - Watchdog

    private static func installWatchdog() {
        if observer == nil {
            let obs = CFRunLoopObserverCreateWithHandler(
                nil,
                CFRunLoopActivity.beforeSources.rawValue
                    | CFRunLoopActivity.beforeWaiting.rawValue
                    | CFRunLoopActivity.afterWaiting.rawValue,
                true, 0
            ) { _, activity in
                lock.lock(); heartbeat = now(); lock.unlock()
                // Close on the SECOND idle after the editor became interactive, not
                // the first: the post-paint work (wide-table overlays, code-block
                // selection) is queued with `DispatchQueue.main.async` during the
                // heavy turn, and the first `.beforeWaiting` can arrive before the
                // main queue drains — closing there drops those rows (seen in a
                // smoke run).
                if activity == .beforeWaiting, open, interactiveAt >= 0 {
                    idlesSinceInteractive += 1
                    if idlesSinceInteractive >= 2 { end(reason: "idle") }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
            observer = obs
        }
        if watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "OpenTrace.watchdog"))
            timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            timer.setEventHandler {
                lock.lock()
                let stall = now() - heartbeat
                if stall > stallMax { stallMax = stall }
                lock.unlock()
            }
            timer.resume()
            watchdog = timer
        }
    }

    // MARK: - Report

    private static func end(reason: String) {
        guard enabled, open else { return }
        open = false
        let total = offsetNow()
        lock.lock(); let stall = stallMax; lock.unlock()

        // Spans still on the stack mean an exit path never popped — surface them
        // instead of dropping the rows they would have carried.
        let leaked = stack.map(\.id)
        stack.removeAll(keepingCapacity: true)

        var out = "\n🅾️ OPEN trace  \(header)\n"
        for row in rows.sorted(by: { $0.offset < $1.offset }) {
            let indent = String(repeating: "  ", count: row.depth + 1)
            let name = row.count > 1 ? "\(row.id) (×\(row.count))" : row.id
            // Pad so the ms column lands at a fixed offset no matter how deep the row.
            let width = max(20, 52 - indent.count)
            let padded = name.count < width ? name + String(repeating: " ", count: width - name.count) : name
            if row.isMark {
                out += "\(indent)\(padded)        ·      \(row.detail)\n"
                continue
            }
            var line = indent + padded + String(format: "%9.2fms  ", row.ms) + row.detail
            if row.selfMs < row.ms - 0.05 { line += String(format: "  self=%.2f", row.selfMs) }
            if row.onMain, row.ms > 16.7 { line += String(format: "  ⛔️main+%.0ff", row.ms / 16.7) }
            out += line + "\n"
        }

        let top3 = rows.sorted { $0.selfMs > $1.selfMs }.prefix(3)
            .map { String(format: "%@ %.1f", $0.id, $0.selfMs) }
            .joined(separator: " | ")
        let attributed = rows.filter { $0.depth == 0 }.reduce(0) { $0 + $1.ms }
        out += String(format: "🅾️ OPEN end   total=%.1fms  interactive@=%@  mainStallMax=%.1fms (%.0f frames dropped)  closedBy=%@\n",
                      total,
                      interactiveAt < 0 ? "NEVER" : String(format: "%.1fms", interactiveAt),
                      stall, stall / 16.7, reason)
        if rows.isEmpty {
            out += "   ⚠️ no probes fired — the traced open path was never entered\n"
        } else {
            out += "   top3(self)  \(top3)\n"
            out += String(format: "   depth0Σ=%.1fms  unattributed=%.1fms\n", attributed, total - attributed)
        }
        if !leaked.isEmpty { out += "   ⚠️ unclosed spans: \(leaked.joined(separator: ", "))\n" }
        print(out)
    }
}
