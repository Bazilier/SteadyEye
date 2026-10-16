#if DEV
import Combine
import SwiftUI

/// DEV overlay for `GazeProbe`: classifies where the user is looking by
/// nearest calibrated zone, and shows the raw signal so it is visible whether
/// the eyes move the numbers at all.
///
/// Calibrate each zone by looking at it and tapping its button: the next
/// second of readings becomes that zone's centre and spread. No gain or sign
/// guesses — every feature (head yaw/pitch, pupil x/y) is compared in units
/// of its own measured noise, so whatever actually moves wins.
struct GazeProbeOverlay: View {
    @ObservedObject var attention: GazeAttention

    @StateObject private var model = GazeProbeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.verdictColor)
                    .frame(width: 10, height: 10)
                Text(model.verdictText)
                    .font(.caption.bold())
            }
            Text(verbatim: "auto: \(String(describing: attention.state))")
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.7))
            Text(model.detailsText)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize()
            HStack(spacing: 6) {
                ForEach(GazeZone.allCases) { zone in
                    Button {
                        model.calibrate(zone)
                    } label: {
                        Text(model.isCalibrated(zone) ? "\(zone.title) ✓" : zone.title)
                    }
                }
            }
            .font(.caption2.bold())
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(model.calibrating != nil)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onReceive(attention.$reading) { model.ingest($0) }
    }
}

enum GazeZone: String, CaseIterable, Identifiable {
    case lens, face, button
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lens: return "Lens"
        case .face: return "Face"
        case .button: return "Button"
        }
    }
}

@MainActor
private final class GazeProbeModel: ObservableObject {
    /// Feature vector: yaw°, pitch°, pupil x, pupil y, eye opening.
    typealias Features = [Double]

    private struct Centroid {
        var mean: Features
        var spread: Features
    }

    @Published private(set) var smoothed: Features?
    @Published private(set) var calibrating: GazeZone?
    @Published private var centroids: [GazeZone: Centroid] = [:]

    /// ~0.5 s of history at the probe's ~10 Hz; the median drops blinks and
    /// single-frame landmark jumps.
    private var window: [Features] = []
    private static let windowSize = 5
    private var samples: [Features] = []
    /// ~1 s of readings per calibration.
    private static let samplesPerZone = 10
    /// Noise floors per feature, so a zone calibrated perfectly still has a
    /// spread to divide by: 0.5° of head pose, 0.02 of pupil offset.
    private static let spreadFloor: Features = [0.5, 0.5, 0.02, 0.02, 0.01]
    private static let featureCount = 5
    /// Further than this (in noise units) from every zone counts as "away".
    private static let awayDistance: Double = 6

    func ingest(_ reading: GazeProbe.Reading?) {
        guard let r = reading else {
            window.removeAll()
            smoothed = nil
            return
        }
        window.append([r.yaw, r.pitch, r.eyeX, r.eyeY, r.eyeOpen])
        if window.count > Self.windowSize { window.removeFirst() }
        let current = (0..<Self.featureCount).map { i in Self.median(window.map { $0[i] }) }
        smoothed = current

        if let zone = calibrating {
            samples.append(current)
            if samples.count >= Self.samplesPerZone {
                let mean = (0..<Self.featureCount).map { i in samples.map { $0[i] }.reduce(0, +) / Double(samples.count) }
                let spread = (0..<Self.featureCount).map { i -> Double in
                    let values = samples.map { $0[i] }
                    let variance = values.map { ($0 - mean[i]) * ($0 - mean[i]) }.reduce(0, +) / Double(values.count)
                    return max(variance.squareRoot(), Self.spreadFloor[i])
                }
                centroids[zone] = Centroid(mean: mean, spread: spread)
                calibrating = nil
                samples.removeAll()
            }
        }
    }

    func calibrate(_ zone: GazeZone) {
        samples.removeAll()
        calibrating = zone
    }

    func isCalibrated(_ zone: GazeZone) -> Bool { centroids[zone] != nil }

    /// Distance from each calibrated zone, in units of the noise measured
    /// during calibration (pooled across zones, per feature).
    private var distances: [(GazeZone, Double)] {
        guard let f = smoothed, !centroids.isEmpty else { return [] }
        let pooled = (0..<Self.featureCount).map { i in
            centroids.values.map { $0.spread[i] }.max() ?? Self.spreadFloor[i]
        }
        return GazeZone.allCases.compactMap { zone in
            guard let c = centroids[zone] else { return nil }
            var sum = 0.0
            for i in 0..<Self.featureCount {
                let z = (f[i] - c.mean[i]) / pooled[i]
                sum += z * z
            }
            return (zone, sum.squareRoot())
        }
    }

    private var nearest: (GazeZone, Double)? {
        distances.min { $0.1 < $1.1 }
    }

    var verdictColor: Color {
        if smoothed == nil { return .gray }
        guard let (zone, d) = nearest else { return .gray }
        if d > Self.awayDistance { return .red }
        return zone == .lens ? .green : .orange
    }

    var verdictText: String {
        if let zone = calibrating { return "CALIBRATING \(zone.title.uppercased())…" }
        guard smoothed != nil else { return "NO FACE" }
        guard let (zone, d) = nearest else { return "CALIBRATE LENS, FACE, BUTTON" }
        if d > Self.awayDistance { return "AWAY" }
        return zone.title.uppercased()
    }

    var detailsText: String {
        guard let f = smoothed else { return "yaw   —\npitch —\neye x —\neye y —\nopen  —" }
        func deg(_ v: Double) -> String { String(format: "%+6.1f°", v) }
        func eye(_ v: Double) -> String { String(format: "%+6.2f", v) }
        var lines = [
            "yaw   \(deg(f[0]))",
            "pitch \(deg(f[1]))",
            "eye x \(eye(f[2]))",
            "eye y \(eye(f[3]))",
            "open  \(eye(f[4]))",
        ]
        for zone in GazeZone.allCases {
            guard let c = centroids[zone] else { continue }
            let d = distances.first { $0.0 == zone }?.1 ?? 0
            lines.append(String(
                format: "%-6@ d=%4.1f  y %+5.2f  open %4.2f",
                zone.title as NSString, d, c.mean[3], c.mean[4]
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
#endif
