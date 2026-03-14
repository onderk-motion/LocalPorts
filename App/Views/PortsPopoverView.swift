import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PortsPopoverView: View {
    @ObservedObject var viewModel: PortsViewModel

    @State private var editingServiceID: String?
    @State private var renameDraft: String = ""
    @State private var showCreateProfileSheet = false
    @State private var showRenameProfileSheet = false
    @State private var showDeleteProfileAlert = false
    @State private var importErrorMessage: String?
    @State private var showImportErrorAlert = false
    @FocusState private var renameFocused: Bool
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var searchText: String = ""
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var draggingID: String? = nil
    @State private var dropTargetID: String? = nil

    var body: some View {
        ZStack {
            settings.backgroundTheme.gradient

            VStack(alignment: .leading, spacing: 12) {
                header

                if let message = viewModel.statusMessage {
                    statusBanner(message)
                }

                if !viewModel.hasCompletedOnboarding {
                    onboardingCard
                }

                ZStack(alignment: .topTrailing) {
                    ScrollView(.vertical, showsIndicators: false) {
                        servicesSection
                            .padding(.trailing, 14)
                            .background(
                                ScrollOffsetReader(
                                    scrollOffset: $scrollOffset,
                                    contentHeight: $contentHeight,
                                    viewportHeight: $viewportHeight
                                )
                            )
                    }
                    CustomScrollbarThumb(
                        contentHeight: contentHeight,
                        viewportHeight: viewportHeight,
                        scrollOffset: scrollOffset
                    )
                }

                footer
            }
            .padding(14)
        }
        .frame(width: 468, height: 620)
        .sheet(isPresented: $showCreateProfileSheet) {
            ProfileNameSheet(
                title: "Create Profile",
                actionTitle: "Create",
                initialName: ""
            ) { newName in
                try viewModel.createProfile(named: newName)
            }
        }
        .sheet(isPresented: $showRenameProfileSheet) {
            ProfileNameSheet(
                title: "Rename Profile",
                actionTitle: "Save",
                initialName: viewModel.activeProfileName
            ) { updatedName in
                try viewModel.renameActiveProfile(to: updatedName)
            }
        }
        .alert("Delete current profile?", isPresented: $showDeleteProfileAlert) {
            Button("Delete", role: .destructive) {
                try? viewModel.deleteActiveProfile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved services in \"\(viewModel.activeProfileName)\". This action cannot be undone.")
        }
        .alert("Import Failed", isPresented: $showImportErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "Unknown error.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = appIconImage() {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("LocalPorts")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(appBuild)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    #if DEBUG
                    Text("DEV")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
                    #endif
                }
            }

            Spacer()

            if license.isProActive {
                Text("PRO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(settings.accentColor, in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button("Upgrade to Pro") {
                    NotificationCenter.default.post(name: .localPortsShowUpgradeRequested, object: nil)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settings.accentColor)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(settings.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(settings.accentColor.opacity(0.35), lineWidth: 1)
                )
            }
        }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to LocalPorts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Text("Use + to add your projects, then use Start/Stop buttons to control them. Right-click the menu bar icon for Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            Button("Got It") {
                viewModel.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            profileSection
            sectionTitle("Services")

            if viewModel.serviceSnapshots.count >= 5 {
                searchField
            }

            if filteredSnapshots.isEmpty && !searchText.isEmpty {
                Text("No results for \"\(searchText)\"")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 10)
            } else {
                ForEach(groupedSnapshots, id: \.category) { group in
                    if !group.category.isEmpty {
                        Text(group.category.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .tracking(0.8)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                    }
                    ForEach(group.services) { service in
                        serviceCard(service)
                            .opacity(draggingID == service.id ? 0.4 : 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.45), lineWidth: 2)
                                    .opacity(dropTargetID == service.id && draggingID != service.id ? 1 : 0)
                            )
                            .onDrag {
                                draggingID = service.id
                                return NSItemProvider(object: service.id as NSString)
                            }
                            .onDrop(of: [UTType.plainText], delegate: ServiceDropDelegate(
                                targetID: service.id,
                                viewModel: viewModel,
                                draggingID: $draggingID,
                                dropTargetID: $dropTargetID
                            ))
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            TextField("Filter services…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.white)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var filteredSnapshots: [PortsViewModel.ServiceSnapshot] {
        guard !searchText.isEmpty else { return viewModel.serviceSnapshots }
        return viewModel.serviceSnapshots.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedSnapshots: [(category: String, services: [PortsViewModel.ServiceSnapshot])] {
        let snapshots = filteredSnapshots
        var order: [String] = []
        var seen = Set<String>()
        for s in snapshots {
            let key = s.category ?? ""
            if !seen.contains(key) { seen.insert(key); order.append(key) }
        }
        return order.map { key in
            (category: key, services: snapshots.filter { ($0.category ?? "") == key })
        }
    }

    private var profileSection: some View {
        HStack(spacing: 8) {
            Text("Profile")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))

            Spacer()

            Menu {
                ForEach(viewModel.profileSummaries) { profile in
                    Button {
                        viewModel.switchProfile(profile.id)
                    } label: {
                        if profile.id == viewModel.activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }

                Divider()

                Button("New Profile…") {
                    showCreateProfileSheet = true
                }

                Button("Rename Current…") {
                    showRenameProfileSheet = true
                }

                Button("Delete Current…", role: .destructive) {
                    showDeleteProfileAlert = true
                }
                .disabled(viewModel.profileSummaries.count <= 1)

                Divider()

                Button("Export Profile…") {
                    exportActiveProfile()
                }

                Button("Import Profile…") {
                    importProfileFromFile()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption.weight(.semibold))
                    Text(viewModel.activeProfileName)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            Button {
                viewModel.setProfileAutoStart(!viewModel.activeProfileAutoStart)
            } label: {
                Image(systemName: viewModel.activeProfileAutoStart ? "bolt.fill" : "bolt.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(viewModel.activeProfileAutoStart ? 0.85 : 0.35))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(viewModel.activeProfileAutoStart ? "Auto-start: On — services start automatically" : "Auto-start: Off")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            footerButton("Refresh", prominent: true) {
                viewModel.refreshNow()
            }
            .keyboardShortcut("r", modifiers: .command)

            footerIconButton("gearshape") {
                NotificationCenter.default.post(name: .localPortsOpenSettingsRequested, object: nil)
            }
            .help("Settings")

            footerIconButton("plus") {
                NotificationCenter.default.post(name: .localPortsOpenAddServiceRequested, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            footerButton("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func footerButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(prominent ? 0.95 : 0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(prominent ? 0.18 : 0.10))
                )
        }
        .buttonStyle(.plain)
    }

    private func footerIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func serviceCard(_ service: PortsViewModel.ServiceSnapshot) -> some View {
        let isRunning = viewModel.isRunning(service.id)
        let canDirectStartOrStop = isRunning || service.canStart

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                serviceNameEditor(service)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(healthIndicatorColor(for: service.health, isRunning: isRunning))
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                        .help(viewModel.healthText(for: service.health))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(verbatim: viewModel.primaryStatusSummary(for: service))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.70))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if viewModel.isPortOccupiedExternally(service.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange.opacity(0.85))
                                    .help("Port \(service.port) is in use by another process")
                            }
                        }

                        if let secondary = viewModel.secondaryStatusSummary(for: service) {
                            Text(verbatim: secondary)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .help(viewModel.statusTooltip(for: service))
                }

                Spacer(minLength: 0)

                HStack(spacing: 7) {
                    iconButton(systemName: "safari") {
                        viewModel.openService(service.id)
                    }
                    .help("Open")
                    .disabled(!service.canOpenInBrowser)
                    .opacity(service.canOpenInBrowser ? 1 : 0.45)

                    iconButton(systemName: "doc.on.doc") {
                        viewModel.copyServiceURL(service.id)
                    }
                    .help("Copy URL")

                    iconButton(
                        systemName: isRunning ? "stop.fill" : "play.fill",
                        tint: isRunning
                            ? .green.opacity(0.90)
                            : (canDirectStartOrStop ? .blue.opacity(0.90) : .orange.opacity(0.78))
                    ) {
                        if isRunning {
                            viewModel.stopService(service.id, force: false)
                        } else if service.canStart {
                            viewModel.startService(service.id)
                        } else {
                            beginEdit(service.id)
                        }
                    }
                    .help(isRunning
                        ? "Stop"
                        : (service.canStart ? "Start" : "Configure start"))

                    Menu {
                        Button("Rename") {
                            beginRename(service)
                        }

                        if viewModel.hasCustomName(service.id) {
                            Button("Reset Name") {
                                viewModel.resetServiceName(service.id)
                            }
                        }

                        if service.canStart {
                            Button("Restart") {
                                viewModel.restartService(service.id)
                            }
                        }

                        if service.workingDirectory != nil {
                            Button("Show in Finder") {
                                viewModel.showServiceInFinder(service.id)
                            }
                        }

                        Button("Edit") {
                            beginEdit(service.id)
                        }

                        if service.canStart {
                            Button("View Logs…") {
                                NotificationCenter.default.post(
                                    name: .localPortsOpenServiceLogRequested,
                                    object: nil,
                                    userInfo: ["serviceID": service.id, "serviceName": service.name]
                                )
                            }
                        }

                        Button("Force Stop", role: .destructive) {
                            viewModel.stopService(service.id, force: true)
                        }

                        Divider()
                        Button("Remove Card", role: .destructive) {
                            viewModel.removeService(service.id)
                            if editingServiceID == service.id {
                                cancelRename()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 26, height: 26)
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                }
                .frame(width: 125, alignment: .trailing)
            }

            if !service.recentHistory.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(service.recentHistory.enumerated()), id: \.offset) { _, isUp in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isUp ? Color.green.opacity(0.55) : Color.white.opacity(0.15))
                            .frame(width: 7, height: 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func serviceNameEditor(_ service: PortsViewModel.ServiceSnapshot) -> some View {
        if editingServiceID == service.id {
            HStack(spacing: 5) {
                TextField("Service name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline.weight(.semibold))
                    .focused($renameFocused)
                    .frame(width: 180)
                    .onSubmit {
                        commitRename(service.id)
                    }

                Button {
                    commitRename(service.id)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.86))
                }
                .buttonStyle(.plain)

                Button {
                    cancelRename()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 0) {
                Text(service.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .onTapGesture(count: 2) {
                        beginRename(service)
                    }
            }
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.84))
            Spacer()
            Button {
                viewModel.dismissStatusMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.74))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }

    private func healthIndicatorColor(for health: PortsViewModel.ServiceHealthState, isRunning: Bool) -> Color {
        guard isRunning else {
            return .white.opacity(0.22)
        }

        switch health {
        case .healthy:
            return .green.opacity(0.95)
        case .checking:
            return .yellow.opacity(0.92)
        case .unhealthy, .failed:
            return .red.opacity(0.92)
        case .unavailable:
            return .white.opacity(0.35)
        }
    }

    private func iconButton(systemName: String, tint: Color = .white.opacity(0.88), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }

    private func beginRename(_ service: PortsViewModel.ServiceSnapshot) {
        editingServiceID = service.id
        renameDraft = service.name
        renameFocused = true
    }

    private func cancelRename() {
        editingServiceID = nil
        renameDraft = ""
        renameFocused = false
    }

    private func commitRename(_ serviceID: String) {
        viewModel.renameService(serviceID, to: renameDraft)
        cancelRename()
    }

    private func beginEdit(_ serviceID: String) {
        NotificationCenter.default.post(
            name: .localPortsOpenEditServiceRequested,
            object: nil,
            userInfo: ["serviceID": serviceID]
        )
    }

    private var appBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "(\(build))"
    }

    private func appIconImage() -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let bundledImage = NSImage(contentsOf: bundledURL) {
            return bundledImage
        }

        return nil
    }

    private func exportActiveProfile() {
        guard let data = viewModel.exportActiveProfileData() else { return }
        let safeName = viewModel.activeProfileName
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        let panel = NSSavePanel()
        panel.title = "Export Profile"
        panel.nameFieldStringValue = "\(safeName).localports.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                importErrorMessage = error.localizedDescription
                showImportErrorAlert = true
            }
        }
    }

    private func importProfileFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Profile"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try viewModel.importProfile(from: data)
            } catch {
                importErrorMessage = error.localizedDescription
                showImportErrorAlert = true
            }
        }
    }
}

private struct ProfileNameSheet: View {
    let title: String
    let actionTitle: String
    let initialName: String
    let onSubmit: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?

    init(
        title: String,
        actionTitle: String,
        initialName: String,
        onSubmit: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.initialName = initialName
        self.onSubmit = onSubmit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 5) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(actionTitle) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func submit() {
        do {
            try onSubmit(name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Custom Scrollbar

/// NSViewRepresentable that hooks into the parent NSScrollView for reliable scroll tracking.
private struct ScrollOffsetReader: NSViewRepresentable {
    @Binding var scrollOffset: CGFloat
    @Binding var contentHeight: CGFloat
    @Binding var viewportHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.observer == nil else { return }
        DispatchQueue.main.async {
            guard let sv = nsView.enclosingScrollView else { return }
            self.viewportHeight = sv.documentVisibleRect.height
            self.contentHeight  = sv.documentView?.frame.height ?? 0
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: sv,
                queue: .main
            ) { [weak sv] _ in
                guard let sv else { return }
                self.scrollOffset   = sv.documentVisibleRect.minY
                self.contentHeight  = sv.documentView?.frame.height ?? 0
                self.viewportHeight = sv.documentVisibleRect.height
            }
        }
    }

    class Coordinator {
        var observer: Any?
        deinit { if let obs = observer { NotificationCenter.default.removeObserver(obs) } }
    }
}

private struct CustomScrollbarThumb: View {
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let scrollOffset: CGFloat   // positive, 0 at top

    private var isNeeded: Bool { contentHeight > viewportHeight + 1 }

    private var thumbHeight: CGFloat {
        let ratio = viewportHeight / max(contentHeight, 1)
        return max(28, viewportHeight * ratio)
    }

    private var thumbOffset: CGFloat {
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 0 else { return 0 }
        let progress = min(1, max(0, scrollOffset / scrollable))
        return progress * (viewportHeight - thumbHeight)
    }

    var body: some View {
        if isNeeded {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.12))
                .frame(width: 4, height: thumbHeight)
                .offset(y: thumbOffset)
                .padding(.trailing, 3)
                .animation(.linear(duration: 0.05), value: thumbOffset)
        }
    }
}

// MARK: - Drag & Drop

private struct ServiceDropDelegate: DropDelegate {
    let targetID: String
    let viewModel: PortsViewModel
    @Binding var draggingID: String?
    @Binding var dropTargetID: String?

    func dropEntered(info: DropInfo) {
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let fromID = draggingID else { return false }
        viewModel.moveService(fromID: fromID, toID: targetID)
        draggingID = nil
        dropTargetID = nil
        return true
    }
}
