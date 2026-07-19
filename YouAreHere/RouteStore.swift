import Foundation

/// A recorded drive on disk: the full trail plus its segment seams. JSON with
/// ISO-8601 dates, so exports are trivially parseable outside the app too.
struct SavedRoute: Codable {
    var started: Date
    var samples: [TrackSample]
    var pauseMarks: [TimeInterval]
}

/// Persistence for recorded drives: Documents/Routes, one JSON file per
/// session, keyed by the trail's first fix so periodic re-saves overwrite
/// rather than pile up. The engine saves at natural boundaries (park, stop,
/// app background); the Routes list reads, plays back, and deletes.
@MainActor
final class RouteStore {
    static let shared = RouteStore()

    struct Entry: Identifiable {
        let url: URL
        let started: Date
        /// Active (un-parked) length of the drive, seconds.
        let duration: TimeInterval
        let samples: Int
        var id: URL { url }
    }

    private var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Save (or re-save) a session's trail. Skips trails too short to matter.
    func save(_ track: TrackLog) {
        guard let first = track.first, track.samples.count >= 2 else { return }
        let route = SavedRoute(started: first.date, samples: track.samples,
                               pauseMarks: roundedMarks(track.pauseMarks))
        guard let data = try? Self.encoder.encode(route) else { return }
        try? data.write(to: url(for: first.date), options: .atomic)
    }

    /// Tenth-of-a-second is plenty for seam markers (samples land every ~4 s);
    /// raw doubles print 15+ digits in JSON.
    private func roundedMarks(_ marks: [TimeInterval]) -> [TimeInterval] {
        marks.map { ($0 * 10).rounded() / 10 }
    }

    private func url(for started: Date) -> URL {
        directory.appendingPathComponent("route-\(Int(started.timeIntervalSince1970)).json")
    }

    /// All saved routes, newest first. Decodes each file fully — fine at this
    /// scale (a handful of ≤2 MB files); revisit if routes ever accumulate.
    func list() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let route = load(url) else { return nil }
                return Entry(url: url, started: route.started,
                             duration: route.samples.last?.activeTime ?? 0,
                             samples: route.samples.count)
            }
            .sorted { $0.started > $1.started }
    }

    func load(_ url: URL) -> SavedRoute? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SavedRoute.self, from: data)
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Write the trail to a temp file for the share sheet (named, .json, so the
    /// receiving end gets a real document).
    func exportURL(for track: TrackLog) -> URL? {
        guard let first = track.first else { return nil }
        let route = SavedRoute(started: first.date, samples: track.samples,
                               pauseMarks: roundedMarks(track.pauseMarks))
        guard let data = try? Self.encoder.encode(route) else { return nil }
        let name = "YouAreHere-route-\(Int(first.date.timeIntervalSince1970)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
