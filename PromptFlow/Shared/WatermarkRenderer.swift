import Foundation
import UIKit
import CoreImage

/// Builds the SteadyEye watermark overlay (a translucent dark pill with
/// app icon + "SteadyEye" text, anchored bottom-right) and rasterizes it
/// to a CIImage for compositing onto each captured video frame at
/// recording time. Used by `RealtimeWatermarkComposer`.
///
/// Visual identity is shared with the previous post-process pipeline: pill
/// geometry, scale-with-resolution behavior, icon asset, font, and color
/// values are unchanged so existing screenshots and Pro-pitch creative
/// remain accurate.
enum WatermarkRenderer {
    private static let watermarkText = "SteadyEye"

    /// Renders the watermark CALayer tree into a transparent CIImage at the
    /// given size. The result is bottom-left origin (matches CIImage and
    /// CVPixelBuffer convention), so compositing it over a captured frame
    /// via CISourceOverCompositing places the pill at the bottom-right of
    /// the frame as intended.
    ///
    /// Returns nil if the requested size is degenerate or a CGContext
    /// cannot be allocated. Caller treats nil as "skip the watermark
    /// composite for this recording" rather than failing the recording.
    static func renderWatermarkImage(renderSize: CGSize) -> CIImage? {
        guard renderSize.width > 0, renderSize.height > 0 else { return nil }

        let parentLayer = makeOverlayLayer(renderSize: renderSize)

        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
              ) else {
            return nil
        }

        // makeOverlayLayer positions the pill with macOS-style coords (y
        // measured from bottom). On iOS, CALayer.render(in:) defaults to
        // UIKit top-left origin; setting isGeometryFlipped on the root
        // restores bottom-left semantics so the pill renders at the bottom
        // and the icon CGImage is right-side up. This is Apple's documented
        // recipe for rendering CA macOS-style hierarchies via
        // CALayer.render on iOS.
        parentLayer.isGeometryFlipped = true
        parentLayer.render(in: context)

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Constructs the watermark layer tree: a dark translucent pill anchored
    /// bottom-right, containing the SteadyEye icon and "SteadyEye" text.
    /// All dimensions scale with the render's short side so the watermark
    /// looks consistent at 1080p and 4K. Sublayer y values are measured
    /// from the pill's bottom; the caller drives the global flip via
    /// isGeometryFlipped on the returned root.
    private static func makeOverlayLayer(renderSize: CGSize) -> CALayer {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        // At a 400px short side the values match the unscaled spec; at
        // 1080p (short side ≥ 1080) the pill is ≈80-100pt tall in render
        // coords.
        let baseDimension = min(renderSize.width, renderSize.height)
        let scale = baseDimension / 400
        let iconSize: CGFloat = 24 * scale
        let horizontalPadding: CGFloat = 12 * scale
        let iconTextGap: CGFloat = 8 * scale
        let verticalPadding: CGFloat = 8 * scale
        let bottomRightMargin: CGFloat = 24 * scale

        let font = UIFont.systemFont(ofSize: 18 * scale, weight: .semibold)
        let measured = (watermarkText as NSString).size(withAttributes: [.font: font])
        let textWidth = ceil(measured.width)
        let textHeight = ceil(measured.height)

        let iconImage = UIImage(named: "Icon")
        let hasIcon = iconImage != nil

        let pillContentWidth: CGFloat = hasIcon
            ? iconSize + iconTextGap + textWidth
            : textWidth
        let pillWidth = horizontalPadding + pillContentWidth + horizontalPadding
        let pillContentHeight: CGFloat = hasIcon ? max(iconSize, textHeight) : textHeight
        let pillHeight = pillContentHeight + 2 * verticalPadding

        let pillLayer = CALayer()
        pillLayer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        pillLayer.cornerRadius = pillHeight / 2
        pillLayer.masksToBounds = true
        pillLayer.frame = CGRect(
            x: renderSize.width - pillWidth - bottomRightMargin,
            y: bottomRightMargin,
            width: pillWidth,
            height: pillHeight
        )

        var contentX: CGFloat = horizontalPadding

        if let iconImage {
            let iconLayer = CALayer()
            iconLayer.contents = iconImage.cgImage
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.cornerRadius = iconSize * 0.22
            iconLayer.masksToBounds = true
            iconLayer.frame = CGRect(
                x: contentX,
                y: (pillHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            pillLayer.addSublayer(iconLayer)
            contentX += iconSize + iconTextGap
        }

        let textLayer = CATextLayer()
        textLayer.string = watermarkText
        textLayer.font = font
        textLayer.fontSize = 18 * scale
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.alignmentMode = .left
        // Hardcoded 3.0 (vs UIScreen.main.scale) because UIScreen is
        // @MainActor in Swift 6 and this method runs off-main on the camera
        // queue. 3.0 matches modern iPhones; @2x devices over-render
        // harmlessly and downsample cleanly into the encoded video.
        textLayer.contentsScale = 3.0
        textLayer.frame = CGRect(
            x: contentX,
            y: (pillHeight - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        pillLayer.addSublayer(textLayer)

        parentLayer.addSublayer(pillLayer)

        return parentLayer
    }
}
