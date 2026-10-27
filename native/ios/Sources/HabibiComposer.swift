// Adapted from Tuist Atlas's native glass composer (9af36c01be).
// Copyright (c) from 2018 Tuist GmbH. MIT license: native/ATLAS_LICENSE.
import SwiftUI

struct HabibiComposer: View {
    @Binding var draft: String
    let connected: Bool
    let running: Bool
    let phase: HabibiVoiceInput.Phase
    let levels: [CGFloat]
    let start: () -> Void
    let stop: () -> Void
    let cancel: () -> Void
    let send: () -> Void
    let stopReply: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.habibiPalette) private var palette
    @FocusState private var typing: Bool

    private var recording: Bool { phase != .idle }
    private var canSubmit: Bool {
        connected && !running && draft.count <= 4000 && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Group {
                if phase == .requesting {
                    Text("Waiting for permission…").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("habibi.voice.status")
                } else if phase == .recording {
                    HStack(spacing: 3) {
                        ForEach(levels.indices, id: \.self) { index in
                            Capsule().fill(.tint).frame(maxWidth: .infinity).frame(height: 4 + levels[index] * 24)
                        }
                    }
                    .frame(height: 44)
                    .animation(reduceMotion ? nil : .linear(duration: 0.05), value: levels)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Recording on this device")
                    .accessibilityHint("Release the microphone or tap stop to add editable text. Nothing is sent automatically.")
                    .accessibilityIdentifier("habibi.voice.recording")
                } else {
                    TextField("Ask Habibi", text: $draft, axis: .vertical)
                        .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                        .textFieldStyle(.plain).padding(.vertical, 11).padding(.leading, 12)
                        .focused($typing).accessibilityIdentifier("habibi.composer")
                }
            }
            .padding(.leading, recording ? 52 : 0).padding(.trailing, recording ? 8 : 44)
            if recording {
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 20)).frame(width: 44, height: 44)
                        .foregroundStyle(.secondary)
                        .background { Circle().fill(Color(uiColor: .tertiarySystemFill)).padding(4) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Discard dictation")
                .accessibilityHint("Keeps your existing typed draft unchanged.")
                .accessibilityIdentifier("habibi.voice.cancel")
            } else if running {
                Button(action: stopReply) {
                    Image(systemName: "stop.fill").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                        .foregroundStyle(palette.onPrimary)
                        .background { Circle().fill(.tint).padding(4) }
                }
                .buttonStyle(.plain).accessibilityLabel("Stop reply").accessibilityIdentifier("habibi.stop")
            } else {
                Button { typing = false; send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44)
                        .foregroundStyle(palette.onPrimary)
                        .background { Circle().fill(.tint).padding(4) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(canSubmit ? 1 : 0.3).disabled(!canSubmit)
                .accessibilityLabel("Send message").accessibilityIdentifier("habibi.send")
            }
        }
        .overlay(alignment: recording ? .bottomLeading : .bottomTrailing) {
            // The same native touch target survives the transition into recording.
            HabibiMicrophoneButton(active: recording, start: { typing = false; start() }, stop: stop, cancel: cancel)
                .disabled(running).padding(.trailing, recording ? 0 : 48)
        }
        .padding(4).foregroundStyle(.primary).background { HabibiGlassSurface() }
        .accessibilityElement(children: .contain)
    }
}

struct HabibiGlassSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28)
        if reduceTransparency || contrast == .increased {
            shape.fill(Color(uiColor: .secondarySystemBackground))
                .overlay { shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1) }
        } else if #available(iOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}

private struct HabibiMicrophoneButton: View {
    let active: Bool
    let start: () -> Void
    let stop: () -> Void
    let cancel: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        ZStack {
            Circle().fill(active ? Color.red.opacity(0.1) : Color(uiColor: .tertiarySystemFill)).padding(4)
            Image(systemName: active ? "stop.fill" : "mic.fill").font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? Color.red : Color.secondary).accessibilityHidden(true)
            HabibiMicrophoneTouchTarget(active: active, enabled: enabled, start: start, stop: stop, cancel: cancel)
        }
        .frame(width: 44, height: 44).opacity(enabled ? 1 : 0.4)
    }
}

private struct HabibiMicrophoneTouchTarget: UIViewRepresentable {
    let active: Bool
    let enabled: Bool
    let start: () -> Void
    let stop: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 60
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        if button.isEnabled != enabled {
            button.isEnabled = enabled
            button.gestureRecognizers?.forEach { $0.isEnabled = enabled }
        }
        button.accessibilityLabel = active ? "Stop dictation" : "Transcribe a voice message"
        button.accessibilityHint = active ? "Adds editable text to your draft. Does not send a message."
            : "Hold while speaking and release to add editable text. Tap to start or stop hands-free dictation. Nothing is sent automatically."
        button.accessibilityIdentifier = "habibi.microphone"
    }

    final class Coordinator: NSObject {
        var parent: HabibiMicrophoneTouchTarget
        private var holding = false
        init(_ parent: HabibiMicrophoneTouchTarget) { self.parent = parent }

        @objc func tap() {
            guard parent.enabled else { return }
            if parent.active { parent.stop() } else { parent.start() }
        }

        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard parent.enabled else { return }
                if parent.active { parent.stop(); return }
                holding = true
                parent.start()
            case .ended: endHold(cancelled: false)
            case .cancelled, .failed: endHold(cancelled: true)
            default: break
            }
        }

        func endHold(cancelled: Bool) {
            guard holding else { return }
            holding = false
            if cancelled { parent.cancel() } else { parent.stop() }
        }
    }
}
