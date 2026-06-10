//
//  ClaudeStatusManager.swift
//  boringNotch
//
//  Watches Claude Code activity reported by the status hook and exposes an
//  aggregated state for the notch indicator.
//
//  IPC: the hook (~/.claude/hooks/claude-notch-status.sh) writes one JSON file
//  per Claude Code session into this app's sandbox-container tmp dir:
//      <container>/Data/tmp/claude-notch/<session_id>.json
//      {"status":"working|idle|needs-input","cwd":"…","ts":<unix>}
//  Reading the container tmp needs no extra entitlement.
//

import Combine
import CoreServices
import Defaults
import Foundation
import SwiftUI

/// Aggregated Claude Code activity, highest-priority across all live sessions.
enum ClaudeNotchState: Equatable {
    case off          // no live session — indicator hidden
    case working      // busy (prompt submitted / tool running)
    case waiting      // finished a turn, awaiting the next prompt (calm)
    case needsInput   // blocked on a permission / notification (loud)
}

final class ClaudeStatusManager: ObservableObject {
    static let shared = ClaudeStatusManager()

    @Published private(set) var state: ClaudeNotchState = .off

    private let dirURL: URL
    private let queue = DispatchQueue(label: "claude-status", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var staleTimer: Timer?

    // A normal turn clears "working" promptly via Stop→idle. But an *interrupted*
    // turn fires no hook at all, leaving the last "working" write dangling — so we
    // self-heal by expiring "working" after a short idle. During active work, tools
    // fire events every few seconds and keep refreshing it; only a single tool (or
    // generation) that stays silent longer than this clears early.
    private static let workingTTL: TimeInterval = 30
    // "needs-input" is a genuine "come back" — it persists until the next event
    // clears it (or this long safety-net idle).
    private static let needsInputTTL: TimeInterval = 12 * 60 * 60
    // "Done" behaves like a Live Activity: a brief green-checkmark flourish right
    // after a turn ends, then the indicator clears — even with the session still open.
    private static let doneWindow: TimeInterval = 3

    private struct StatusFile: Decodable {
        let status: String
        let ts: Double
    }

    private init() {
        dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        queue.async { [weak self] in self?.recompute() }
        startWatching()

        // FSEvents fires on every status write, so the only thing left to poll is
        // staleness (a crashed session that never wrote Stop/SessionEnd emits no
        // event). A slow, cheap TTL check covers that.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.queue.async { self?.recompute() }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            self.staleTimer = t
        }
    }

    /// Watch the status directory with FSEvents — event-driven, zero work while idle,
    /// and (unlike a DispatchSource vnode watch) it reports in-place file rewrites.
    private func startWatching() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let manager = Unmanaged<ClaudeStatusManager>.fromOpaque(info).takeUnretainedValue()
            manager.queue.async { manager.recompute() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [dirURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // latency (s): coalesce rapid writes
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
        staleTimer?.invalidate()
    }

    private func recompute() {
        guard Defaults[.claudeIndicatorEnabled] else {
            update(.off)
            return
        }

        let now = Date().timeIntervalSince1970
        var best: ClaudeNotchState = .off

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil)) ?? []

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let f = try? JSONDecoder().decode(StatusFile.self, from: data) else { continue }
            let age = now - f.ts
            let mapped: ClaudeNotchState
            switch f.status {
            case "working":     mapped = age <= Self.workingTTL ? .working : .off
            case "needs-input": mapped = age <= Self.needsInputTTL ? .needsInput : .off
            case "idle":        mapped = age <= Self.doneWindow ? .waiting : .off
            default:            mapped = .off
            }
            best = Self.merge(best, mapped)
        }

        update(best)
    }

    /// Priority across sessions: needsInput > working > waiting > off.
    private static func merge(_ a: ClaudeNotchState, _ b: ClaudeNotchState) -> ClaudeNotchState {
        rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ s: ClaudeNotchState) -> Int {
        switch s {
        case .needsInput: return 3
        case .working:    return 2
        case .waiting:    return 1
        case .off:        return 0
        }
    }

    private func update(_ newState: ClaudeNotchState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != newState else { return }
            // Animate the state change so the notch width contracts/expands smoothly
            // (e.g. collapses back to the bare notch when activity ends).
            withAnimation(.smooth(duration: 0.4)) {
                self.state = newState
            }
        }
    }
}

/// Right-side status glyph for the Claude Code live activity in the notch.
/// Mirrors how the music spectrum sits on the right edge of the closed notch.
struct ClaudeStatusIndicator: View {
    let state: ClaudeNotchState
    @State private var pulse = false

    // One Image whose symbol changes by state, so swaps animate via the SF Symbol
    // "replace" content transition instead of a hard cut.
    private var symbolName: String {
        switch state {
        case .working:    return "progress.indicator" // spinning loader
        case .waiting:    return "checkmark"          // finished
        case .needsInput: return "questionmark.circle.fill"
        case .off:        return "checkmark"          // never shown
        }
    }

    // Glyph colour. In needs-input the symbol uses a palette so the "?" stays
    // white while the circle is amber.
    private var primaryColor: Color {
        switch state {
        case .waiting:    return .green
        case .needsInput: return .white   // the "?" glyph
        default:          return .gray
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(state == .needsInput ? .palette : .monochrome)
            .foregroundStyle(primaryColor, .orange) // 2nd colour = amber circle (palette only)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: state == .working)
            // Amber halo adds colored mass to the "needs you" state.
            .shadow(color: state == .needsInput ? .orange.opacity(0.9) : .clear,
                    radius: state == .needsInput ? 4 : 0)
            // Whole-symbol scale pulse: the amber circle and the white "?" grow and
            // shrink together — the "?" never fades or changes colour.
            .scaleEffect(state == .needsInput && pulse ? 1.22 : 1.0)
            .onAppear { applyPulse(for: state) }
            .onChange(of: state) { _, newState in applyPulse(for: newState) }
    }

    private func applyPulse(for state: ClaudeNotchState) {
        if state == .needsInput {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
        }
    }
}
