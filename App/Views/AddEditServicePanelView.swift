import AppKit
import SwiftUI

// MARK: - Mode

enum AddEditServiceMode {
    case add
    case edit(data: PortsViewModel.ServiceEditorData)
}

// MARK: - Panel View

struct AddEditServicePanelView: View {
    @ObservedObject var viewModel: PortsViewModel
    @ObservedObject private var settings = AppSettingsStore.shared
    let mode: AddEditServiceMode
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    // MARK: Explicit color palette (LSUIElement inactive-safe)
    private var labelColor: Color {
        colorScheme == .dark ? .white.opacity(0.75) : .black.opacity(0.72)
    }
    private var hintColor: Color {
        colorScheme == .dark ? .white.opacity(0.38) : .black.opacity(0.38)
    }
    private var chipBG: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.07)
    }
    private var chipFG: Color {
        colorScheme == .dark ? .white.opacity(0.80) : .black.opacity(0.80)
    }
    private var tabActiveBG: Color {
        colorScheme == .dark ? .white.opacity(0.13) : .black.opacity(0.08)
    }
    private var tabBarBG: Color {
        colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    }

    // MARK: Tabs

    @State private var selectedTab = 0

    // MARK: Fields

    @State private var name: String
    @State private var category: String
    @State private var address: String
    @State private var healthCheckURL: String
    @State private var workingDirectory: String
    @State private var startCommand: String
    @State private var useGlobalBrowser: Bool
    @State private var selectedBrowserBundleID: String
    @State private var notificationsEnabled: Bool
    @State private var autoRestartEnabled: Bool

    // MARK: Validation

    @State private var errorMessage: String?
    @State private var portConflictName: String?
    @State private var validationMessage: String?
    @State private var validationIsError = false

    // MARK: Init

    init(viewModel: PortsViewModel, mode: AddEditServiceMode, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.mode = mode
        self.onDismiss = onDismiss

        switch mode {
        case .add:
            _name = State(initialValue: "")
            _category = State(initialValue: "")
            _address = State(initialValue: "http://localhost:")
            _healthCheckURL = State(initialValue: "")
            _workingDirectory = State(initialValue: "")
            _startCommand = State(initialValue: "")
            _useGlobalBrowser = State(initialValue: true)
            _selectedBrowserBundleID = State(initialValue: "")
            _notificationsEnabled = State(initialValue: true)
            _autoRestartEnabled = State(initialValue: false)

        case .edit(let data):
            _name = State(initialValue: data.name)
            _category = State(initialValue: data.category)
            _address = State(initialValue: data.address)
            _healthCheckURL = State(initialValue: data.healthCheckURL)
            _workingDirectory = State(initialValue: data.workingDirectory)
            _startCommand = State(initialValue: data.startCommand)
            _useGlobalBrowser = State(initialValue: data.usesGlobalBrowser)
            _selectedBrowserBundleID = State(initialValue: data.browserBundleID ?? "")
            _notificationsEnabled = State(initialValue: data.notificationsEnabled)
            _autoRestartEnabled = State(initialValue: data.autoRestartEnabled)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar
            tabBar
                .padding(.horizontal, 16)
                .padding(.top, isEditing ? 8 : 16)
                .padding(.bottom, 12)

            Divider()

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                if selectedTab == 0 {
                    mainContent
                        .padding(16)
                } else {
                    advancedContent
                        .padding(16)
                }
            }
            .groupBoxStyle(PanelCardStyle(isDark: colorScheme == .dark))

            Divider()

            // Footer
            panelFooter
        }
        .frame(width: 460)
        .onAppear {
            settings.refreshAvailableBrowsers()
            ensureBrowserSelection()
        }
        .onChange(of: useGlobalBrowser) { newValue in
            if !newValue { ensureBrowserSelection() }
        }
    }

    // MARK: Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(title: "Main", icon: "slider.horizontal.3", index: 0)
            tabButton(title: "Advanced", icon: "gearshape", index: 1)
            Spacer()
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tabBarBG)
        )
    }

    private func tabButton(title: String, icon: String, index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = index
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selectedTab == index ? tabActiveBG : Color.clear)
                    .shadow(color: selectedTab == index ? .black.opacity(0.15) : .clear, radius: 2, y: 1)
            )
            .foregroundStyle(
                selectedTab == index
                    ? (colorScheme == .dark ? Color.white : Color.black)
                    : labelColor
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Main Tab

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Service (required) ──
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    // Name
                    inlineField("Name", text: $name, placeholder: "My API")

                    // Address
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Address")
                        TextField("http://localhost:3000", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: address) { newValue in
                                let port = URL(string: newValue)?.port
                                if isEditing, case .edit(let data) = mode {
                                    portConflictName = port.flatMap {
                                        viewModel.conflictingServiceName(forPort: $0, excludingID: data.id)
                                    }
                                } else {
                                    portConflictName = port.flatMap {
                                        viewModel.conflictingServiceName(forPort: $0)
                                    }
                                }
                            }
                        if settings.experimentalTCPServicesEnabled {
                            Text("Experimental TCP mode is on. Use an explicit scheme like tcp://localhost:5432 or postgres://localhost:5432 for non-web services.")
                                .font(.caption)
                                .foregroundStyle(hintColor)
                        }
                        if let conflict = portConflictName {
                            Label("Port already used by \(conflict)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            } label: {
                Label("Service", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // ── Launch Configuration ──
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    // Project Folder
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Project Folder", optional: true)
                        HStack(spacing: 8) {
                            TextField("/Users/you/project", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") {
                                chooseProjectFolder()
                            }
                        }
                    }

                    // Start Command
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Start Command", optional: true)
                        TextField("npm run dev", text: $startCommand)
                            .textFieldStyle(.roundedBorder)
                        commandPresetBar
                    }

                    // Test Command
                    commandValidationRow
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            } label: {
                Label("Launch Configuration", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Start requires both Project Folder and Start Command.")
                .font(.caption)
                .foregroundStyle(hintColor)
                .padding(.horizontal, 2)

            // ── Divider before optional section ──
            Divider()
                .padding(.vertical, 2)

            // ── Category (optional) ──
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Frontend, Backend, Database…", text: $category)
                        .textFieldStyle(.roundedBorder)
                    categoryPresetBar
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tag")
                    Text("Category")
                    Text("Optional")
                        .foregroundStyle(hintColor)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    // MARK: Advanced Tab

    private var notificationsGroupBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if ProGate.isAllowed(.advancedNotifications) {
                    Toggle("Notify on unexpected stop", isOn: $notificationsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.subheadline)
                    Text("When disabled, crash alerts are silenced for this service only.")
                        .font(.caption)
                        .foregroundStyle(hintColor)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(hintColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Per-service notifications")
                                .font(.subheadline)
                                .foregroundStyle(labelColor)
                            Text("Upgrade to Pro to silence crash alerts per service.")
                                .font(.caption)
                                .foregroundStyle(hintColor)
                        }
                        Spacer()
                        Button("Pro") {
                            NotificationCenter.default.post(name: .localPortsShowUpgradeRequested, object: nil)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        } label: {
            Label("Notifications", systemImage: "bell")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var autoRestartGroupBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if ProGate.isAllowed(.autoRestart) {
                    Toggle("Restart automatically on unexpected stop", isOn: $autoRestartEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.subheadline)
                    Text("Waits 2 seconds, then attempts a single restart. Requires Start Command.")
                        .font(.caption)
                        .foregroundStyle(hintColor)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(hintColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Restart")
                                .font(.subheadline)
                                .foregroundStyle(labelColor)
                            Text("Upgrade to Pro to restart services automatically on crash.")
                                .font(.caption)
                                .foregroundStyle(hintColor)
                        }
                        Spacer()
                        Button("Pro") {
                            NotificationCenter.default.post(name: .localPortsShowUpgradeRequested, object: nil)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        } label: {
            Label("Auto-Restart", systemImage: "arrow.clockwise.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Health Check ──
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("URL", optional: true)
                    TextField("http://localhost:3000/health", text: $healthCheckURL)
                        .textFieldStyle(.roundedBorder)
                    Text("If set, the status indicator reflects this endpoint's response.")
                        .font(.caption)
                        .foregroundStyle(hintColor)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            } label: {
                Label("Health Check", systemImage: "heart.text.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // ── Notifications (Edit only, Pro-gated) ──
            if isEditing {
                notificationsGroupBox
            }

            // ── Auto-Restart (Edit only, Pro-gated) ──
            if isEditing {
                autoRestartGroupBox
            }

            // ── Browser ──
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Use browser from Settings", isOn: $useGlobalBrowser)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.subheadline)

                    if !useGlobalBrowser {
                        if browsers.isEmpty {
                            Text("No browsers detected. Enable the toggle to use system/default behavior.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Picker("Browser", selection: $selectedBrowserBundleID) {
                                ForEach(browsers) { browser in
                                    Text(browser.name).tag(browser.bundleIdentifier)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            } label: {
                Label("Browser", systemImage: "safari")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var panelFooter: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack {
                    Label(errorMessage, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? "Save" : "Add Service") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: Reusable Subviews

    private var categoryPresetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["Frontend", "Backend", "Database", "Tools", "Mobile"], id: \.self) { preset in
                    let isSelected = category == preset
                    Button(preset) {
                        category = isSelected ? "" : preset
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor : chipBG)
                    )
                    .foregroundStyle(isSelected ? Color.white : chipFG)
                }
            }
        }
    }

    private var commandPresetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(commandPresets) { preset in
                    Button(preset.title) {
                        startCommand = preset.command
                        errorMessage = nil
                        validationMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(chipBG)
                    )
                    .foregroundStyle(chipFG)
                }
            }
        }
    }

    private var commandValidationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Test Command") {
                validateStartSetup()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(validationIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func inlineField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func fieldLabel(_ title: String, optional: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(labelColor)
            if optional {
                Text("Optional")
                    .font(.caption2)
                    .foregroundStyle(hintColor)
            }
        }
    }

    // MARK: Helpers

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var browsers: [ActionsService.BrowserOption] {
        settings.availableBrowsers
    }

    private struct CommandPreset: Identifiable {
        let id: String
        let title: String
        let command: String
    }

    private let commandPresets: [CommandPreset] = [
        CommandPreset(id: "npm-dev",     title: "npm dev",    command: "npm run dev"),
        CommandPreset(id: "pnpm-dev",    title: "pnpm dev",   command: "pnpm dev"),
        CommandPreset(id: "yarn-dev",    title: "yarn dev",   command: "yarn dev"),
        CommandPreset(id: "node-server", title: "node server", command: "node server.js")
    ]

    // MARK: Actions

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

    private func trimmedCategory() -> String? {
        let t = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func save() {
        guard useGlobalBrowser || !selectedBrowserBundleID.isEmpty else {
            errorMessage = "Choose a browser or enable browser from Settings."
            return
        }

        do {
            switch mode {
            case .add:
                try viewModel.addCustomService(
                    name: name,
                    address: address,
                    healthCheckURL: healthCheckURL,
                    workingDirectory: workingDirectory,
                    startCommand: startCommand,
                    useGlobalBrowser: useGlobalBrowser,
                    selectedBrowserBundleID: useGlobalBrowser ? nil : selectedBrowserBundleID,
                    category: trimmedCategory()
                )
            case .edit(let data):
                try viewModel.updateService(
                    id: data.id,
                    name: name,
                    address: address,
                    healthCheckURL: healthCheckURL,
                    workingDirectory: workingDirectory,
                    startCommand: startCommand,
                    useGlobalBrowser: useGlobalBrowser,
                    selectedBrowserBundleID: useGlobalBrowser ? nil : selectedBrowserBundleID,
                    category: trimmedCategory(),
                    notificationsEnabled: notificationsEnabled,
                    autoRestart: autoRestartEnabled
                )
            }
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Custom GroupBox Style (LSUIElement inactive-safe)

private struct PanelCardStyle: GroupBoxStyle {
    let isDark: Bool

    private var cardBG: Color    { isDark ? .white.opacity(0.07) : .black.opacity(0.04) }
    private var cardBorder: Color { isDark ? .white.opacity(0.16) : .black.opacity(0.12) }
    private var labelFG: Color   { isDark ? .white.opacity(0.65) : .black.opacity(0.65) }

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .foregroundStyle(labelFG)
            configuration.content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(cardBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(cardBorder, lineWidth: 1)
                        )
                )
        }
    }
}
