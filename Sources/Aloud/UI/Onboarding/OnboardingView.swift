import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var modelManager = ModelManager.shared
    @State private var step = 0
    @State private var accessibilityGranted = PermissionsManager.isTrusted()

    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Aloud")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Select text anywhere, press a hotkey, hear it read aloud.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }

            Text("Step \(step + 1) of 3")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)

            Group {
                switch step {
                case 0: accessibilityStep
                case 1: downloadStep
                default: testStep
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            HStack {
                Spacer()
                Button(primaryButtonTitle, action: advance)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryButtonDisabled)
            }
        }
        .padding(28)
        .frame(width: 380, height: 340)
        .task {
            if modelManager.state != .installed {
                await modelManager.ensureInstalled()
            }
        }
        .task(id: step) {
            guard step == 0 else { return }
            while !accessibilityGranted {
                accessibilityGranted = PermissionsManager.isTrusted()
                if accessibilityGranted { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Aloud needs Accessibility access to read your text selection from other apps.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
            Button("Open System Settings") {
                PermissionsManager.requestAccess()
                PermissionsManager.openAccessibilitySettings()
            }
            if accessibilityGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var downloadStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            switch modelManager.state {
            case .downloading(let label, let written, let total):
                Text("Downloading \(label)…").font(.system(size: 13))
                ProgressView(value: Double(written), total: Double(max(total, 1)))
                    .frame(maxWidth: 240)
                Text("\(byteString(written)) / \(byteString(total))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .verifying:
                Text("Verifying…").font(.system(size: 13))
                ProgressView().frame(maxWidth: 240)
            case .installed:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
                Button("Retry") { Task { await modelManager.ensureInstalled() } }
            case .notInstalled:
                ProgressView().frame(maxWidth: 240)
            }
        }
    }

    private var testStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Let's confirm everything works end-to-end.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
            Button("Say something") {
                AppCoordinator.shared.readText(
                    "Hi, I'm Aloud. Select some text and press your hotkey to hear it."
                )
            }
        }
    }

    private var primaryButtonTitle: String {
        step < 2 ? "Continue" : "Done"
    }

    private var primaryButtonDisabled: Bool {
        switch step {
        case 0: !accessibilityGranted
        case 1: modelManager.state != .installed
        default: false
        }
    }

    private func advance() {
        if step < 2 {
            step += 1
        } else {
            onFinish()
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
