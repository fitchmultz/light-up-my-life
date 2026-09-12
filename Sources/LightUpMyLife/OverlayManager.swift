import AppKit
import CoreGraphics
import MetalKit

final class OverlayManager {
    private struct GammaTable {
        let sampleCount: UInt32
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    private var overlayWindows: [NSScreen: NSWindow] = [:]
    private var renderers: [NSWindow: MetalRenderer] = [:]
    private var originalGammaTables: [CGDirectDisplayID: GammaTable] = [:]
    private var generation = 0
    private let device: MTLDevice?

    init() {
        self.device = MTLCreateSystemDefaultDevice()
    }

    func showOverlays(brightness: Double) {
        hideOverlays()

        guard let device = device else { return }
        generation += 1
        let currentGeneration = generation

        for screen in NSScreen.screens {
            // Only create overlays for EDR-capable screens
            guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0,
                  let displayID = screen.displayID else {
                continue
            }

            saveGammaTable(for: displayID)

            let window = createOverlayWindow(for: screen)
            let mtkView = createMetalView(device: device, in: window)
            let renderer = MetalRenderer(device: device, mtkView: mtkView, brightness: max(brightness, 1.01))
            mtkView.delegate = renderer

            overlayWindows[screen] = window
            renderers[window] = renderer

            window.orderFrontRegardless()
        }

        // The HDR seed must present before macOS accepts >1.0 gamma values.
        for delay in [0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.generation == currentGeneration else { return }
                self.applyGammaToVisibleDisplays(brightness: brightness)
            }
        }
    }

    func hideOverlays() {
        generation += 1
        for (_, window) in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        renderers.removeAll()
        restoreGammaTables()
    }

    func updateBrightness(_ brightness: Double) {
        for (_, renderer) in renderers {
            renderer.brightness = max(brightness, 1.01)
        }
        applyGammaToVisibleDisplays(brightness: brightness)
    }

    func rebuildOverlays(brightness: Double) {
        hideOverlays()
        showOverlays(brightness: brightness)
    }

    func keepOverlaysVisible() {
        overlayWindows.values
            .filter { !$0.isVisible }
            .forEach { $0.orderFrontRegardless() }
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        // Tiny HDR seed window: full-screen HDR/multiply overlays flash white
        // when Mission Control snapshots the display.
        let size: CGFloat = 5
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: size, height: size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.sharingType = .readOnly
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.setFrame(frame, display: true)
        window.contentView?.wantsLayer = true

        return window
    }

    private func createMetalView(device: MTLDevice, in window: NSWindow) -> MTKView {
        let mtkView = MTKView(frame: window.contentView!.bounds, device: device)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.layer?.isOpaque = false
        mtkView.colorPixelFormat = .rgba16Float

        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3_PQ)
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.isOpaque = false
        }

        // Low FPS — we're just filling a solid color, no animation needed
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 10

        window.contentView?.addSubview(mtkView)

        return mtkView
    }

    private func saveGammaTable(for displayID: CGDirectDisplayID) {
        guard originalGammaTables[displayID] == nil else { return }

        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return }

        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0

        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &sampleCount) == .success,
              sampleCount > 0 else { return }

        originalGammaTables[displayID] = GammaTable(
            sampleCount: sampleCount,
            red: Array(red.prefix(Int(sampleCount))),
            green: Array(green.prefix(Int(sampleCount))),
            blue: Array(blue.prefix(Int(sampleCount)))
        )
    }

    private func applyGammaToVisibleDisplays(brightness: Double) {
        for (screen, _) in overlayWindows {
            if let displayID = screen.displayID {
                applyGamma(brightness: brightness, to: displayID)
            }
        }
    }

    private func applyGamma(brightness: Double, to displayID: CGDirectDisplayID) {
        guard let table = originalGammaTables[displayID] else { return }
        let multiplier = gammaMultiplier(for: brightness)
        let outputCount: UInt32 = 256
        let red = boostedGammaTable(from: table.red, multiplier: multiplier, outputCount: Int(outputCount))
        let green = boostedGammaTable(from: table.green, multiplier: multiplier, outputCount: Int(outputCount))
        let blue = boostedGammaTable(from: table.blue, multiplier: multiplier, outputCount: Int(outputCount))
        CGSetDisplayTransferByTable(displayID, outputCount, red, green, blue)
    }

    private func gammaMultiplier(for brightness: Double) -> CGGammaValue {
        let progress = min(max((brightness - 1.0) / 2.2, 0.0), 1.0)
        return CGGammaValue(1.0 + progress * 0.45)
    }

    private func boostedGammaTable(
        from source: [CGGammaValue],
        multiplier: CGGammaValue,
        outputCount: Int
    ) -> [CGGammaValue] {
        guard source.count > 1, outputCount > 1 else { return source.map { $0 * multiplier } }

        return (0..<outputCount).map { index in
            let position = Double(index) * Double(source.count - 1) / Double(outputCount - 1)
            return source[Int(position.rounded())] * multiplier
        }
    }

    private func restoreGammaTables() {
        for (displayID, table) in originalGammaTables {
            CGSetDisplayTransferByTable(displayID, table.sampleCount, table.red, table.green, table.blue)
        }
        originalGammaTables.removeAll()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return deviceDescription[key] as? CGDirectDisplayID
    }
}
