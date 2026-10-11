import SwiftUI
import Observation
import os

// iPhone Duo display state. Resolved from the hinge plus the window's
// reserved regions (occlusion = camera, division = crease), all of which are
// iOS 27.1+ API. Everywhere else — other devices, iOS < 27.1 — `state` stays
// nil and nothing downstream changes.

/// Resolved display state of an iPhone Duo. All frames are in window
/// coordinates, as delivered by `GeometryProxy.reservedRegions` from a
/// full-window reader.
struct DuoDisplayState: Equatable {
    enum Posture: String { case folded, unfolded }
    enum HingeStatus: String { case closed, partiallyOpen, fullyOpen }
    enum Edge: String { case top, leading, bottom, trailing }

    var posture: Posture
    var hingeStatus: HingeStatus
    var windowSize: CGSize
    var lensFrame: CGRect
    /// Window edge nearest to the lens centre.
    var lensEdge: Edge
    /// Division frame as reported, which already includes its margins. Nil when folded.
    var creaseFrame: CGRect?
    var isCreaseActive: Bool
    /// Unfolded: the part of the window on the lens side of `creaseFrame`.
    /// Folded: the whole window.
    var cameraHalf: CGRect

    /// Unfolded: the part of the window across the crease from the lens.
    /// Nil when folded.
    var otherHalf: CGRect? {
        guard let crease = creaseFrame else { return nil }
        let window = CGRect(origin: .zero, size: windowSize)
        if crease.height >= crease.width {
            return cameraHalf.minX >= crease.midX
                ? CGRect(x: 0, y: 0, width: max(0, crease.minX), height: window.height)
                : CGRect(x: crease.maxX, y: 0, width: max(0, window.maxX - crease.maxX), height: window.height)
        }
        return cameraHalf.minY >= crease.midY
            ? CGRect(x: 0, y: 0, width: window.width, height: max(0, crease.minY))
            : CGRect(x: 0, y: crease.maxY, width: window.width, height: max(0, window.maxY - crease.maxY))
    }
}

@MainActor
@Observable
final class DuoDisplayMonitor {
    /// Nil means "not a Duo" (or not resolved yet).
    private(set) var state: DuoDisplayState?
    /// Every occlusion region behind the current `state`, lens included.
    /// Updated only together with `state`, so the two always agree.
    private(set) var occlusionFrames: [CGRect] = []
    /// Latest hinge angle, updated on every hinge callback. Kept out of
    /// `state` so angle jitter neither changes the state nor logs; read only
    /// by the debug overlay.
    private(set) var hingeAngleDegrees: Double = 0
    /// Whether the hinge is closed, straight from the hinge callback; nil
    /// until the first known status. Leads the display switch (opening: by
    /// 170–440 ms; closing: it flips at about 80°, before the window moves),
    /// which `state` cannot, since it waits for the new display's regions.
    /// partiallyOpen and fullyOpen are both "not closed".
    private(set) var isHingeClosed: Bool?

    struct Division: Equatable {
        /// The region's frame, which already includes its margins.
        var frame: CGRect
        var isActive: Bool
    }

    // Raw inputs. Not observed: only the resolved output is.
    @ObservationIgnored private var hasHinge = false
    @ObservationIgnored private var hingeStatus: DuoDisplayState.HingeStatus?
    @ObservationIgnored private var windowSize: CGSize = .zero
    @ObservationIgnored private var occlusions: [CGRect] = []
    @ObservationIgnored private var divisions: [Division] = []

    /// True once any hinge has been reported in this process: the device is a
    /// foldable. For code without the SwiftUI environment — the capture
    /// pipeline, Settings — that needs "is this a Duo" rather than the current
    /// posture. In memory only: a process never moves to another device. False
    /// for roughly the first 2 s after launch, until the first hinge callback.
    nonisolated static var deviceHasHinge: Bool { hingeLatch.withLock { $0 } }
    nonisolated private static let hingeLatch = OSAllocatedUnfairLock(initialState: false)

    /// `status` nil with `present` true means a hinge status this build does
    /// not know; resolution treats it as transitional.
    func updateHinge(present: Bool, status: DuoDisplayState.HingeStatus?, angleDegrees: Double) {
        hasHinge = present
        if present { Self.hingeLatch.withLock { $0 = true } }
        if present, let status {
            let closed = status == .closed
            if isHingeClosed != closed { isHingeClosed = closed }
        }
        hingeStatus = status
        if hingeAngleDegrees != angleDegrees { hingeAngleDegrees = angleDegrees }
        resolve()
    }

    func updateGeometry(windowSize: CGSize, occlusions: [CGRect], divisions: [Division]) {
        self.windowSize = windowSize
        self.occlusions = occlusions
        self.divisions = divisions
        resolve()
    }

    // MARK: - Resolution

    private func resolve() {
        guard hasHinge else {
            commit(nil, occlusions: [])
            return
        }
        // Anything not positively folded or unfolded is transitional: the
        // previous state stands.
        guard let hingeStatus,
              let lens = occlusions.min(by: { $0.width * $0.height < $1.width * $1.height }),
              regionsFitWindow(),
              divisionsMatchWindow() else { return }

        let window = CGRect(origin: .zero, size: windowSize)
        let posture: DuoDisplayState.Posture
        var crease: Division?
        if let division = divisions.first {
            posture = .unfolded
            crease = division
        } else if min(windowSize.width, windowSize.height) < 600 {
            posture = .folded
        } else {
            return
        }

        let cameraHalf = crease.map { Self.half(of: window, beside: $0.frame, containing: lens) } ?? window
        commit(
            DuoDisplayState(
                posture: posture,
                hingeStatus: hingeStatus,
                windowSize: windowSize,
                lensFrame: lens,
                lensEdge: Self.nearestEdge(of: lens, in: windowSize),
                creaseFrame: crease?.frame,
                isCreaseActive: crease?.isActive ?? false,
                cameraHalf: cameraHalf
            ),
            occlusions: occlusions
        )
    }

    /// Right after a display switch the window already has its new size while
    /// the regions still belong to the old display. Regions that do not fit
    /// the window are that stale set, so they are treated as transitional.
    /// Occlusions must lie inside the window; the crease only has to touch
    /// it, since its frame, margins included, may reach past an edge.
    private func regionsFitWindow() -> Bool {
        let window = CGRect(origin: .zero, size: windowSize).insetBy(dx: -1, dy: -1)
        return occlusions.allSatisfy { window.contains($0) }
            && divisions.allSatisfy { window.intersects($0.frame) }
    }

    /// A crease spans the full window along its long side and sits centred
    /// on the other axis, within 1 pt. After a rotation or a fold the window
    /// changes before the regions do, so a crease that fails this belongs to
    /// the previous geometry and the input is transitional.
    private func divisionsMatchWindow() -> Bool {
        divisions.allSatisfy { division in
            let f = division.frame
            if f.height >= f.width {
                return abs(f.height - windowSize.height) <= 1
                    && abs(f.midX - windowSize.width / 2) <= 1
            }
            return abs(f.width - windowSize.width) <= 1
                && abs(f.midY - windowSize.height / 2) <= 1
        }
    }

    private func commit(_ newState: DuoDisplayState?, occlusions: [CGRect]) {
        guard newState != state else { return }
        state = newState
        occlusionFrames = newState == nil ? [] : occlusions
        Self.log(newState)
    }

    // MARK: - Geometry helpers

    private static func nearestEdge(of lens: CGRect, in size: CGSize) -> DuoDisplayState.Edge {
        let distances: [(DuoDisplayState.Edge, CGFloat)] = [
            (.top, lens.midY),
            (.leading, lens.midX),
            (.bottom, size.height - lens.midY),
            (.trailing, size.width - lens.midX),
        ]
        return distances.min(by: { $0.1 < $1.1 })!.0
    }

    /// The part of `window` on the same side of `crease` as the lens. The
    /// crease runs along the window's longer extent of the two, so a tall
    /// crease splits left/right and a wide one splits top/bottom.
    private static func half(of window: CGRect, beside crease: CGRect, containing lens: CGRect) -> CGRect {
        if crease.height >= crease.width {
            if lens.midX < crease.midX {
                return CGRect(x: window.minX, y: window.minY, width: max(0, crease.minX - window.minX), height: window.height)
            }
            return CGRect(x: crease.maxX, y: window.minY, width: max(0, window.maxX - crease.maxX), height: window.height)
        }
        if lens.midY < crease.midY {
            return CGRect(x: window.minX, y: window.minY, width: window.width, height: max(0, crease.minY - window.minY))
        }
        return CGRect(x: window.minX, y: crease.maxY, width: window.width, height: max(0, window.maxY - crease.maxY))
    }

    private static func log(_ state: DuoDisplayState?) {
        guard let s = state else {
            print("[DUO] state=nil")
            return
        }
        print(
            "[DUO] posture=\(s.posture.rawValue) hinge=\(s.hingeStatus.rawValue) window=\(fmt(s.windowSize)) lensFrame=\(fmt(s.lensFrame)) lensEdge=\(s.lensEdge.rawValue) creaseFrame=\(s.creaseFrame.map(fmt) ?? "nil") creaseActive=\(s.isCreaseActive) cameraHalf=\(fmt(s.cameraHalf))"
        )
    }

    static func fmt(_ size: CGSize) -> String {
        String(format: "%.1fx%.1f", size.width, size.height)
    }

    static func fmt(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f,%.1fx%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}

extension DeviceDetectionService {
    /// Duo-aware cutout type: `.duoFolded` / `.duoUnfolded` while a Duo state
    /// is resolved, otherwise the statically detected `cutoutType`.
    func cutoutType(for duoState: DuoDisplayState?) -> CutoutType {
        switch duoState?.posture {
        case .folded: return .duoFolded
        case .unfolded: return .duoUnfolded
        case nil: return cutoutType
        }
    }
}

// MARK: - Feeding

extension View {
    /// Feeds `monitor` from the hinge and the window's reserved regions, and
    /// injects it into the environment. Attach once, at the root.
    func duoDisplayMonitor(_ monitor: DuoDisplayMonitor) -> some View {
        modifier(DuoDisplayMonitorModifier(monitor: monitor))
    }
}

private struct DuoDisplayMonitorModifier: ViewModifier {
    let monitor: DuoDisplayMonitor

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 27.1, *) {
                content.background {
                    // Full-window reader: its coordinate space is the window,
                    // which is what region frames are reported in. A
                    // background never affects the content's layout.
                    GeometryReader { proxy in
                        let input = DuoGeometryInput(proxy)
                        Color.clear
                            .onChange(of: input, initial: true) { _, new in
                                monitor.updateGeometry(
                                    windowSize: new.windowSize,
                                    occlusions: new.occlusions,
                                    divisions: new.divisions
                                )
                            }
                            .onHingeChange { _, new in
                                let hinge = new.hinge
                                monitor.updateHinge(
                                    present: hinge != nil,
                                    status: hinge.flatMap { DuoGeometryInput.status($0.status) },
                                    angleDegrees: hinge?.angle.degrees ?? 0
                                )
                                // Regions can change without the window size
                                // changing; re-read them on every hinge update.
                                let fresh = DuoGeometryInput(proxy)
                                monitor.updateGeometry(
                                    windowSize: fresh.windowSize,
                                    occlusions: fresh.occlusions,
                                    divisions: fresh.divisions
                                )
                            }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            } else {
                content
            }
        }
        .environment(monitor)
        // First sight of each posture and orientation: report it (Duo only).
        .onChange(of: monitor.state) { _, new in
            if new != nil { DuoReportService.scheduleDeviceReport(monitor) }
        }
    }
}

/// One geometry pass's worth of input, read inside the GeometryReader so a
/// change to any of it — size or regions — reaches `onChange`.
@available(iOS 27.1, *)
private struct DuoGeometryInput: Equatable {
    let windowSize: CGSize
    let occlusions: [CGRect]
    let divisions: [DuoDisplayMonitor.Division]

    init(_ proxy: GeometryProxy) {
        windowSize = proxy.size
        // `.includeInactive`: the crease is inactive when fully open and
        // would otherwise vanish from the list.
        occlusions = proxy.reservedRegions(kind: .occlusion, options: [.includeInactive]).map(\.frame)
        divisions = proxy.reservedRegions(kind: .division, options: [.includeInactive]).map { region in
            DuoDisplayMonitor.Division(frame: region.frame, isActive: region.isActive)
        }
    }

    static func status(_ status: DeviceHinge.Status) -> DuoDisplayState.HingeStatus? {
        switch status {
        case .closed: return .closed
        case .partiallyOpen: return .partiallyOpen
        case .fullyOpen: return .fullyOpen
        default: return nil
        }
    }
}
