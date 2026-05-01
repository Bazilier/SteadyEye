import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal

/// Composites the SteadyEye watermark onto each captured video frame in
/// realtime. The watermark CIImage is rendered once at init time via
/// `WatermarkRenderer.renderWatermarkImage`, then composited onto every
/// frame via CISourceOverCompositing on a Metal-backed CIContext.
///
/// Pro users construct with `isPro: true`. Every frame is returned
/// unchanged: no allocation, no GPU work, no CIContext touched.
final class RealtimeWatermarkComposer {
    private let isPro: Bool
    private let renderSize: CGSize
    private let watermarkImage: CIImage?
    private let ciContext: CIContext?
    private var pixelBufferPool: CVPixelBufferPool?

    init(renderSize: CGSize, isPro: Bool) {
        self.renderSize = renderSize
        self.isPro = isPro

        if isPro {
            self.watermarkImage = nil
            self.ciContext = nil
        } else {
            self.watermarkImage = WatermarkRenderer.renderWatermarkImage(renderSize: renderSize)
            // Metal-backed context: the GPU does the SourceOverCompositing
            // blit, encoder gets a BGRA pixel buffer back, all hardware. On
            // the iOS 17+ floor every supported device has a Metal device,
            // so the fallback path is purely defensive.
            if let device = MTLCreateSystemDefaultDevice() {
                self.ciContext = CIContext(mtlDevice: device)
            } else {
                self.ciContext = CIContext(options: nil)
            }
        }
    }

    /// Hands the composer the writer's pixel buffer pool so output frames
    /// reuse encoder-managed buffers instead of allocating per-frame. Must
    /// be called before the first `process(_:)` for free users — the pool
    /// is acquired from `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool`
    /// after the writer's `startWriting()` returns.
    func setPixelBufferPool(_ pool: CVPixelBufferPool) {
        pixelBufferPool = pool
    }

    /// Returns a pixel buffer for the encoder. Pro path: returns the input
    /// unchanged. Free path: composites the cached watermark image over the
    /// input via CISourceOverCompositing, renders into a pool-allocated
    /// BGRA buffer, returns that buffer.
    ///
    /// On allocation or render failure (out-of-memory, pool exhausted),
    /// returns the input buffer so the recording continues without the
    /// watermark for one frame rather than dropping the frame.
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        guard !isPro else { return pixelBuffer }
        guard let watermark = watermarkImage,
              let ciContext = ciContext,
              let pool = pixelBufferPool else {
            return pixelBuffer
        }

        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard status == kCVReturnSuccess, let outputBuffer = output else {
            return pixelBuffer
        }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let composed = watermark.composited(over: inputImage)
        ciContext.render(composed, to: outputBuffer)
        return outputBuffer
    }
}
