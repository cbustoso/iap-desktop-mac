import AppKit
import CFreeRDPProbe

/// Compile-time proof of the intended adapter boundary. A production implementation
/// would receive the buffer populated by `gdi_init(..., PIXEL_FORMAT_BGRX32)`.
final class FreeRDPFramebufferView: NSView {
    private let framebuffer: FreeRDPFrame

    init(frame: FreeRDPFrame) {
        self.framebuffer = frame
        super.init(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported by this programmatic AppKit spike")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let bytes = framebuffer.bytes,
            let provider = CGDataProvider(
                dataInfo: nil,
                data: bytes,
                size: framebuffer.stride * framebuffer.height,
                releaseData: { _, _, _ in }
            ),
            let image = CGImage(
                width: framebuffer.width,
                height: framebuffer.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: framebuffer.stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ),
            let context = NSGraphicsContext.current?.cgContext
        else { return }

        context.draw(image, in: bounds)
    }
}

let probe = freerdp_probe()
let frame = freerdp_mock_frame()
let view = FreeRDPFramebufferView(frame: frame)

precondition(frame.width == 2 && frame.height == 1 && frame.stride == 8)
precondition(view.frame.size == NSSize(width: 2, height: 1))
print("SPM-C/AppKit framebuffer bridge: OK")
print("FreeRDP headers available: \(probe.headers_available)")
print(String(cString: probe.detail))
