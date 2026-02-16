import AppKit
import SwiftUI

struct PortsPopoverView: View {
    @ObservedObject var viewModel: PortsViewModel

    @State private var editingServiceID: String?
    @State private var renameDraft: String = ""
    @State private var showAddServiceSheet = false
    @State private var editingServiceData: PortsViewModel.ServiceEditorData?
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

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("My Services")

            ForEach(viewModel.serviceSnapshots) { service in
                serviceCard(service)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                viewModel.refreshNow()
            }
            .buttonStyle(.borderedProminent)

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
        let canStartOrStop = isRunning || service.canStart

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                serviceNameEditor(service)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: "\(service.url) · \(viewModel.stateText(for: service.state))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.tail)

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
                            : (canStartOrStop ? .blue.opacity(0.90) : .white.opacity(0.40))
                    ) {
                        if isRunning {
                            viewModel.stopService(service.id, force: false)
                        } else {
                            viewModel.startService(service.id)
                        }
                    }
                    .disabled(!canStartOrStop)
                    .opacity(canStartOrStop ? 1 : 0.7)
                    .help(isRunning ? "Stop" : (service.canStart ? "Start" : "Start not configured"))

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
    @ObservedObject var viewModel: PortsViewModel
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var address: String = "http://localhost:"
    @State private var workingDirectory: String = ""
    @State private var startCommand: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Service Card")
                .font(.title3.weight(.semibold))

            field("Name", text: $name, placeholder: "My API")
            field("Address", text: $address, placeholder: "http://localhost:3000")
            projectFolderField
            field("Start Command (Optional)", text: $startCommand, placeholder: "npm run dev")

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
        do {
            try viewModel.addCustomService(
                name: name,
                address: address,
                workingDirectory: workingDirectory,
                startCommand: startCommand
            )
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EditServiceSheet: View {
    @ObservedObject var viewModel: PortsViewModel
    let serviceData: PortsViewModel.ServiceEditorData
    @Environment(\.dismiss) private var dismiss

    @State private var address: String
    @State private var workingDirectory: String
    @State private var startCommand: String
    @State private var errorMessage: String?

    init(viewModel: PortsViewModel, serviceData: PortsViewModel.ServiceEditorData) {
        self.viewModel = viewModel
        self.serviceData = serviceData
        _address = State(initialValue: serviceData.address)
        _workingDirectory = State(initialValue: serviceData.workingDirectory)
        _startCommand = State(initialValue: serviceData.startCommand)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Service")
                .font(.title3.weight(.semibold))

            Text(serviceData.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            field("Address", text: $address, placeholder: "http://localhost:3000")
            projectFolderField
            field("Start Command (Optional)", text: $startCommand, placeholder: "npm run dev")

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
        do {
            try viewModel.updateService(
                id: serviceData.id,
                address: address,
                workingDirectory: workingDirectory,
                startCommand: startCommand
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
