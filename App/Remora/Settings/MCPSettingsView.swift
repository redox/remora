import AppKit
import ClientConfig
import Lifecycle
import os
import SwiftUI

/// One client row's state: its status and what the last action left to say.
private struct ClientRowState {
    var status: ClientStatus?
    var busy = false
    var changed = false
    var backup: URL?
    var error: String?
}

struct MCPSettingsView: View {
    /// Computed from the running bundle (symlinks resolved), so it is right wherever Remora is installed.
    static var toolPath: String { ServerLocation.toolPath(bundleURL: Bundle.main.bundleURL) }

    /// The bundle path Connect and Update are checked against, resolved like `toolPath`.
    private static var bundlePath: String { Bundle.main.bundleURL.resolvingSymlinksInPath().path }

    /// Remora sits in /Applications or ~/Applications (not a disk image, Downloads or a
    /// translocation folder).
    static var isInstalled: Bool {
        InstallLocation.classify(bundlePath: bundlePath, homeDirectory: NSHomeDirectory()).isInstalled
    }

    /// The one guard for writing Remora into a client's config (Connect, Update, Copy config):
    /// refused when Remora isn't installed in Applications (Plan 6's caption), or when this copy
    /// is translocated or has no runnable `remora-mcp`. Nil when allowed; otherwise the caption.
    static var installRefusal: String? {
        ServerLocation.refusal(isInstalled: isInstalled, notInstalledMessage: LaunchCopy.mcpNotInstalled,
                               bundlePath: bundlePath,
                               toolIsExecutable: FileManager.default.isExecutableFile(atPath: toolPath))
    }

    /// Connect, Update and Copy config may run.
    static var canRegister: Bool { installRefusal == nil }

    private static let log = Logger(subsystem: "dev.remora", category: "clientconfig")

    @State private var rows: [MCPClient: ClientRowState] = [:]
    @State private var confirmDisconnect: MCPClient?
    private let registrar = Self.makeRegistrar()

    private var snippets: [(title: String, text: String)] {
        let path = Self.toolPath
        let quoted = Self.shellQuote(path)
        return [
            ("Claude Code", "claude mcp add --scope user remora \(quoted)"),
            ("Codex", "codex mcp add remora -- \(quoted)"),
            ("Other clients (JSON)", Self.jsonSnippet(path: path)),
        ]
    }

    /// Always single-quoted, with embedded single quotes escaped.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func jsonSnippet(path: String) -> String {
        let escaped = (try? JSONEncoder().encode(path)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\""
        return "{\"mcpServers\":{\"remora\":{\"command\":\(escaped.replacingOccurrences(of: "\\/", with: "/"))}}}"
    }

    /// The real home directory and processes; `appInstalled` asks Launch Services.
    private static func makeRegistrar() -> ClientRegistrar {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runner = ProcessRunner(home: home)
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let locator = ExecutableLocator(
            home: home,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) },
            // The locator only passes names made of [A-Za-z0-9._-].
            loginShellLookup: { name in
                let r = await runner.run(URL(fileURLWithPath: shell), ["-l", "-c", "command -v \(name)"], timeout: .seconds(5))
                return r.status == 0 ? r.stdout : nil
            })
        return ClientRegistrar(
            home: home, serverPath: toolPath, runner: runner, locator: locator,
            appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            writer: SafeFileWriter(now: { Date() }))
    }

    var body: some View {
        Form {
            Section {
                Text("Let AI tools like Claude Code, Codex, or Cursor search what you have seen on your Mac. The server is read-only, runs locally, and works even when Remora is not running.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Server") {
                    Text(Self.toolPath).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                }
            }
            let refusal = Self.installRefusal
            if let refusal {
                Text(refusal).font(.callout).foregroundStyle(.orange)
            }
            Section {
                ForEach(MCPClient.allCases, id: \.self) { row($0) }
            } header: {
                Text("Apps")
            } footer: {
                Text("Remora edits only its own entry, keeps a backup next to the file, and never changes files it can't read back exactly.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Other apps") {
                ForEach(snippets, id: \.title) { snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snippet.title).font(.subheadline.bold())
                        Text(snippet.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy config") { Self.copy(snippet.text) }
                            .disabled(refusal != nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshAll() }
        .alert(confirmDisconnect.map { "Remove Remora from \($0.displayName)?" } ?? "",
               isPresented: Binding(get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } }),
               presenting: confirmDisconnect) { client in
            Button("Remove", role: .destructive) { run(client, connect: false) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Rows

    @ViewBuilder private func row(_ client: MCPClient) -> some View {
        let state = rows[client] ?? ClientRowState()
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(client.displayName)
                Spacer()
                if state.busy || state.status == nil {
                    ProgressView().controlSize(.small)
                } else if let status = state.status {
                    statusLabel(client, status)
                    buttons(client, status)
                }
            }
            if case .cannotEdit(let reason)? = state.status {
                Text("Can't edit its settings safely: \(reason) Use Copy config below.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let error = state.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if state.changed {
                Text("Restart \(client.displayName) to load Remora.").font(.footnote).foregroundStyle(.secondary)
            }
            if let backup = state.backup {
                HStack {
                    Text("Backup: \(backup.lastPathComponent)").font(.footnote).foregroundStyle(.secondary)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func statusLabel(_ client: MCPClient, _ status: ClientStatus) -> some View {
        switch status {
        case .connected: Text("Connected").foregroundStyle(.green)
        case .connectedElsewhere: Text("Connected to another copy of Remora").foregroundStyle(.orange)
        case .notConnected: Text("Not connected").foregroundStyle(.secondary)
        case .notInstalled: Text("Not installed").foregroundStyle(.tertiary)
        case .cannotEdit: Text("Can't edit").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func buttons(_ client: MCPClient, _ status: ClientStatus) -> some View {
        switch status {
        case .connected:
            Button("Disconnect…") { confirmDisconnect = client }
        case .connectedElsewhere:
            Button("Update") { run(client, connect: true) }.disabled(!Self.canRegister)
            Button("Disconnect…") { confirmDisconnect = client }
        case .notConnected:
            Button("Connect") { run(client, connect: true) }.disabled(!Self.canRegister)
        case .notInstalled:
            Button("Connect") {}.disabled(true)
        case .cannotEdit:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func refreshAll() async {
        await withTaskGroup(of: (MCPClient, ClientStatus).self) { group in
            for client in MCPClient.allCases {
                group.addTask { [registrar] in (client, await registrar.status(client)) }
            }
            for await (client, status) in group { rows[client, default: ClientRowState()].status = status }
        }
    }

    private func run(_ client: MCPClient, connect: Bool) {
        // Connect/Update are re-checked here: the button state may be stale.
        if connect, let refusal = Self.installRefusal {
            rows[client, default: ClientRowState()].error = refusal
            return
        }
        rows[client, default: ClientRowState()].busy = true
        rows[client]?.error = nil
        Task {
            let outcome = connect ? await registrar.connect(client) : await registrar.disconnect(client)
            var state = rows[client] ?? ClientRowState()
            switch outcome {
            case .done(let backup):
                state.changed = connect
                if let backup { state.backup = backup }
                Self.log.info("client \(connect ? "connected" : "disconnected", privacy: .public): \(client.rawValue, privacy: .public)")
            case .failed(let message):
                state.error = message
                Self.log.error("client change failed: \(client.rawValue, privacy: .public)")
            }
            state.status = await registrar.status(client)
            state.busy = false
            rows[client] = state
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
