import SwiftUI

/// The saved-routes browser: most recent first, tap a row to play it back,
/// swipe left to delete (the standard iOS trailing Delete).
struct RoutesListView: View {
    @Environment(\.dismiss) private var dismiss
    /// Start date of the in-progress drive, so its row can be tagged.
    var currentStarted: Date?
    /// Called with the decoded route when the user picks one to play back.
    var onPlay: (SavedRoute) -> Void

    @State private var entries: [RouteStore.Entry] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    Text("No recorded routes yet.\nDrives are saved automatically as you go.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(32)
                } else {
                    List {
                        ForEach(entries) { entry in
                            Button {
                                if let route = RouteStore.shared.load(entry.url) {
                                    onPlay(route)
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.started.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundColor(.primary)
                                    Text("\(Self.durationLabel(entry.duration)) · \(entry.samples) points\(Self.isCurrent(entry.started, currentStarted) ? " · recording now" : "")")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { RouteStore.shared.delete(entries[index].url) }
                            entries = RouteStore.shared.list()
                        }
                    }
                }
            }
            .navigationTitle("Routes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { entries = RouteStore.shared.list() }
        }
    }

    /// Same drive? Saved dates round-trip ISO-8601 (whole seconds) while the
    /// live trail keeps sub-second precision, so compare with tolerance.
    static func isCurrent(_ a: Date, _ b: Date?) -> Bool {
        guard let b else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }

    /// Active driving time, human-shaped: "7 min", "1 h 20 min".
    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(max(1, minutes)) min"
    }
}
