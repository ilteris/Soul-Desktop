import Foundation
import Observation
import SwiftUI

/// Environment key for the AppShell-owned AutoCompactController. ThreadView
/// reads `\.autoCompactController` to surface the "Compacting…" banner
/// without a new initializer argument.
private struct AutoCompactControllerKey: EnvironmentKey {
    static let defaultValue: AutoCompactController? = nil
}

extension EnvironmentValues {
    var autoCompactController: AutoCompactController? {
        get { self[AutoCompactControllerKey.self] }
        set { self[AutoCompactControllerKey.self] = newValue }
    }
}

/// Provider-side context compaction dispatcher (desktop half).
///
/// Watches `ContextUsage.fraction` and, when it crosses a threshold,
/// shells out to `soul autocompact` for a directive. The kernel owns
/// the policy (which command, threshold, debounce, audit); this layer
/// just translates a directive into UI/ACP action.
///
/// One instance per active thread. Held on the AppShell so its lifetime
/// matches the thread the user is looking at; resets cleanly across
/// sidebar switches.
@MainActor
@Observable
final class AutoCompactController {
    /// Soft toast surfaced when a provider has no native compact
    /// (Codex, Pi) but its context window is filling. The user picks
    /// a branch target or dismisses.
    struct Toast: Identifiable, Equatable {
        let id: UUID = UUID()
        let provider: Provider
        let message: String
        let actions: [Action]

        struct Action: Equatable, Hashable {
            let label: String
            let provider: Provider
        }
    }

    /// Visible to AppShell so it can overlay a toast view. nil ⇒ nothing
    /// to show.
    var pendingToast: Toast? = nil

    /// Brief banner string shown above the composer while a `/compact`
    /// dispatch is in flight. Cleared once the next agent message lands
    /// (handled by ComposerView observing this).
    var banner: String? = nil

    /// Local debounce — defense in depth alongside the kernel's 60s
    /// window. Prevents us from even shelling out if we just fired.
    @ObservationIgnored private var lastEvaluation: Date = .distantPast
    @ObservationIgnored private var lastEvaluatedFraction: Double = 0
    @ObservationIgnored private var inFlight: Bool = false

    /// Master enable flag. Mirrors `defaults read Soul-Desktop soul.autocompact.enabled`
    /// at instance creation. ⌘⇧K still works when this is false.
    @ObservationIgnored private let enabled: Bool

    init() {
        let key = "soul.autocompact.enabled"
        // CFPreferences returns nil if never set — default ON.
        if let raw = CFPreferencesCopyAppValue(key as CFString, kCFPreferencesCurrentApplication) as? Bool {
            self.enabled = raw
        } else {
            self.enabled = true
        }
    }

    /// Called by AppShell on every contextUsage fraction change.
    /// Cheap fast-path: no shell-out unless threshold + interval gates
    /// pass.
    func evaluate(thread: ThreadController, usage: ContextUsage) {
        guard enabled else { return }
        // Refuse to auto-fire on estimated signals — Pi byte-counts and
        // Gemini fallback would both trip a wrong threshold.
        guard !usage.isEstimate else { return }
        let frac = usage.fraction
        // Local short-window debounce. The kernel enforces 60s globally;
        // this trims redundant shell-outs while usage hovers around the
        // threshold.
        let now = Date()
        guard now.timeIntervalSince(lastEvaluation) >= 5 else { return }
        // Only fire on upward crossing of 0.50 — don't re-fire on every
        // additional 0.01 above. The kernel will also debounce, but
        // skipping the shell-out here keeps the trace clean. The 0.95
        // re-arm is a safety net: if usage somehow climbs that high
        // without a compact landing (debounced, errored), try again.
        guard frac >= 0.50, lastEvaluatedFraction < 0.50 || frac >= 0.95 else {
            lastEvaluatedFraction = frac
            return
        }
        lastEvaluation = now
        lastEvaluatedFraction = frac
        dispatch(thread: thread, usagePct: frac, force: false)
    }

    /// Manual trigger (⌘⇧K). Bypasses threshold + debounce on both ends
    /// (sets --force) so the user can compact whenever they want.
    func forceCompact(thread: ThreadController, usage: ContextUsage?) {
        let pct = usage?.fraction ?? 0.0
        dispatch(thread: thread, usagePct: pct, force: true)
    }

    func dismissToast() {
        pendingToast = nil
    }

    // MARK: - Internals

    private func dispatch(thread: ThreadController, usagePct: Double, force: Bool) {
        guard !inFlight else { return }
        guard let sid = thread.sessionId else { return }
        let project = thread.project.id
        let provider = thread.provider.rawValue
        inFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let directive = await Self.callKernel(
                session: sid,
                project: project,
                provider: provider,
                usagePct: usagePct,
                force: force
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard let directive else { return }
                self.executeDirective(directive, on: thread)
            }
        }
    }

    private static func callKernel(
        session: String,
        project: String,
        provider: String,
        usagePct: Double,
        force: Bool
    ) async -> Directive? {
        let soulBin = ("~/dotfiles/soul/bin/soul" as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: soulBin) else {
            NSLog("[autocompact] missing or non-exec kernel binary at \(soulBin)")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: soulBin)
        var args = [
            "autocompact",
            "--session", session,
            "--project", project,
            "--provider", provider,
            "--usage-pct", String(format: "%.4f", usagePct),
        ]
        if force { args.append("--force") }
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently while the process runs. Without this
        // the child blocks at ~64KB of stderr output and waitUntilExit() never
        // returns. The kernel verb itself is quiet, but a Python traceback
        // could exceed the buffer; better to be safe.
        var outData = Data()
        var errData = Data()
        let drainQueue = DispatchQueue(label: "soul.autocompact.drain", attributes: .concurrent)
        let outGroup = DispatchGroup()
        let errGroup = DispatchGroup()
        outGroup.enter()
        errGroup.enter()
        drainQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }
        drainQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }

        NSLog("[autocompact] spawning: %@ %@", soulBin, args.joined(separator: " "))
        do {
            try process.run()
        } catch {
            NSLog("[autocompact] kernel spawn failed: \(error)")
            return nil
        }

        // Bound the wait so a hung kernel can't leave inFlight=true forever.
        // 5s is generous — the verb is pure stdlib + filesystem reads.
        let deadline = DispatchTime.now() + .seconds(5)
        let waitTask = DispatchWorkItem {
            process.waitUntilExit()
        }
        drainQueue.async(execute: waitTask)
        if waitTask.wait(timeout: deadline) == .timedOut {
            NSLog("[autocompact] kernel call timed out — terminating")
            process.terminate()
            _ = outGroup.wait(timeout: .now() + .seconds(1))
            _ = errGroup.wait(timeout: .now() + .seconds(1))
            return nil
        }
        _ = outGroup.wait(timeout: .now() + .seconds(1))
        _ = errGroup.wait(timeout: .now() + .seconds(1))

        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            NSLog("[autocompact] kernel exit %d — stderr: %@", Int(process.terminationStatus), errText)
            return nil
        }
        let directive = Directive.parse(outData)
        if directive == nil {
            let raw = String(data: outData, encoding: .utf8) ?? ""
            NSLog("[autocompact] could not parse directive — stdout: %@", raw)
        }
        return directive
    }

    private func executeDirective(_ directive: Directive, on thread: ThreadController) {
        switch directive {
        case .sendSlash(let command, let bannerText):
            banner = bannerText
            // Clear the banner once the agent produces its next message —
            // cheapest signal that the compact ran.
            scheduleBannerClear(thread: thread)
            Task { @MainActor in
                await thread.send(command)
            }
        case .showToast(let toast):
            pendingToast = toast
        case .skip:
            break
        }
    }

    private func scheduleBannerClear(thread: ThreadController) {
        // 8s ceiling so a silent compact doesn't pin the banner forever.
        // ComposerView clears it sooner when isWorking flips back to false
        // after the compact returns.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            self?.banner = nil
        }
    }
}

// MARK: - Directive parsing

extension AutoCompactController {
    enum Directive {
        case sendSlash(command: String, banner: String)
        case showToast(Toast)
        case skip(reason: String)

        static func parse(_ data: Data) -> Directive? {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = obj["action"] as? String
            else { return nil }
            switch action {
            case "send_slash":
                guard let cmd = obj["command"] as? String else { return nil }
                let banner = (obj["banner"] as? String) ?? "Compacting…"
                return .sendSlash(command: cmd, banner: banner)
            case "show_toast":
                let message = (obj["message"] as? String) ?? "Context filling — consider branching"
                let actions = (obj["actions"] as? [[String: Any]]) ?? []
                let parsedActions: [Toast.Action] = actions.compactMap { dict in
                    guard let label = dict["label"] as? String,
                          let providerRaw = dict["provider"] as? String,
                          let provider = Provider(rawValue: providerRaw)
                    else { return nil }
                    return Toast.Action(label: label, provider: provider)
                }
                // The toast's `provider` is whichever the session is using
                // right now — kernel doesn't tell us, but the directive
                // implies it via the action set. We don't strictly need
                // it for rendering; pass .codex as a placeholder if we
                // can't infer.
                let provider: Provider = .codex
                return .showToast(Toast(provider: provider, message: message, actions: parsedActions))
            case "skip":
                let reason = (obj["reason"] as? String) ?? "unknown"
                return .skip(reason: reason)
            default:
                return nil
            }
        }
    }
}
