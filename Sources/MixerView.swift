import SwiftUI

struct MixerView: View {
    let model: MixerModel
    var keyboard: KazakhKeyboard? = nil
    var onHeightChange: (CGFloat) -> Void

    private let maxVisibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            MasterRow(model: model)

            Rectangle()
                .fill(.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 4)

            if model.access != .granted {
                PermissionCard(model: model)
                    .transition(.opacity)
            } else if model.apps.isEmpty {
                EmptyState()
                    .transition(.opacity)
            } else if model.apps.count > maxVisibleRows {
                ScrollView {
                    appList
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(maxVisibleRows) * 38 - 8)
            } else {
                appList
            }

            if let keyboard, keyboard.needsAccess {
                KeyboardAccessHint(keyboard: keyboard)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: PanelController.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .animation(.smooth(duration: 0.28), value: model.apps.map(\.id))
        .animation(.smooth(duration: 0.28), value: model.access)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Микшер")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                Toggle("Открывать при входе в систему", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Button("Вернуть всем 100%") { model.resetAll() }
                    .disabled(!model.hasAdjustments)
                if let keyboard {
                    Divider()
                    KeyboardMenu(keyboard: keyboard)
                }
                Divider()
                Button("Выйти") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 4)
    }

    private var appList: some View {
        VStack(spacing: 8) {
            ForEach(model.apps) { item in
                AppRow(item: item, model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }
}

// MARK: - Rows

private struct MasterRow: View {
    let model: MixerModel

    var body: some View {
        HStack(spacing: 10) {
            RoundIconButton(
                symbol: model.masterMuted ? "speaker.slash.fill" : model.output.symbol,
                help: model.masterMuted ? "Включить звук" : "Выключить звук",
                enabled: model.output.canMute,
                action: model.toggleMasterMute
            )
            VolumeCapsule(
                value: model.masterVolume,
                dimmed: model.masterMuted,
                enabled: model.output.hasVolume,
                onChange: model.setMasterVolume
            ) {
                Text(model.output.name).lineLimit(1)
            } trailing: {
                Text(percentText(model.masterVolume, muted: model.masterMuted))
            }
        }
    }
}

private struct AppRow: View {
    let item: AppItem
    let model: MixerModel
    @State private var hoveringIcon = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleMute(for: item.id)
            } label: {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .saturation(item.isMuted ? 0 : 1)
                    .opacity(item.isMuted ? 0.55 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if hoveringIcon || item.isMuted {
                            muteBadge.offset(x: 3, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringIcon = $0 }
            .help(item.isMuted ? "Включить звук" : "Выключить звук")

            VolumeCapsule(
                value: item.volume,
                dimmed: item.isMuted,
                onChange: { model.setVolume($0, for: item.id) },
                onReset: { model.reset(item.id) }
            ) {
                HStack(spacing: 5) {
                    Text(item.name).lineLimit(1)
                    if item.isPlaying && !item.isMuted {
                        // Static on purpose: a looping symbol animation keeps the GPU busy all the time.
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.5)
                            .transition(.opacity)
                    }
                }
            } trailing: {
                Text(percentText(item.volume, muted: item.isMuted))
            }
        }
    }

    private var muteBadge: some View {
        // Shows the current state, and the action while hovering.
        let showsSlash = item.isMuted != hoveringIcon
        return Image(systemName: showsSlash ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(.black.opacity(0.6)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

private func percentText(_ value: Double, muted: Bool) -> String {
    muted ? "Выкл" : "\(Int((value * 100).rounded()))%"
}

// MARK: - Controls

/// Control Center–style volume bar: the fill is the level, the label sits inside.
struct VolumeCapsule<Leading: View, Trailing: View>: View {
    let value: Double
    let dimmed: Bool
    let enabled: Bool
    let onChange: (Double) -> Void
    let onReset: (() -> Void)?
    let leading: Leading
    let trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    @State private var dragging = false

    private let height: CGFloat = 30

    init(
        value: Double,
        dimmed: Bool = false,
        enabled: Bool = true,
        onChange: @escaping (Double) -> Void,
        onReset: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.value = value
        self.dimmed = dimmed
        self.enabled = enabled
        self.onChange = onChange
        self.onReset = onReset
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fillWidth = width * CGFloat(min(max(value, 0), 1))

            ZStack(alignment: .leading) {
                Rectangle().fill(trackColor)
                Rectangle().fill(fillColor).frame(width: fillWidth)
                labels.foregroundStyle(textOnTrack)
                labels.foregroundStyle(textOnFill)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fillWidth)
                    }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        let position = min(max(Double(gesture.location.x / width), 0), 1)
                        onChange((position * 100).rounded() / 100)
                    }
                    .onEnded { _ in dragging = false },
                including: enabled ? .all : .none
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onReset?() },
                including: enabled && onReset != nil ? .all : .none
            )
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .animation(.smooth(duration: 0.2), value: dimmed)
    }

    private var labels: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 8)
            trailing.monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var active: Bool { enabled && (hovering || dragging) }

    private var trackColor: Color {
        isDark ? .white.opacity(active ? 0.17 : 0.12) : .black.opacity(active ? 0.11 : 0.075)
    }

    private var fillColor: Color {
        if dimmed { return isDark ? .white.opacity(0.28) : .black.opacity(0.16) }
        return isDark ? .white.opacity(0.92) : .white
    }

    private var textOnTrack: Color { isDark ? .white.opacity(0.92) : .black.opacity(0.8) }
    private var textOnFill: Color { dimmed ? textOnTrack : .black.opacity(0.8) }
    private var borderColor: Color { isDark ? .white.opacity(0.07) : .black.opacity(0.05) }
}

private struct RoundIconButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(hovering && enabled ? 0.15 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Kazakh keyboard

private struct KeyboardMenu: View {
    let keyboard: KazakhKeyboard

    var body: some View {
        Menu("Казахская клавиатура") {
            Button(keyboard.layoutInstalled ? "Переустановить раскладку" : "Установить раскладку «Русская + Қазақша»") {
                keyboard.installLayout()
            }
            Toggle("Казахские буквы на правом ⌘", isOn: Binding(
                get: { keyboard.rightCommand },
                set: { keyboard.rightCommand = $0 }
            ))
            Toggle("Автозамена казахских слов", isOn: Binding(
                get: { keyboard.autocorrect },
                set: { keyboard.autocorrect = $0 }
            ))
            Button("Мои слова для автозамены…") { keyboard.openUserWords() }
            if let app = keyboard.frontmostApp {
                Toggle("Не исправлять в «\(app.name)»", isOn: Binding(
                    get: { keyboard.isFrontmostExcluded },
                    set: { _ in keyboard.toggleFrontmostExclusion() }
                ))
            }
            if keyboard.learnedCount > 0 {
                Button("Забыть выученное (\(keyboard.learnedCount))") { keyboard.forgetLearned() }
            }
            if keyboard.needsAccess {
                Divider()
                Button("Дать доступ к клавиатуре…") { keyboard.requestAccess() }
            }
        }
    }
}

private struct KeyboardAccessHint: View {
    let keyboard: KazakhKeyboard

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Правому ⌘ и автозамене нужен доступ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Открыть") { keyboard.requestAccess() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 4)
    }
}

// MARK: - States

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("Сейчас тихо")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Приложения со звуком появятся здесь")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct PermissionCard: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Нужен доступ к звуку")
                .font(.system(size: 12, weight: .semibold))
            Text(model.access == .denied
                 ? "Включи «Микшер» в Системных настройках → Конфиденциальность и безопасность → Запись экрана и системного звука."
                 : "macOS спросит разрешение на запись системного звука. Без него громкость приложений не поменять. Звук никуда не сохраняется.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.access == .denied ? "Открыть Настройки" : "Разрешить") {
                model.requestAccess()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
    }
}
