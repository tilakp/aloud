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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text("Settings").font(.system(size: 13, weight: .bold))
            }
            .padding(.bottom, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
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
            .frame(height: 178)

            Divider()

            SettingRow(label: "Read selection") {
                KeyboardShortcuts.Recorder(for: .readSelection)
                    .controlSize(.small)
            }
            SettingRow(label: "Default speed") {
                Stepper(value: $settings.speed, in: 0.5...2.0, step: 0.1) {
                    Text(String(format: "%.1f×", settings.speed))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            SettingRow(label: "Launch at login") {
                Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
            }
            SettingRow(label: "Accessibility") {
                PermissionBadge(granted: coordinator.hasAccessibilityPermission)
            }
            SettingRow(label: "Voice model") {
                Text(coordinator.modelStatusLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Button("Quit Aloud") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }
}

private struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .semibold))
            Spacer()
            content
        }
        .padding(.top, 6)
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
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            Spacer()
            Button(action: onPreview) {
                Image(systemName: "play.fill").font(.system(size: 8))
            }
            .buttonStyle(.plain)
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
