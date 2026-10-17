import AVFoundation
import UIKit

/// Captions drawn into the exported frames, laid out as the preview lays
/// them out (`SubtitleStyle`): one text layer per caption, shown for its
/// time.
nonisolated enum SubtitleBurnIn {

    static func videoComposition(for composition: AVComposition, phrases: [SubtitlePhrase]) async throws -> AVVideoComposition {
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        let size = videoComposition.renderSize

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        // Top-left origin, as in UIKit.
        parent.isGeometryFlipped = true
        let video = CALayer()
        video.frame = parent.bounds
        parent.addSublayer(video)

        let fontSize = size.width * SubtitleStyle.fontSizeOfWidth
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let maxWidth = size.width * SubtitleStyle.maxWidthOfWidth

        for phrase in phrases where phrase.end > phrase.start {
            let text = NSAttributedString(string: phrase.text, attributes: [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ])
            let bounds = text.boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let height = ceil(bounds.height) + fontSize * 0.2
            let layer = CATextLayer()
            layer.string = text
            layer.isWrapped = true
            layer.alignmentMode = .center
            layer.contentsScale = 1
            layer.frame = CGRect(
                x: (size.width - maxWidth) / 2,
                y: size.height * (1 - SubtitleStyle.bottomInsetOfHeight) - height,
                width: maxWidth,
                height: height
            )
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.85
            layer.shadowRadius = fontSize * 0.08
            layer.shadowOffset = .zero
            layer.opacity = 0

            let shown = CABasicAnimation(keyPath: "opacity")
            shown.fromValue = 1
            shown.toValue = 1
            shown.beginTime = AVCoreAnimationBeginTimeAtZero + phrase.start
            shown.duration = phrase.end - phrase.start
            shown.isRemovedOnCompletion = true
            layer.add(shown, forKey: "shown")
            parent.addSublayer(layer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: video, in: parent
        )
        return videoComposition
    }
}
