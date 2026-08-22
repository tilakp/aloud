import SwiftUI
import AppKit
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    // Observed directly (not read through `coordinator.settings`) because
    // AppCoordinator doesn't re-publish when the nested SettingsStore's own
    // @Published properties change — without this, the speed stepper and
    // login toggle would mutate the model but never visually update.
    @ObservedObject private var settings = SettingsStore.shared
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Text("Settings")
                    .font(.system(size: 14, weight: .bold))
            }

            // Only the voice list scrolls — with 28 voices there's no
            // fixed height that avoids scrolling there entirely, but
            // everything else (hotkey, speed, toggle, permission, model,
            // quit) stays outside the scroll so it's always visible
            // without having to scroll past the voice grid to reach it.
            voiceCard

            VStack(spacing: 0) {
                SettingRow(icon: "keyboard.fill", label: "Read selection") {
                    KeyboardShortcuts.Recorder(for: .readSelection)
                        .controlSize(.small)
                }
                SettingRow(icon: "speedometer", label: "Default speed") {
                    Stepper(value: $settings.speed, in: 0.5...2.0, step: 0.1) {
                        Text(String(format: "%.1f×", settings.speed))
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                SettingRow(icon: "power", label: "Launch at login") {
                    Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
                }
                SettingRow(icon: "hand.raised.fill", label: "Accessibility") {
                    PermissionBadge(granted: coordinator.hasAccessibilityPermission)
                }
                SettingRow(icon: "shippingbox.fill", label: "Voice model") {
                    Text(coordinator.modelStatusLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .cardBackground(padding: 2)

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Aloud")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
        }
    }

    private var voiceCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Voices.grouped(), id: \.group) { entry in
                    Text(entry.group.rawValue)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(entry.voices) { voice in
                            VoiceRow(
                                voice: voice,
                                isSelected: settings.selectedVoice == voice.id,
                                onSelect: { settings.selectedVoice = voice.id },
                                onPreview: { coordinator.previewVoice(voice.id) }
                            )
                        }
                    }
                }
            }
            .padding(.trailing, 4)
        }
        .frame(height: 172)
        .cardBackground()
    }
}

private struct SettingRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 9) {
            IconBadge(systemName: icon)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

private struct VoiceRow: View {
    let voice: VoiceInfo
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack {
            Text(voice.name)
                .font(.system(size: 11.5, weight: .semibold))
                // .primary even when selected — accentColor text on its
                // own accent-tinted background measured ~2.9:1, under the
                // 4.5:1 AA bar. The tint + accent border are enough to
                // signal "selected" without the text itself needing color.
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onPreview) {
                Image(systemName: "play.fill").font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(voice.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Button {
                PermissionsManager.requestAccess()
                PermissionsManager.openAccessibilitySettings()
            } label: {
                Label("Open Settings", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        }
    }
}
