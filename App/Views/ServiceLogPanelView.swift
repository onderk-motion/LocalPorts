import AppKit
import SwiftUI

struct ServiceLogPanelView: View {
    let serviceID: String
    let serviceName: String
    @ObservedObject var viewModel: PortsViewModel
    let onClose: () -> Void

    @State private var autoScroll = true

    private var logs: [String] { viewModel.serviceLogs[serviceID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(width: 600, height: 420)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(serviceName)
                .font(.subheadline.weight(.semibold))

            Spacer()

            Toggle(isOn: $autoScroll) {
                Text("Auto-scroll")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button("Copy All") {
                copyAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(logs.isEmpty)

            Button("Clear") {
                viewModel.clearServiceLogs(serviceID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Log Content

    @ViewBuilder
    private var logContent: some View {
        if logs.isEmpty {
            VStack {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Text("No output yet.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Start the service to capture stdout and stderr.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(foregroundColor(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1.5)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: logs.count) { count in
                    guard autoScroll, count > 0 else { return }
                    withAnimation(.none) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
                .onAppear {
                    if !logs.isEmpty {
                        proxy.scrollTo(logs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func foregroundColor(for line: String) -> Color {
        if line.contains("[err]") { return .red }
        return .primary
    }

    private func copyAll() {
        let text = logs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
