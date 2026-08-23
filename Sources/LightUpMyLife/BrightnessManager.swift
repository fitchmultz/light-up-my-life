import AppKit
import Combine

final class BrightnessManager: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            if isEnabled {
                overlayManager.showOverlays(brightness: brightnessMultiplier)
                startWatchdog()
            } else {
                overlayManager.hideOverlays()
                stopWatchdog()
            }
        }
    }

    @Published var brightnessMultiplier: Double {
        didSet {
            let clamped = min(max(brightnessMultiplier, 1.0), maxMultiplier)
            if clamped != brightnessMultiplier {
                brightnessMultiplier = clamped
                return
            }
            UserDefaults.standard.set(brightnessMultiplier, forKey: "brightnessMultiplier")
            if isEnabled {
                overlayManager.updateBrightness(brightnessMultiplier)
            }
        }
    }

    var currentNits: Int {
        Int((500.0 * brightnessMultiplier).rounded())
    }

    var maxNits: Int {
        Int((500.0 * maxMultiplier).rounded())
    }

    func setNits(_ nits: Double) {
        brightnessMultiplier = min(max(nits / 500.0, 1.0), maxMultiplier)
    }

    var boostPercentage: Int {
        Int((brightnessMultiplier - 1.0) * 100.0)
    }

    @Published var isEDRSupported: Bool = false
    @Published var maxMultiplier: Double = 1.0

    private let overlayManager = OverlayManager()
    private var cancellables = Set<AnyCancellable>()
    private var watchdogTimer: Timer?

    init() {
        let savedEnabled = UserDefaults.standard.bool(forKey: "isEnabled")
        let savedMultiplier = UserDefaults.standard.object(forKey: "brightnessMultiplier") == nil
            ? 1.6
            : UserDefaults.standard.double(forKey: "brightnessMultiplier")

        self.isEnabled = false
        self.brightnessMultiplier = savedMultiplier

        checkEDRSupport()
        setupNotifications()

        // Re-check once AppKit has fully settled screen info, then
        // defer enabling to after init completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.checkEDRSupport()
            if savedEnabled && self.isEDRSupported {
                self.isEnabled = true
            }
        }
    }

    /// Re-scan displays for EDR capability. Safe to call any time;
    /// only publishes changes when values actually differ.
    func checkEDRSupport() {
        // Check ALL screens, not just .main — with multiple displays the
        // "main" screen may be a non-EDR external monitor, and at app
        // launch NSScreen.main may not be resolved yet.
        let maxEDR = NSScreen.screens
            .map(\.maximumPotentialExtendedDynamicRangeColorComponentValue)
            .max() ?? 1.0

        let supported = maxEDR > 1.0
        let newMax = min(max(Double(maxEDR), 1.0), 3.2)

        if isEDRSupported != supported { isEDRSupported = supported }
        if maxMultiplier != newMax { maxMultiplier = newMax }

        if brightnessMultiplier > maxMultiplier {
            brightnessMultiplier = maxMultiplier
        }
    }

    private func setupNotifications() {
        // Re-check EDR support when displays change
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.checkEDRSupport()
                if let self = self, self.isEnabled {
                    self.overlayManager.rebuildOverlays(brightness: self.brightnessMultiplier)
                }
            }
            .store(in: &cancellables)

        // Re-apply overlays after wake from sleep
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, self.isEnabled else { return }
                self.overlayManager.rebuildOverlays(brightness: self.brightnessMultiplier)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.overlayManager.hideOverlays()
            }
            .store(in: &cancellables)
    }

    // MARK: - Watchdog

    /// Periodically checks if overlay windows are still alive.
    /// macOS can kill them after sleep/wake or space transitions.
    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }
            self.overlayManager.keepOverlaysVisible()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }
}
