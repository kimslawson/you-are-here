#if METRICS_LOGGING
import Foundation
import MetricKit

/// On-device performance logging for real-world drives — the untethered
/// counterpart to Instruments (see README ▸ Debugging).
///
/// Compiled in only when the `METRICS_LOGGING` Swift flag is set (Debug builds).
/// MetricKit aggregates CPU / memory / location-accuracy / run-time data on the
/// device and delivers it to this registered subscriber — an in-process
/// callback, not a server or file — at most once per ~24h, on a *later* launch.
/// So you drive today and read it tomorrow. Each payload is written to the
/// console (`NSLog`, visible in Xcode's console or Console.app) and its raw
/// JSON is saved to the app's Documents container as a backup.
final class MetricsLogger: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsLogger()

    func start() {
        MXMetricManager.shared.add(self)
        // Payloads already delivered before we subscribed this launch.
        let past = MXMetricManager.shared.pastPayloads
        if past.isEmpty {
            NSLog("[Metrics] Subscribed. No past payloads yet — new ones arrive ~once/24h on a later launch.")
        } else {
            NSLog("[Metrics] Subscribed. \(past.count) past payload(s):")
            past.forEach(logSummary)
        }
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            logSummary(payload)
            persist(payload.jsonRepresentation(), prefix: "metric", date: payload.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persist(payload.jsonRepresentation(), prefix: "diagnostic", date: payload.timeStampEnd)
            NSLog("[Metrics] Saved diagnostic payload (hangs / crashes / disk-write exceptions).")
        }
    }

    // MARK: Console summary — the fields that matter for a GPS wayfinding app

    private func logSummary(_ p: MXMetricPayload) {
        var l = ["── \(p.timeStampBegin) → \(p.timeStampEnd) ──"]
        if let cpu = p.cpuMetrics {
            l.append("CPU time:            \(cpu.cumulativeCPUTime)")
        }
        if let gpu = p.gpuMetrics {
            l.append("GPU time:            \(gpu.cumulativeGPUTime)")
        }
        if let mem = p.memoryMetrics {
            l.append("Peak memory:         \(mem.peakMemoryUsage)")
            l.append("Avg suspended mem:   \(mem.averageSuspendedMemory.averageMeasurement)")
        }
        if let t = p.applicationTimeMetrics {
            l.append("Foreground time:     \(t.cumulativeForegroundTime)")
            l.append("Background time:     \(t.cumulativeBackgroundTime)")
            l.append("Bg audio time (PiP): \(t.cumulativeBackgroundAudioTime)")
            l.append("Bg location time:    \(t.cumulativeBackgroundLocationTime)")
        }
        // The headline for this app: time spent at each GPS accuracy level —
        // exactly the battery lever the RefreshRate setting pulls.
        if let loc = p.locationActivityMetrics {
            l.append("GPS best accuracy:   \(loc.cumulativeBestAccuracyTime)")
            l.append("GPS best-for-nav:    \(loc.cumulativeBestAccuracyForNavigationTime)")
            l.append("GPS ~10 m:           \(loc.cumulativeNearestTenMetersAccuracyTime)")
            l.append("GPS ~100 m:          \(loc.cumulativeHundredMetersAccuracyTime)")
            l.append("GPS ~1 km:           \(loc.cumulativeKilometerAccuracyTime)")
            l.append("GPS ~3 km:           \(loc.cumulativeThreeKilometersAccuracyTime)")
        }
        if let disk = p.diskIOMetrics {
            l.append("Logical disk writes: \(disk.cumulativeLogicalWrites)")
        }
        NSLog("[Metrics]\n  %@", l.joined(separator: "\n  "))
    }

    // MARK: Persist raw JSON to Documents (backup for the console)

    private func persist(_ json: Data, prefix: String, date: Date) {
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("\(prefix)-\(stamp).json")
        do {
            try json.write(to: url)
            NSLog("[Metrics] Saved \(url.lastPathComponent) to Documents.")
        } catch {
            NSLog("[Metrics] Could not save payload: \(error.localizedDescription)")
        }
    }
}
#endif
