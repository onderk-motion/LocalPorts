import AppKit
import SwiftUI

struct PortsPopoverView: View {
    @ObservedObject var viewModel: PortsViewModel

    @State private var editingServiceID: String?
    @State private var renameDraft: String = ""
    @State private var showAddServiceSheet = false
    @State private var editingServiceData: PortsViewModel.ServiceEditorData?
    @State private var showCreateProfileSheet = false
    @State private var showRenameProfileSheet = false
    @State private var showDeleteProfileAlert = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.14, blue: 0.20),
                    Color(red: 0.08, green: 0.10, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 12) {
                header

                if let message = viewModel.statusMessage {
                    statusBanner(message)
                }

                if viewModel.requiresImportedStartApproval {
                    importTrustBanner
                }

                if !viewModel.hasCompletedOnboarding {
                    onboardingCard
                }

                ScrollView(.vertical, showsIndicators: true) {
                    servicesSection
                }

                footer
            }
            .padding(14)
        }
        .frame(width: 468, height: 620)
        .sheet(isPresented: $showAddServiceSheet) {
            AddServiceSheet(
                viewModel: viewModel,
                isPresented: $showAddServiceSheet
            )
        }
        .sheet(item: $editingServiceData) { data in
            EditServiceSheet(
                viewModel: viewModel,
                serviceData: data
            )
        }
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
                Text("LocalPorts")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 8, height: 8)
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

            ForEach(viewModel.serviceSnapshots) { service in
                serviceCard(service)
            }
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
            Button("Refresh") {
                viewModel.refreshNow()
            }
            .buttonStyle(.borderedProminent)

            Button {
                NotificationCenter.default.post(name: .localPortsOpenSettingsRequested, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .help("Settings")

            Button {
                showAddServiceSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
        }
        .tint(.white.opacity(0.3))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func serviceCard(_ service: PortsViewModel.ServiceSnapshot) -> some View {
        let isRunning = viewModel.isRunning(service.id)
        let isStartLockedByImport = viewModel.isStartBlockedByImportApproval(service.id)
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
                        Text(verbatim: viewModel.primaryStatusSummary(for: service))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                            .truncationMode(.tail)

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

                    iconButton(systemName: "doc.on.doc") {
                        viewModel.copyServiceURL(service.id)
                    }
                    .help("Copy URL")

                    iconButton(
                        systemName: isRunning ? "stop.fill" : "play.fill",
                        tint: isRunning
                            ? .green.opacity(0.90)
                            : (isStartLockedByImport
                                ? .yellow.opacity(0.90)
                                : (canDirectStartOrStop ? .blue.opacity(0.90) : .orange.opacity(0.78)))
                    ) {
                        if isRunning {
                            viewModel.stopService(service.id, force: false)
                        } else if isStartLockedByImport {
                            viewModel.showImportApprovalRequiredMessage()
                        } else if service.canStart {
                            viewModel.startService(service.id)
                        } else {
                            beginEdit(service.id)
                        }
                    }
                    .help(isRunning
                        ? "Stop"
                        : (isStartLockedByImport ? "Trust imported config first" : (service.canStart ? "Start" : "Configure start")))

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
                            .disabled(isStartLockedByImport)
                        }

                        if service.workingDirectory != nil {
                            Button("Show in Finder") {
                                viewModel.showServiceInFinder(service.id)
                            }
                        }

                        Button("Edit") {
                            beginEdit(service.id)
                        }

                        Button("Force Stop", role: .destructive) {
                            viewModel.stopService(service.id, force: true)
                        }

                        if !service.isBuiltIn {
                            Divider()
                            Button("Remove Card", role: .destructive) {
                                viewModel.removeService(service.id)
                                if editingServiceID == service.id {
                                    cancelRename()
                                }
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

    private var importTrustBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.yellow.opacity(0.92))

            Text("Imported config is in review mode. Start actions are locked until you trust it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Trust Config") {
                viewModel.approveImportedStartCommands()
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow.opacity(0.25))
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.yellow.opacity(0.22), lineWidth: 1)
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
        editingServiceData = viewModel.serviceEditorData(for: serviceID)
    }

    private func appIconImage() -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let bundledImage = NSImage(contentsOf: bundledURL) {
            return bundledImage
        }

        return nil
    }
}

private struct AddServiceSheet: View {
    private struct CommandPreset: Identifiable {
        let id: String
        let title: String
        let command: String
    }

    @ObservedObject var viewModel: PortsViewModel
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var address: String = "http://localhost:"
    @State private var healthCheckURL: String = ""
    @State private var workingDirectory: String = ""
    @State private var startCommand: String = ""
    @State private var useGlobalBrowser: Bool = true
    @State private var selectedBrowserBundleID: String = ""
    @State private var errorMessage: String?
    @State private var validationMessage: String?
    @State private var validationIsError = false

    private let presets: [CommandPreset] = [
        CommandPreset(id: "npm-dev", title: "npm dev", command: "npm run dev"),
        CommandPreset(id: "pnpm-dev", title: "pnpm dev", command: "pnpm dev"),
        CommandPreset(id: "yarn-dev", title: "yarn dev", command: "yarn dev"),
        CommandPreset(id: "node-server", title: "node server", command: "node server.js")
    ]

    private var browsers: [ActionsService.BrowserOption] {
        viewModel.availableBrowsers()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Service Card")
                .font(.title3.weight(.semibold))

            field("Name", text: $name, placeholder: "My API")
            field("Address", text: $address, placeholder: "http://localhost:3000")
            field("Health Check URL (Optional)", text: $healthCheckURL, placeholder: "http://localhost:3000/health")
            projectFolderField
            field("Start Command (Optional)", text: $startCommand, placeholder: "npm run dev")
            commandPresetBar
            commandValidationRow
            browserSection

            Text("Start requires both Project Folder and Start Command.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Card") {
                    addService()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            ensureBrowserSelection()
        }
        .onChange(of: useGlobalBrowser) { newValue in
            if !newValue {
                ensureBrowserSelection()
            }
        }
    }

    private var commandPresetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    Button(preset.title) {
                        startCommand = preset.command
                        errorMessage = nil
                        validationMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var commandValidationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test Command") {
                    validateStartSetup()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(validationIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var projectFolderField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Project Folder (Optional)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("/Users/you/project", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)

                Button("Browse...") {
                    chooseProjectFolder()
                }
            }
        }
    }

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use browser from Settings", isOn: $useGlobalBrowser)
                .font(.caption.weight(.semibold))

            if !useGlobalBrowser {
                if browsers.isEmpty {
                    Text("No browsers were detected. Enable this toggle to use system/default behavior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Browser for this service", selection: $selectedBrowserBundleID) {
                        ForEach(browsers) { browser in
                            Text(browser.name).tag(browser.bundleIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"

        if !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        }

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func addService() {
        guard useGlobalBrowser || !selectedBrowserBundleID.isEmpty else {
            errorMessage = "Choose a browser for this service or enable browser from Settings."
            return
        }

        do {
            try viewModel.addCustomService(
                name: name,
                address: address,
                healthCheckURL: healthCheckURL,
                workingDirectory: workingDirectory,
                startCommand: startCommand,
                useGlobalBrowser: useGlobalBrowser,
                selectedBrowserBundleID: useGlobalBrowser ? nil : selectedBrowserBundleID
            )
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validateStartSetup() {
        do {
            let message = try viewModel.validateStartConfiguration(
                workingDirectory: workingDirectory,
                startCommand: startCommand
            )
            validationMessage = message
            validationIsError = false
            errorMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            validationIsError = true
        }
    }

    private func ensureBrowserSelection() {
        if selectedBrowserBundleID.isEmpty {
            selectedBrowserBundleID = browsers.first?.bundleIdentifier ?? ""
        }
    }
}

private struct EditServiceSheet: View {
    private struct CommandPreset: Identifiable {
        let id: String
        let title: String
        let command: String
    }

    @ObservedObject var viewModel: PortsViewModel
    let serviceData: PortsViewModel.ServiceEditorData
    @Environment(\.dismiss) private var dismiss

    @State private var address: String
    @State private var healthCheckURL: String
    @State private var workingDirectory: String
    @State private var startCommand: String
    @State private var useGlobalBrowser: Bool
    @State private var selectedBrowserBundleID: String
    @State private var errorMessage: String?
    @State private var validationMessage: String?
    @State private var validationIsError = false

    private let presets: [CommandPreset] = [
        CommandPreset(id: "npm-dev", title: "npm dev", command: "npm run dev"),
        CommandPreset(id: "pnpm-dev", title: "pnpm dev", command: "pnpm dev"),
        CommandPreset(id: "yarn-dev", title: "yarn dev", command: "yarn dev"),
        CommandPreset(id: "node-server", title: "node server", command: "node server.js")
    ]

    private var browsers: [ActionsService.BrowserOption] {
        viewModel.availableBrowsers()
    }

    init(viewModel: PortsViewModel, serviceData: PortsViewModel.ServiceEditorData) {
        self.viewModel = viewModel
        self.serviceData = serviceData
        _address = State(initialValue: serviceData.address)
        _healthCheckURL = State(initialValue: serviceData.healthCheckURL)
        _workingDirectory = State(initialValue: serviceData.workingDirectory)
        _startCommand = State(initialValue: serviceData.startCommand)
        _useGlobalBrowser = State(initialValue: serviceData.usesGlobalBrowser)
        _selectedBrowserBundleID = State(initialValue: serviceData.browserBundleID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Service")
                .font(.title3.weight(.semibold))

            Text(serviceData.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            field("Address", text: $address, placeholder: "http://localhost:3000")
            field("Health Check URL (Optional)", text: $healthCheckURL, placeholder: "http://localhost:3000/health")
            projectFolderField
            field("Start Command (Optional)", text: $startCommand, placeholder: "npm run dev")
            commandPresetBar
            commandValidationRow
            browserSection

            Text("Start requires both Project Folder and Start Command.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            ensureBrowserSelection()
        }
        .onChange(of: useGlobalBrowser) { newValue in
            if !newValue {
                ensureBrowserSelection()
            }
        }
    }

    private var commandPresetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    Button(preset.title) {
                        startCommand = preset.command
                        errorMessage = nil
                        validationMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var commandValidationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test Command") {
                    validateStartSetup()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(validationIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var projectFolderField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Project Folder (Optional)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("/Users/you/project", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)

                Button("Browse...") {
                    chooseProjectFolder()
                }
            }
        }
    }

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use browser from Settings", isOn: $useGlobalBrowser)
                .font(.caption.weight(.semibold))

            if !useGlobalBrowser {
                if browsers.isEmpty {
                    Text("No browsers were detected. Enable this toggle to use system/default behavior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Browser for this service", selection: $selectedBrowserBundleID) {
                        ForEach(browsers) { browser in
                            Text(browser.name).tag(browser.bundleIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"

        if !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        }

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func save() {
        guard useGlobalBrowser || !selectedBrowserBundleID.isEmpty else {
            errorMessage = "Choose a browser for this service or enable browser from Settings."
            return
        }

        do {
            try viewModel.updateService(
                id: serviceData.id,
                address: address,
                healthCheckURL: healthCheckURL,
                workingDirectory: workingDirectory,
                startCommand: startCommand,
                useGlobalBrowser: useGlobalBrowser,
                selectedBrowserBundleID: useGlobalBrowser ? nil : selectedBrowserBundleID
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validateStartSetup() {
        do {
            let message = try viewModel.validateStartConfiguration(
                workingDirectory: workingDirectory,
                startCommand: startCommand
            )
            validationMessage = message
            validationIsError = false
            errorMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            validationIsError = true
        }
    }

    private func ensureBrowserSelection() {
        if selectedBrowserBundleID.isEmpty {
            selectedBrowserBundleID = browsers.first?.bundleIdentifier ?? ""
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
