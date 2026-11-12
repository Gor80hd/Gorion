import GorionDesign
import GorionKit
import SwiftUI

/// Основной островок (эталон — map_view.dart): планета на всю площадь,
/// над ней слева — состояние и сервер, справа — режим, внизу — парящая
/// стеклянная панель подключения. Стекло панели преломляет планету.
struct MainIsland: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < GComponent.compactHeight
            ZStack(alignment: .top) {
                GlobeView(
                    inputs: globeInputs,
                    insets: EdgeInsets(
                        top: compact ? GComponent.globeTopInsetCompact : GComponent.globeTopInset,
                        leading: GSpacing.xxl,
                        bottom: compact ? GComponent.globeBottomInsetCompact : GComponent.globeBottomInset,
                        trailing: GSpacing.xxl),
                    onSelectCountry: { ui.selectedCountry = $0 })

                // Полоса у верхнего края — за неё окно перетаскивается.
                Color.clear
                    .frame(height: GLayout.sidebarHeaderHeight / 2)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())

                HStack(alignment: .top, spacing: GSpacing.lg) {
                    ConnectionHero()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ModeBadge()
                }
                .padding(.top, GSpacing.xl)
                .padding(.leading, GSpacing.xxl)
                .padding(.trailing, GSpacing.lg)

                VStack(spacing: GSpacing.sm) {
                    Spacer(minLength: 0)
                    ToastHost()
                    if model.needsHelper, !ui.showingAddSubscription {
                        HelperSetupCard(outdated: model.snapshot.error?.code == .helperOutdated)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    } else if let error = model.snapshot.error, !ui.showingAddSubscription {
                        ProblemView(failure: error)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                    ConnectionBar()
                }
                .frame(maxWidth: GComponent.connectionBarMaxWidth)
                .padding(GSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(GMotion.animation(GMotion.smooth, reduceMotion: reduceMotion), value: model.snapshot.error)
            }
        }
    }

    private var globeInputs: GlobeInputs {
        let snapshot = model.snapshot
        // Как в эталоне: в режиме системного прокси точка отправления — по
        // региону системы, иначе — по внешнему IP.
        let localSource = snapshot.mode == .systemProxy
        let regionCode = Locale.current.region?.identifier
        let regionPoint = regionCode.flatMap { countryLocation(code: $0) }
        let source = localSource ? (regionPoint ?? snapshot.sourceLocation) : snapshot.sourceLocation
        let sourceCountry = localSource ? (regionPoint == nil ? nil : regionCode) : snapshot.directIp?.countryCode

        var countries: [String: GlobeCountryInfo] = [:]
        for server in snapshot.servers {
            guard let code = server.mapCountryCode else { continue }
            let ping = Int(server.delayMs ?? 0)
            let previous = countries[code]
            let best = [previous?.bestPing ?? 0, ping].filter { $0 > 0 }.min() ?? 0
            countries[code] = GlobeCountryInfo(code: code, serverCount: (previous?.serverCount ?? 0) + 1, bestPing: best)
        }

        return GlobeInputs(
            source: Vector3(lat: source.lat, lon: source.lon),
            destination: Vector3(lat: snapshot.destinationLocation.lat, lon: snapshot.destinationLocation.lon),
            sourceCountry: sourceCountry,
            destinationCountry: snapshot.destinationCountry,
            showConnection: model.isConnected,
            connected: model.isConnected,
            busy: snapshot.stage == .starting || (model.isConnected && snapshot.busy),
            countries: countries,
            selectedCountry: ui.selectedCountry,
            highlightedCountry: ui.highlightedCountry,
            reduceMotion: reduceMotion)
    }
}

// MARK: - Заголовок состояния

/// Состояние, имя сервера и метки сессии. Без подложки — текст лежит прямо
/// на островке над планетой.
private struct ConnectionHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let snapshot = model.snapshot
        let auto = snapshot.autoSelected
        // В автовыборе до подключения сервер ещё не известен.
        let server = auto && !model.isConnected ? nil : model.activeServer
        VStack(alignment: .leading, spacing: GSpacing.xs) {
            Label {
                Text(Copy.heroStatus(snapshot.stage, switching: model.isConnected && snapshot.busy))
                    .contentTransition(.opacity)
            } icon: {
                Image(systemName: statusSymbol)
                    .font(.system(size: GComponent.heroStatusIconSize, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .textStyle(GType.labelLarge)
            .foregroundStyle(statusColor)
            .lineLimit(1)

            Text(title(server: server, auto: auto))
                .textStyle(GType.headlineLarge)
                .foregroundStyle(GColor.textPrimary)
                .lineLimit(1)
                .contentTransition(.opacity)

            // Секунды сессии тикают только у меток, не у всего заголовка.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let tags = tagList(server: server, auto: auto, now: timeline.date)
                if !tags.isEmpty {
                    HStack(spacing: GSpacing.xs + GSpacing.xxs) {
                        ForEach(tags.indices, id: \.self) { tags[$0] }
                    }
                    .padding(.top, GSpacing.xs)
                }
            }
            if auto, model.isConnected, let server {
                Text(Copy.serverTitle(server))
                    .textStyle(GType.body)
                    .fontWeight(.medium)
                    .foregroundStyle(GColor.textPrimary.opacity(0.8))
                    .lineLimit(1)
                    .padding(.top, GSpacing.xs)
            }
            if auto {
                Text(Copy.autoActive)
                    .textStyle(GType.bodySmall)
                    .foregroundStyle(GColor.textMuted)
            }
        }
        .animation(GMotion.animation(GMotion.smooth, reduceMotion: reduceMotion), value: snapshot.stage)
        .animation(GMotion.animation(GMotion.smooth, reduceMotion: reduceMotion), value: snapshot.activeTag)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch model.snapshot.stage {
        case .connected: model.snapshot.busy ? "arrow.triangle.2.circlepath" : "lock.fill"
        case .starting, .stopping: "arrow.triangle.2.circlepath"
        case .disconnected, .failed: "lock.open.fill"
        }
    }

    private var statusColor: DynamicColor {
        let stage = model.snapshot.stage
        if stage == .starting || stage == .stopping || (stage == .connected && model.snapshot.busy) {
            return GColor.statusWarning
        }
        return stage == .connected ? GColor.brandAccent : GColor.textMuted
    }

    private func title(server: CoreServer?, auto: Bool) -> String {
        if auto { return Copy.autoServerTitle }
        guard let server else { return Copy.noServer }
        return Copy.serverTitle(server)
    }

    private func tagList(server: CoreServer?, auto: Bool, now: Date) -> [GTag] {
        var tags: [GTag] = []
        if let server, !server.kind.isEmpty {
            tags.append(GTag(server.kind.uppercased(), tint: GColor.statusInfo))
        }
        if auto {
            tags.append(GTag(Copy.autoTag, symbol: "sparkles", tint: GColor.brandAccent))
        }
        if let delay = server?.delayMs, delay > 0 {
            tags.append(GTag(Copy.delay(delay), symbol: "waveform.path.ecg", tint: pingColor(delay)))
        }
        if model.isConnected, let started = model.snapshot.connectedAtMs {
            let seconds = max(0, Int(now.timeIntervalSince1970 - Double(started) / 1000))
            tags.append(GTag(Copy.session, value: Copy.elapsed(seconds), tint: GColor.brandAccent))
        }
        return tags
    }
}

// MARK: - Режим

/// Режим на главном экране не выбирается: по умолчанию VPN для всего
/// компьютера (ADR-0005). Если опытный пользователь выбрал другой режим в
/// меню «Подключение → Режим», об этом напоминает метка.
private struct ModeBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mode = model.snapshot.mode
        if mode != .wholeComputer {
            GTag(Copy.modeTitle(mode), symbol: "slider.horizontal.3", tint: GColor.textMuted)
                .help(Copy.modeExplanation(mode, port: model.snapshot.localProxyPort))
                .accessibilityLabel("Режим: \(Copy.modeTitle(mode))")
        }
    }
}

// MARK: - Панель подключения

/// Парящая панель: кнопка питания, IP и трафик (эталон — нативная панель
/// Flutter-версии в MainFlutterWindow.swift).
private struct ConnectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            GlassEffectContainer(spacing: GSpacing.md) {
                content(width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .glassEffect(.regular, in: .rect(cornerRadius: GComponent.connectionBarRadius, style: .continuous))
            }
        }
        .frame(height: GComponent.powerButtonSize + GSpacing.md * 2)
    }

    private func content(width: CGFloat) -> some View {
        let connected = model.isConnected
        let active = connected || model.isTransitioning
        let ip = connected ? model.snapshot.routedIp : model.snapshot.directIp
        return HStack(spacing: 0) {
            PowerButton()
                .padding(.trailing, GSpacing.lg)

            VStack(alignment: .leading, spacing: GSpacing.xxs / 2) {
                Text(connected ? "IP сервера" : "Ваш IP")
                    .textStyle(GType.labelSmall)
                    .fontWeight(.medium)
                    .foregroundStyle(GColor.textMuted)
                Text(ip?.ip ?? "—")
                    .textStyle(GType.headlineSmall)
                    .monospacedDigit()
                    .foregroundStyle(connected ? AnyShapeStyle(GColor.brandAccent) : AnyShapeStyle(GColor.textPrimary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .textSelection(.enabled)
                Text(ip?.location ?? (connected ? "Получаем IP сервера…" : "Определяем внешний адрес…"))
                    .textStyle(GType.bodySmall)
                    .foregroundStyle(GColor.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(GMaterial.hairline)
                .frame(width: GComponent.strokeWidth, height: GComponent.barDividerHeight)
                .padding(.horizontal, GSpacing.lg)

            TrafficMetric(
                symbol: "arrow.down", label: "Загрузка", value: model.traffic.down,
                tint: active ? GColor.brandAccent : GColor.textMuted)

            if width >= GComponent.connectionBarGraphMinWidth {
                TrafficSparkline(history: model.trafficHistory, active: active)
                    .frame(height: GComponent.sparklineHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, GSpacing.lg)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: GSpacing.lg)
            }

            if width >= GComponent.connectionBarUploadMinWidth {
                TrafficMetric(
                    symbol: "arrow.up", label: "Отдача", value: model.traffic.up,
                    tint: active ? GColor.statusUpload : GColor.textMuted)
            }
        }
        .padding(.leading, GSpacing.md)
        .padding(.trailing, GSpacing.xl)
        .frame(maxHeight: .infinity)
    }
}

private struct PowerButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stage = model.snapshot.stage
        let connected = stage == .connected && !model.snapshot.busy
        let busy = stage == .starting || stage == .stopping || (stage == .connected && model.snapshot.busy)
        Button(action: model.toggleConnection) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: GComponent.powerIconSize, weight: .semibold))
                }
            }
            .frame(width: GComponent.powerButtonSize, height: GComponent.powerButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(PowerButtonStyle())
        .foregroundStyle(connected ? AnyShapeStyle(GColor.brandOnAccent) : AnyShapeStyle(GColor.textPrimary))
        .glassEffect(glass(connected: connected, busy: busy), in: .circle)
        .disabled(stage == .stopping)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .animation(GMotion.animation(GMotion.bouncy, reduceMotion: reduceMotion), value: stage)
        .keyboardShortcut(.defaultAction)
    }

    private func glass(connected: Bool, busy: Bool) -> Glass {
        if connected { return .regular.tint(GColor.brandAccent.color).interactive() }
        if busy { return .regular.tint(GColor.statusWarning.color.opacity(0.45)).interactive() }
        return .regular.interactive()
    }

    private var tooltip: String {
        switch model.snapshot.stage {
        case .starting: "Отменить"
        case .connected: "Отключиться"
        case .stopping: "Отключаемся…"
        case .disconnected, .failed: "Подключиться"
        }
    }
}

/// Нажатие кнопки питания: проседание на `press`, возврат на `release`.
private struct PowerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressFeedback(pressed: configuration.isPressed, scale: GMotion.pressScaleSmallControl)
    }
}

private struct TrafficMetric: View {
    let symbol: String
    let label: String
    let value: UInt64
    let tint: DynamicColor

    var body: some View {
        VStack(alignment: .leading, spacing: GSpacing.xxs) {
            HStack(spacing: GSpacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: GComponent.iconSizeSmall - GSpacing.xxs, weight: .semibold))
                Text(label)
                    .textStyle(GType.labelSmall)
                    .fontWeight(.medium)
            }
            .foregroundStyle(GColor.textMuted)
            Text(Copy.rate(value))
                .textStyle(GType.titleMedium)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .contentTransition(.numericText(value: Double(value)))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Copy.rate(value))")
    }
}

private struct TrafficSparkline: View {
    let history: [TrafficRate]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let peak = max(Double(history.map { max($0.down, $0.up) }.max() ?? 0), 1)
            func path(_ values: [Double]) -> Path {
                var path = Path()
                guard values.count > 1 else { return path }
                let step = size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let p = CGPoint(
                        x: CGFloat(i) * step,
                        y: size.height - GSpacing.xxs - CGFloat(v / peak) * (size.height - GSpacing.xs))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                return path
            }
            let style = StrokeStyle(lineWidth: GComponent.sparklineStroke, lineCap: .round, lineJoin: .round)
            let idle = GraphicsContext.Shading.style(GColor.textMuted.opacity(0.5))
            context.stroke(
                path(history.map { Double($0.up) }),
                with: active ? .style(GColor.statusUpload.opacity(0.7)) : idle, style: style)
            context.stroke(
                path(history.map { Double($0.down) }),
                with: active ? .style(GColor.brandAccent) : idle, style: style)
        }
    }
}

// MARK: - Ошибка

/// Ошибка над панелью: что случилось, что делать и кнопка действия;
/// технические детали — под «Подробнее».
private struct ProblemView: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    let failure: CoreFailure
    @State private var showDetails = false

    var body: some View {
        let problem = Copy.problem(failure.code, serverName: model.activeServer?.name, autoSelected: model.snapshot.autoSelected)
        HStack(alignment: .top, spacing: GSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GColor.statusDanger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: GSpacing.sm) {
                Text(problem.message)
                    .textStyle(GType.bodySmall)
                    .fontWeight(.medium)
                    .foregroundStyle(GColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GSpacing.sm) {
                    if let title = problem.actionTitle, let action = problem.action {
                        Button(title) { perform(action) }
                            .buttonStyle(GButtonStyle(.regular, size: .small))
                    }
                    if !failure.detail.isEmpty {
                        Button(Copy.details) { showDetails.toggle() }
                            .buttonStyle(GButtonStyle(.quiet, size: .small))
                            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                                Text(failure.detail)
                                    .textStyle(GType.bodySmall)
                                    .textSelection(.enabled)
                                    .padding(GSpacing.md)
                                    .frame(maxWidth: GComponent.toastMaxWidth)
                            }
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                model.dismissMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: GComponent.iconSizeSmall, weight: .semibold))
            }
            .buttonStyle(GButtonStyle(.quiet, size: .small))
            .accessibilityLabel("Скрыть сообщение")
        }
        .padding(.horizontal, GSpacing.md + GSpacing.xxs)
        .padding(.vertical, GSpacing.sm + GSpacing.xxs)
        .glassEffect(.regular.tint(GColor.statusDanger.color.opacity(GComponent.tagFillOpacity)), in: .rect(cornerRadius: GRadius.card))
        .accessibilityElement(children: .contain)
    }

    private func perform(_ action: Copy.Action) {
        switch action {
        case .retryConnect: model.connect()
        case .useAutoSelect: model.selectAutoAndConnect()
        case .addSubscription: ui.showingAddSubscription = true
        case .switchToManual: model.setMode(.manual)
        case .installHelper: model.installHelper(prompt: Copy.helperPasswordPrompt)
        case .refreshProfile:
            if let id = model.snapshot.activeProfileId { model.refreshProfile(id) }
        }
    }
}

// MARK: - Установка помощника

/// Первое подключение в режиме «Весь компьютер»: объясняет, зачем macOS
/// спросит пароль, и ставит системный компонент одной кнопкой. Это не
/// ошибка, поэтому без красного.
private struct HelperSetupCard: View {
    @Environment(AppModel.self) private var model
    let outdated: Bool

    var body: some View {
        HStack(alignment: .top, spacing: GSpacing.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: GComponent.iconSizeLarge, weight: .semibold))
                .foregroundStyle(GColor.brandAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: GSpacing.xs) {
                Text(outdated ? Copy.helperUpdateTitle : Copy.helperSetupTitle)
                    .textStyle(GType.labelLarge)
                    .foregroundStyle(GColor.textPrimary)
                Text(outdated ? Copy.helperUpdateBody : Copy.helperSetupBody)
                    .textStyle(GType.bodySmall)
                    .foregroundStyle(GColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GSpacing.sm) {
                    Button(outdated ? Copy.helperUpdate : Copy.helperInstall) {
                        model.installHelper(prompt: Copy.helperPasswordPrompt)
                    }
                    .buttonStyle(GButtonStyle(.primary, size: .small))
                    .disabled(model.snapshot.busy)
                    Button(Copy.notNow) { model.dismissMessage() }
                        .buttonStyle(GButtonStyle(.quiet, size: .small))
                }
                .padding(.top, GSpacing.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GSpacing.md + GSpacing.xxs)
        .padding(.vertical, GSpacing.sm + GSpacing.xxs)
        .glassEffect(.regular, in: .rect(cornerRadius: GRadius.card))
        .accessibilityElement(children: .contain)
    }
}
