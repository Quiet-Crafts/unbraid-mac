import Foundation
import Observation
import WidgetKit

// Keeps the widgets' snapshot current: written on every setup or connection change and every half-hour, marked no
// longer vouched for when the app quits, and the widgets and controls reloaded only when what they show changed.

extension Snapshot {
    /// This week's bytes per day and route, from the statistics (empty while they are off).
    @MainActor static var weekSource: () async -> [Day] = { [] }
    @MainActor private static var publishing = true
    /// When the snapshot the widgets were last reloaded with was written (see `change`); a launch reloads them at once.
    @MainActor private static var lastReload = Date.distantPast

    /// Quitting, before anything else awaits: no more writes (the loop checks right before each one), and the
    /// snapshot no longer vouched for, so the widgets offer "Open unbraid" rather than buttons only a running app can
    /// act on. Safe to call more than once.
    @MainActor static func retire() {
        publishing = false
        markStale()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// Keeps the widgets' snapshot in step with setup and connection changes; totals refresh every half-hour.
    /// Widgets reload when something they show changed, and in time to keep vouching for a running app.
    @MainActor static func startPublishing() {
        Task {
            var lastWeek = Date.distantPast
            var week: [Day] = []
            var recording: Bool?
            var epoch = -1
            var fetch: (key: String, task: Task<[Day], Never>)?
            while publishing {
                let on = Store.shared.setup.prefs.stats, currentEpoch = Stats.shared.epoch
                if -lastWeek.timeIntervalSinceNow > heartbeat || recording != on || epoch != currentEpoch {
                    // The totals never hold up the heartbeat the widgets' trust depends on: a query still busy after a
                    // minute is left running (and waited for again next time) while the last totals stay.
                    let key = "\(on)|\(currentEpoch)"
                    let task = fetch?.key == key ? fetch!.task : Task { await weekSource() }
                    fetch = (key, task)
                    let finished = await bounded(60, { _ = await task.value })
                    guard on == Store.shared.setup.prefs.stats, currentEpoch == Stats.shared.epoch else { continue }
                    if finished {
                        fetch = nil
                        week = await task.value; recording = on; epoch = currentEpoch; lastWeek = .now
                    } else if recording == on, epoch == currentEpoch {
                        lastWeek = .now // a heartbeat: the last totals still stand
                    } else {
                        // Totals of another setting or of deleted statistics: none shown, and the query is waited for
                        // again right after this write.
                        week = []
                    }
                }
                guard publishing else { return }
                if let written = make(week: week).write(lastReload: lastReload) {
                    lastReload = written
                    WidgetCenter.shared.reloadAllTimelines()
                    ControlCenter.shared.reloadAllControls()
                }
                // Wake on a visible change or when totals are due. Cancel the superseded timeout on every wake.
                var timeout: Task<Void, Never>?
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let once = ResumeOnce(c)
                    withObservationTracking { _ = make(week: week); _ = Stats.shared.epoch } onChange: { once.resume() }
                    timeout = Task {
                        do { try await Task.sleep(for: .seconds(max(0, heartbeat + lastWeek.timeIntervalSinceNow))) } catch { return }
                        once.resume()
                    }
                }
                timeout?.cancel()
                try? await Task.sleep(for: .milliseconds(500)) // coalesce bursts of edits
            }
        }
    }

    @MainActor private static func make(week: [Day]) -> Snapshot {
        let m = AppModel.shared
        let v = m.vpn.state
        return make(phase: v.phase, since: v.phase == .on ? v.since : nil, pausedUntil: v.pausedUntil, failed: v.error != nil,
                    edited: m.setup, running: m.vpn.running, exits: Set(m.vpn.tags.values).count, week: week, profileGeneration: m.profileGeneration,
                    protection: v.phase == .on ? v.runState.protection(blocked: Set(v.blocked.keys)) : nil)
    }
}
