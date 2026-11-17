import AppIntents
import SwiftUI
import WidgetKit

// The widget extension: the status widget in three sizes and the Control Center controls (Connect or Pause, and
// the first three profiles). Widgets only read the snapshot the app publishes; a button writes a request the app
// carries out (see WidgetActions in the app).

@main
struct UnbraidWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        ProfileControl<ProfileSlot1>()
        ProfileControl<ProfileSlot2>()
        ProfileControl<ProfileSlot3>()
        ConnectionControl()
    }
}

/// Connection state with one action; medium adds the routes, large adds this week's data per route.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: Provider()) { WidgetView(s: $0.snapshot, live: $0.snapshot.fresh(at: $0.date)) }
            .configurationDisplayName("unbraid")
            .description("Connected, paused or off, your routes, and one button to connect, pause or resume.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    var date = Date.now
    var snapshot: Snapshot
}

/// The app writes a new snapshot and reloads the widgets on every change, and in time to keep vouching for itself, so
/// one entry is enough; a pause that ends on its own gets an entry at its resume time, and the moment the app stops
/// vouching for the snapshot one that says "Open unbraid" (Snapshot.timeline).
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(snapshot: Snapshot(phase: .on, exits: 3, updated: .now)) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(snapshot: Snapshot.read())) }
    /// Read again on their own only when the app didn't reload them in time (Snapshot.nextRead).
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let s = Snapshot.read()
        let entries = s.timeline(now: now).map { Entry(date: $0.date, snapshot: $0.snapshot) }
        completion(Timeline(entries: entries, policy: .after(s.nextRead(now: now))))
    }
}

// WidgetView, the status widget's face, is in Shared/WidgetView.swift: the app's test copy draws it for pictures.

struct ControlSnapshotProvider: ControlValueProvider {
    var previewValue: Snapshot { Snapshot() }
    func currentValue() async throws -> Snapshot { Snapshot.read() }
}

protocol ProfileSlot { static var index: Int { get } }
struct ProfileSlot1: ProfileSlot { static let index = 0 }
struct ProfileSlot2: ProfileSlot { static let index = 1 }
struct ProfileSlot3: ProfileSlot { static let index = 2 }

struct ProfileControl<Slot: ProfileSlot>: ControlWidget {
    let slot = Slot.index
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "profile-\(slot)", provider: ControlSnapshotProvider()) { snapshot in
            let profile = WidgetAction.profileSlot(slot, names: snapshot.profiles, generation: snapshot.profileGeneration)
            let name = profile?.name ?? "No profile"
            ControlWidgetButton(action: SwitchProfileIntent(profile: ProfileEntity(id: name, generation: profile?.generation ?? ""))) {
                Label(name, systemImage: "person.crop.square")
            }
            .disabled(profile == nil)
            .tint(Palette.accent)
        }
        .displayName("Profile \(slot + 1)")
        .description("Switch to a saved profile.")
    }
}

struct ConnectionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "connection", provider: ControlSnapshotProvider()) { snapshot in
            // A snapshot no running app keeps fresh says nothing about now: Connect (macOS launches unbraid for it), never Pause.
            let on = snapshot.phase == .on && snapshot.fresh(at: .now)
            ControlWidgetButton(action: ConnectPauseIntent()) {
                Label(on ? "Pause" : "Connect", systemImage: on ? "pause.fill" : "power")
            }
            .tint(Palette.accent)
        }
        .displayName("Connect or Pause")
        .description("Connect or pause unbraid for 15 minutes.")
    }
}
