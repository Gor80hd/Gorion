import GorionDesign
import GorionKit
import SwiftUI

/// Боковой островок (эталон — servers_panel.dart): шапка под «светофор»,
/// поиск и действия, «Рекомендуем» с автовыбором и подписки с серверами.
struct SidebarIsland: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @AppStorage("serverSortMode") private var sortRaw = ServerSort.none.rawValue
    @FocusState private var searchFocused: Bool
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.snapshot.bootstrapping {
                Spacer()
            } else if model.snapshot.profiles.isEmpty {
                Spacer()
                EmptyServers()
                Spacer()
            } else {
                controls
                serverList
            }
        }
        .onChange(of: ui.searchFocusRequest) { searchFocused = true }
    }

    private var sort: ServerSort { ServerSort(rawValue: sortRaw) ?? .none }

    // MARK: Шапка

    /// Место под кнопки окна; за свободную часть окно перетаскивается.
    private var header: some View {
        HStack(spacing: GSpacing.sm) {
            Color.clear.frame(width: GLayout.trafficLightsWidth)
            Text(Copy.serversTitle)
                .textStyle(GType.titleMedium)
                .foregroundStyle(GColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GSpacing.md)
        .frame(height: GLayout.sidebarHeaderHeight)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    // MARK: Поиск и действия

    private var controls: some View {
        VStack(alignment: .leading, spacing: GSpacing.sm) {
            HStack(spacing: GSpacing.xs) {
                searchField
                SortMenu(sortRaw: $sortRaw)
                Button {
                    model.measureDelays()
                } label: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .symbolEffect(.pulse, isActive: model.snapshot.measuringDelays)
                        .frame(width: GComponent.buttonHeightRegular, height: GComponent.buttonHeightRegular)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(model.activeProfile == nil || model.snapshot.measuringDelays)
                .help(model.snapshot.measuringDelays ? Copy.measuring : Copy.measure)
                .accessibilityLabel(model.snapshot.measuringDelays ? Copy.measuring : Copy.measure)
                SubscriptionMenu()
            }
            if let code = ui.selectedCountry {
                CountryFilterChip(code: code) { ui.selectedCountry = nil }
            }
        }
        .padding(.leading, GSpacing.md)
        .padding(.trailing, GSpacing.sm)
        .padding(.bottom, GSpacing.sm)
    }

    private var searchField: some View {
        HStack(spacing: GSpacing.xs + GSpacing.xxs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: GComponent.iconSizeSmall))
                .foregroundStyle(GColor.textMuted)
            TextField(Copy.searchPrompt, text: $query)
                .textFieldStyle(.plain)
                .textStyle(GType.body)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(GColor.textSubtle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, GSpacing.md)
        .frame(height: GComponent.buttonHeightRegular)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: Список

    private func visible(_ servers: [CoreServer]) -> [CoreServer] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let filtered = servers.filter { server in
            (ui.selectedCountry == nil || server.mapCountryCode == ui.selectedCountry)
                && (trimmed.isEmpty || server.name.localizedCaseInsensitiveContains(trimmed)
                    || (server.countryCode?.localizedCaseInsensitiveContains(trimmed) ?? false))
        }
        return sort.apply(filtered)
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionLabel("Рекомендуем")
                AutoCard(namespace: selection)
                    .padding(.top, GSpacing.sm)
                SectionLabel(ui.selectedCountry.map(Copy.countryName) ?? "Все серверы")
                    .padding(.top, GSpacing.sm + GSpacing.xxs)
                    .padding(.bottom, GSpacing.sm)
                ForEach(model.snapshot.profiles, id: \.id) { profile in
                    profileSection(profile)
                }
            }
            .padding(.horizontal, GSpacing.sm)
            .padding(.bottom, GSpacing.sm)
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private func profileSection(_ profile: CoreProfile) -> some View {
        let isActive = profile.id == model.snapshot.activeProfileId
        let servers = isActive ? visible(model.snapshot.servers) : []
        let expanded = isActive && !collapsed.contains(profile.id)
        SubscriptionRow(
            name: profile.name,
            count: isActive ? servers.count : Int(profile.serverCount),
            active: isActive, expanded: expanded
        ) {
            if isActive {
                if collapsed.remove(profile.id) == nil { collapsed.insert(profile.id) }
            } else {
                // Серверы другой подписки появятся, когда она станет текущей.
                collapsed.remove(profile.id)
                model.chooseProfile(profile.id)
            }
        }
        if expanded {
            VStack(spacing: GSpacing.xxs) {
                if servers.isEmpty {
                    Text(query.isEmpty && ui.selectedCountry == nil
                         ? "В этой подписке пока нет доступных серверов."
                         : "По текущему фильтру серверы не найдены.")
                        .textStyle(GType.bodySmall)
                        .fontWeight(.medium)
                        .foregroundStyle(GColor.textMuted)
                        .padding(.leading, GSpacing.md)
                        .padding(.bottom, GSpacing.xxs)
                }
                ForEach(servers, id: \.tag) { server in
                    ServerCard(server: server, namespace: selection)
                }
            }
            .padding(.top, GSpacing.xs + GSpacing.xxs)
        }
        Color.clear.frame(height: GSpacing.sm)
    }
}

// MARK: - Сортировка

enum ServerSort: String, CaseIterable {
    case none, ping, name

    var title: String {
        switch self {
        case .none: "Без сортировки"
        case .ping: "По пингу"
        case .name: "По имени"
        }
    }

    func apply(_ servers: [CoreServer]) -> [CoreServer] {
        switch self {
        case .none: servers
        case .name: servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .ping:
            // Неизмеренные и неответившие — в конце, порядок среди них прежний.
            servers.enumerated().sorted { a, b in
                let da = a.element.delayMs.flatMap { $0 > 0 ? $0 : nil } ?? .max
                let db = b.element.delayMs.flatMap { $0 > 0 ? $0 : nil } ?? .max
                return da == db ? a.offset < b.offset : da < db
            }.map(\.element)
        }
    }
}

private struct SortMenu: View {
    @Binding var sortRaw: String

    var body: some View {
        Menu {
            Picker("Сортировка", selection: $sortRaw) {
                ForEach(ServerSort.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .frame(width: GComponent.buttonHeightRegular, height: GComponent.buttonHeightRegular)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .circle)
        .fixedSize()
        .help("Сортировка")
        .accessibilityLabel("Сортировка: \(ServerSort(rawValue: sortRaw)?.title ?? "")")
    }
}

// MARK: - Подписки

private struct SubscriptionMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @State private var renaming: CoreProfile?
    @State private var newName = ""

    var body: some View {
        Menu {
            Button(Copy.addSubscription + "…", systemImage: "plus") { ui.showingAddSubscription = true }
            if let profile = model.activeProfile {
                Button(Copy.refresh, systemImage: "arrow.clockwise") { model.refreshProfile(profile.id) }
                Button("Переименовать…", systemImage: "pencil") {
                    newName = profile.name
                    renaming = profile
                }
                Divider()
                Button(Copy.remove, systemImage: "trash", role: .destructive) { model.removeProfile(profile.id) }
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: GComponent.buttonHeightRegular, height: GComponent.buttonHeightRegular)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .circle)
        .fixedSize()
        .help("Подписки")
        .accessibilityLabel("Подписки")
        .alert("Название подписки", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $newName)
            Button("Сохранить") {
                if let renaming { model.rename(profile: renaming.id, to: newName) }
                renaming = nil
            }
            Button(Copy.cancel, role: .cancel) { renaming = nil }
        }
    }
}

private struct SubscriptionRow: View {
    let name: String
    let count: Int
    let active: Bool
    let expanded: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: GSpacing.sm + GSpacing.xxs) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: GComponent.iconSizeRegular + GSpacing.xxs))
                    .foregroundStyle(active ? GColor.brandAccent : GColor.textMuted)
                Text(name)
                    .textStyle(GType.titleSmall)
                    .foregroundStyle(GColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: GSpacing.xs)
                Text("\(count)")
                    .textStyle(GType.labelMedium)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(GColor.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: GComponent.iconSizeSmall - GSpacing.xxs, weight: .semibold))
                    .foregroundStyle(GColor.textMuted.opacity(0.72))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(GMotion.animation(GMotion.snappy, reduceMotion: reduceMotion), value: expanded)
            }
            .padding(.horizontal, GSpacing.sm)
            .frame(height: GComponent.subscriptionRowHeight)
        }
        .buttonStyle(HoverRowStyle(selected: false))
        .accessibilityLabel("\(name), \(Copy.servers(count))")
        .accessibilityValue(active ? (expanded ? "развёрнута" : "свёрнута") : "не выбрана")
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(GType.labelSmall)
            .foregroundStyle(GColor.textSubtle)
            .padding(.leading, GSpacing.sm)
            .padding(.top, GSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct CountryFilterChip: View {
    let code: String
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: GSpacing.xs + GSpacing.xxs) {
                Text(flagEmoji(code) ?? "")
                Text(Copy.countryName(code))
                    .textStyle(GType.labelMedium)
                Image(systemName: "xmark")
                    .font(.system(size: GComponent.iconSizeSmall - GSpacing.xxs, weight: .bold))
            }
            .foregroundStyle(GColor.brandAccent)
            .padding(.horizontal, GSpacing.md)
            .padding(.vertical, GSpacing.xs + GSpacing.xxs)
            .background(GColor.brandAccent.opacity(GComponent.tagFillOpacity), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Показать серверы всех стран")
        .accessibilityLabel("Фильтр: \(Copy.countryName(code)). Снять фильтр")
    }
}

// MARK: - Карточки серверов

/// Индикатор выбора: перетекает между карточками на `snappy`.
private struct SelectionIndicator: View {
    let namespace: Namespace.ID

    var body: some View {
        RoundedRectangle(cornerRadius: GRadius.control + GSpacing.xxs, style: .continuous)
            .fill(GMaterial.selectionFill)
            .matchedGeometryEffect(id: "selection", in: namespace)
    }
}

private struct AutoCard: View {
    @Environment(AppModel.self) private var model
    let namespace: Namespace.ID

    var body: some View {
        let selected = model.snapshot.autoSelected
        let target = selected && model.isConnected ? model.activeServer : nil
        Button {
            model.selectAuto()
        } label: {
            HStack(spacing: GSpacing.sm + GSpacing.xxs) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: GComponent.iconSizeRegular))
                    .foregroundStyle(GColor.brandAccent)
                    .frame(width: GComponent.serverLeadSize, height: GComponent.serverLeadSize)
                    .background(GColor.brandAccent.opacity(GComponent.tagFillOpacity), in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Copy.autoServerTitle)
                        .textStyle(GType.titleSmall)
                        .fontWeight(selected ? .semibold : .medium)
                        .foregroundStyle(GColor.textPrimary)
                    Text(target.map { "Сейчас: \(Copy.serverTitle($0))" } ?? "Выберет лучший доступный сервер")
                        .textStyle(GType.bodySmall)
                        .foregroundStyle(GColor.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: GSpacing.sm)
                PingLabel(delay: target?.delayMs)
            }
            .padding(EdgeInsets(top: GSpacing.sm, leading: GSpacing.sm, bottom: GSpacing.sm, trailing: GSpacing.xs + GSpacing.xxs))
        }
        .buttonStyle(HoverRowStyle(selected: selected, namespace: namespace))
        .accessibilityLabel(Copy.autoServerTitle)
        .accessibilityHint(Copy.autoSubtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ServerCard: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    let server: CoreServer
    let namespace: Namespace.ID

    var body: some View {
        let selected = model.isSelected(server)
        let active = model.isConnected && model.snapshot.activeTag == server.tag
        Button {
            model.select(server: server.tag)
        } label: {
            HStack(spacing: GSpacing.sm + GSpacing.xxs) {
                Group {
                    if let flag = flagEmoji(server.countryCode) {
                        Text(flag).font(.system(size: GComponent.serverFlagSize))
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: GComponent.iconSizeRegular))
                            .foregroundStyle(GColor.brandAccent)
                            .frame(width: GComponent.serverLeadSize, height: GComponent.serverLeadSize)
                            .background(GColor.brandAccent.opacity(GComponent.tagFillOpacity), in: .circle)
                    }
                }
                .frame(width: GComponent.serverLeadSize, height: GComponent.serverLeadSize)
                .accessibilityHidden(true)
                Text(server.name)
                    .textStyle(GType.titleSmall)
                    .fontWeight(selected ? .semibold : .medium)
                    .foregroundStyle(GColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: GSpacing.sm)
                if active {
                    Circle()
                        .fill(GColor.statusSuccess)
                        .frame(width: GComponent.statusDotSize, height: GComponent.statusDotSize)
                        .accessibilityHidden(true)
                }
                PingLabel(delay: server.delayMs)
            }
            .padding(EdgeInsets(top: GSpacing.sm, leading: GSpacing.sm, bottom: GSpacing.sm, trailing: GSpacing.xs + GSpacing.xxs))
        }
        .buttonStyle(HoverRowStyle(selected: selected, namespace: namespace))
        .onHover { hovering in
            // Наведение на сервер подсвечивает его страну на планете.
            guard let code = server.mapCountryCode else { return }
            if hovering {
                ui.highlightedCountry = code
            } else if ui.highlightedCountry == code {
                ui.highlightedCountry = nil
            }
        }
        .contextMenu {
            Button("Подключиться через этот сервер") {
                model.select(server: server.tag)
                if !model.isConnected { model.connect() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name), \(Copy.delayAccessibility(server.delayMs))\(active ? ", подключено" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Задержка: «N мс» цветом по порогам, «нет» — не ответил, «—» — не
/// проверяли. Смена числа — прокрутка цифр на `snappy`.
struct PingLabel: View {
    let delay: Int64?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(label)
            .textStyle(GType.labelMedium)
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(value: Double(delay ?? 0)))
            .animation(GMotion.animation(GMotion.snappy, reduceMotion: reduceMotion), value: delay)
    }

    private var label: String {
        guard let delay else { return "—" }
        return delay > 0 ? Copy.delay(delay) : "нет"
    }

    private var color: DynamicColor {
        guard let delay else { return GColor.textSubtle }
        return delay > 0 ? pingColor(delay) : GColor.statusDanger
    }
}

/// Строка списка: вся нажимается, подсветка при наведении, индикатор выбора.
private struct HoverRowStyle: ButtonStyle {
    let selected: Bool
    var namespace: Namespace.ID?

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration, selected: selected, namespace: namespace)
    }
}

private struct HoverRow: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let namespace: Namespace.ID?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GRadius.control + GSpacing.xxs, style: .continuous)
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(hovering || configuration.isPressed ? GMaterial.controlFill : GMaterial.controlFill.opacity(0))
                    if selected, let namespace {
                        SelectionIndicator(namespace: namespace)
                    }
                }
            }
            .contentShape(shape)
            .pressFeedback(pressed: configuration.isPressed, scale: GMotion.pressScaleCard)
            .onHover { hovering = $0 }
            .animation(GMotion.hover.animation, value: hovering)
            .animation(GMotion.animation(GMotion.snappy, reduceMotion: reduceMotion), value: selected)
    }
}

// MARK: - Пусто

private struct EmptyServers: View {
    @Environment(UIState.self) private var ui

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "globe.europe.africa")
                .font(.system(size: GComponent.iconSizeLarge + GSpacing.sm, weight: .regular))
                .foregroundStyle(GColor.textMuted)
                .frame(width: GComponent.emptyServersIconSize, height: GComponent.emptyServersIconSize)
                .background(GMaterial.controlFill, in: .circle)
                .accessibilityHidden(true)
            Text("Нет серверов")
                .textStyle(GType.titleMedium)
                .foregroundStyle(GColor.textPrimary)
                .padding(.top, GSpacing.lg)
            Text("Добавьте подписку — её серверы появятся здесь и на планете.")
                .textStyle(GType.bodySmall)
                .foregroundStyle(GColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, GSpacing.xs)
            Button {
                ui.showingAddSubscription = true
            } label: {
                Label(Copy.addSubscription, systemImage: "plus")
            }
            .buttonStyle(GButtonStyle(.primary))
            .padding(.top, GSpacing.lg)
        }
        .padding(.horizontal, GSpacing.xl)
    }
}
