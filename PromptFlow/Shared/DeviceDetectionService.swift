import UIKit

enum CutoutType {
    case dynamicIsland
    case notch
    case none
}

final class DeviceDetectionService {

    static let shared = DeviceDetectionService()

    lazy var cutoutType: CutoutType = detectCutoutType()
    lazy var modelIdentifier: String = getModelIdentifier()

    private init() {}

    private func getModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }

    private func detectCutoutType() -> CutoutType {
        #if targetEnvironment(simulator)
        return detectFromSafeArea()
        #else
        let model = getModelIdentifier()

        // Dynamic Island: iPhone 14 Pro+, 15 series, 16 series, 17 series
        let dynamicIslandModels: Set<String> = [
            "iPhone15,2", "iPhone15,3",         // 14 Pro, 14 Pro Max
            "iPhone15,4", "iPhone15,5",         // 15, 15 Plus
            "iPhone16,1", "iPhone16,2",         // 15 Pro, 15 Pro Max
            "iPhone17,1", "iPhone17,2",         // 16 Pro, 16 Pro Max
            "iPhone17,3", "iPhone17,4",         // 16, 16 Plus
        ]

        // Notch: iPhone X through 14/14 Plus, SE 4
        let notchModels: Set<String> = [
            "iPhone10,3", "iPhone10,6",         // X
            "iPhone11,2", "iPhone11,4", "iPhone11,6", // XS, XS Max
            "iPhone11,8",                       // XR
            "iPhone12,1", "iPhone12,3", "iPhone12,5", // 11, 11 Pro, 11 Pro Max
            "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4", // 12 mini/12/Pro/Pro Max
            "iPhone14,4", "iPhone14,5", "iPhone14,2", "iPhone14,3", // 13 mini/13/Pro/Pro Max
            "iPhone14,7", "iPhone14,8",         // 14, 14 Plus
            "iPhone14,6",                       // SE 3rd gen
            "iPhone17,5",                       // SE 4th gen
        ]

        if dynamicIslandModels.contains(model) {
            return .dynamicIsland
        } else if notchModels.contains(model) {
            return .notch
        } else if model.starts(with: "iPhone") {
            // Future unknown iPhones — assume Dynamic Island
            return .dynamicIsland
        } else {
            return .none
        }
        #endif
    }

    private func detectFromSafeArea() -> CutoutType {
        let topInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0

        if topInset >= 55 { return .dynamicIsland }
        if topInset >= 44 { return .notch }
        return .none
    }
}

// MARK: - Layout configuration per cutout type

struct CutoutLayoutConfig {
    let topPadding: CGFloat         // padding from screen top to container shape start
    let textTopOffset: CGFloat      // text starts this far from container top
    let bottomCornerRadius: CGFloat // bottom corner radius
    let topCornerRadius: CGFloat    // top corner radius (0 = square top)
    let collapsedWidth: CGFloat     // container width when collapsed
    let dragEnabled: Bool           // whether horizontal drag works
    let defaultOffset: CGFloat      // default horizontal position

    static func current(for cutout: CutoutType, screenWidth: CGFloat, safeAreaTop: CGFloat) -> CutoutLayoutConfig {
        switch cutout {
        case .dynamicIsland:
            let topPad: CGFloat = 11
            return CutoutLayoutConfig(
                topPadding: topPad,
                textTopOffset: max(0, safeAreaTop - topPad - 6),
                bottomCornerRadius: 28,
                topCornerRadius: 28,
                collapsedWidth: 126,
                dragEnabled: true,
                defaultOffset: 20
            )
        case .notch:
            return CutoutLayoutConfig(
                topPadding: 0,
                textTopOffset: max(0, safeAreaTop - 6),
                bottomCornerRadius: 28,
                topCornerRadius: 0,
                collapsedWidth: 126,
                dragEnabled: true,
                defaultOffset: 20
            )
        case .none:
            return CutoutLayoutConfig(
                topPadding: 0,
                textTopOffset: 4,
                bottomCornerRadius: 28,
                topCornerRadius: 0,
                collapsedWidth: 126,
                dragEnabled: false,
                defaultOffset: 0
            )
        }
    }
}
