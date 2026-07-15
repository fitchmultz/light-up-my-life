import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: BrightnessManager
    @State private var isEditingNits = false
    @State private var nitsDraft = ""
    @FocusState private var nitsFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            // Sun icon
            sunIconSection

            // Toggle
            toggleSection

            // Nits display
            nitsDisplay

            // Slider
            sliderSection

            // Status bar
            statusBar

            Divider()
                .padding(.top, 12)

            // Quit button
            quitButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(width: 300)
        .onAppear {
            // Screens may have changed (or launch-time detection may have
            // run too early) — re-check every time the popover opens.
            manager.checkEDRSupport()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 4) {
            Text("Light Up My Life")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text("X D R   B R I G H T N E S S")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(2)
        }
    }

    // MARK: - Sun Icon

    private var sunIconSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.15), Color(white: 0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 90, height: 90)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            Image(systemName: "sun.max.fill")
                .font(.system(size: 38))
                .foregroundStyle(
                    manager.isEnabled
                        ? LinearGradient(
                            colors: [Color.yellow, Color.orange],
                            startPoint: .top,
                            endPoint: .bottom
                          )
                        : LinearGradient(
                            colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                          )
                )
                .shadow(color: manager.isEnabled ? .orange.opacity(0.6) : .clear, radius: 12)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.3), value: manager.isEnabled)
        .onTapGesture {
            if manager.isEDRSupported {
                manager.isEnabled.toggle()
            }
        }
    }

    // MARK: - Toggle

    private var toggleSection: some View {
        Toggle(isOn: $manager.isEnabled) {
            Text(manager.isEnabled ? "ON" : "OFF")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(manager.isEnabled ? .primary : .secondary)
        }
        .toggleStyle(AmberToggleStyle())
        .padding(.bottom, 12)
        .disabled(!manager.isEDRSupported)
    }

    // MARK: - Nits Display

    private var nitsDisplay: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            if isEditingNits {
                TextField("", text: $nitsDraft)
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                    .focused($nitsFieldFocused)
                    .onSubmit { finishEditingNits(commit: true) }
                    .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { _ in
                        finishEditingNits(commit: true)
                    }
            } else {
                Text(formattedNits)
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: manager.currentNits)
                    .onTapGesture { startEditingNits() }
            }

            Text("nits")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }

    private var formattedNits: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: manager.currentNits)) ?? "\(manager.currentNits)"
    }

    private func startEditingNits() {
        guard manager.isEDRSupported else { return }
        nitsDraft = "\(manager.currentNits)"
        isEditingNits = true
        nitsFieldFocused = true
    }

    private func finishEditingNits(commit: Bool) {
        guard isEditingNits else { return }
        if commit {
            let value = nitsDraft.replacingOccurrences(of: ",", with: "")
            if let nits = Double(value) {
                manager.setNits(nits)
            }
        }
        isEditingNits = false
        nitsFieldFocused = false
    }

    // MARK: - Slider

    private var sliderSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Slider(
                value: $manager.brightnessMultiplier,
                // Guard against a zero-width range (crashes SwiftUI) when
                // no EDR display is detected (maxMultiplier == 1.0).
                in: 1.0...max(manager.maxMultiplier, 1.01)
            )
            .tint(Color.accentAmber)
            .disabled(!manager.isEnabled)

            Image(systemName: "sun.max.fill")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isEnabled ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)

                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Max \(manager.maxNits) nits")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        if !manager.isEDRSupported {
            return "EDR Not Supported"
        }
        if manager.isEnabled {
            return "EDR Active  \u{00B7}  +\(manager.boostPercentage)%"
        }
        return "EDR Inactive"
    }

    // MARK: - Quit

    private var quitButton: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            Text("Quit")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
