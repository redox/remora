import MeetingImport
import Storage
import SwiftUI

struct MeetingSourcesView: View {
    let env: AppEnvironment
    private var model: MeetingSourcesModel { env.meetingSources }
    @State private var provider: MeetingSource.Provider = .quill
    @State private var endpoint = ""
    @State private var since = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var query = ""
    @State private var matches: [ImportedMeeting] = []
    @State private var selected: ImportedMeeting?
    @State private var disconnecting: MeetingSource?
    @State private var forgetting: ImportedMeeting?
    @State private var searchFailed = false
    @State private var confirmChatAccess = false

    var body: some View {
        Form {
            MeetingRecordingSettingsView(env: env)
            LocalMeetingsSection(model: model)
            Section("Add a source") {
                Picker("Provider", selection: $provider) {
                    ForEach(MeetingSource.Provider.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                if provider != .granola {
                    TextField("Local MCP URL", text: $endpoint, prompt: Text("http://127.0.0.1:8080/mcp"))
                        .autocorrectionDisabled()
                    if provider == .quill {
                        Text("In Quill Settings › MCP Server, enable the local HTTP server and copy its URL.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use a local Streamable HTTP server with read tools for listing meetings and fetching notes or transcripts.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                DatePicker("Import meetings since", selection: $since, in: ...Date.now, displayedComponents: .date)
                Button(provider == .granola ? "Sign in to Granola" : "Connect") {
                    model.connect(provider: provider, endpoint: provider == .granola ? MeetingEndpoint.granola : endpoint,
                                  since: Calendar.current.startOfDay(for: since))
                }
                .disabled(model.connecting || provider != .granola && endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.connecting { ProgressView().controlSize(.small) }
                Text("Imported meetings are stored and searchable on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            if !model.sources.isEmpty {
                Section("Connected sources") {
                    ForEach(model.sources) { source in
                        LabeledContent {
                            Button("Sync") {
                                model.syncNow(source, since: Calendar.current.startOfDay(for: since))
                            }
                            .disabled(model.syncing.contains(source.id))
                            Button("Disconnect…") { disconnecting = source }
                        } label: {
                            Text(source.provider.title)
                            if model.syncing.contains(source.id) {
                                Text("Syncing…")
                            } else if let status = model.statuses[source.id] {
                                Text(status)
                            }
                        }
                    }
                }
                Section("Chat access") {
                    Toggle("Let Remora chat search imported meetings", isOn: Binding(
                        get: { model.chatAccessEnabled }, set: { enabled in
                            if enabled { confirmChatAccess = true } else { model.setChatAccess(false) }
                        }))
                    Text("When enabled, relevant meeting excerpts can be sent to OpenAI through your ChatGPT account when you use Remora chat.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Imported meetings") {
                    TextField("Search meetings", text: $query)
                    if searchFailed { Text("Could not search meetings.").foregroundStyle(.red) }
                    if matches.isEmpty, !searchFailed {
                        Text(query.isEmpty ? "No imported meetings." : "No matching meetings.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(matches) { meeting in
                        Button {
                            selected = meeting
                        } label: {
                            LabeledContent(meeting.title, value: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: SearchInput(query: query, revision: model.revision)) { await search() }
        .alert("Allow chat to use imported meetings?", isPresented: $confirmChatAccess) {
            Button("Allow") { model.setChatAccess(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Relevant meeting excerpts may be sent to OpenAI through your ChatGPT account.")
        }
        .sheet(item: $selected) { meeting in
            VStack(alignment: .leading) {
                Text(meeting.title).font(.headline)
                Text(meeting.startedAt.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary)
                if model.sources.contains(where: { $0.id == meeting.sourceID && $0.provider == .quill }),
                   let id = UUID(uuidString: meeting.remoteID),
                   let url = URL(string: "quill://meeting/\(id.uuidString.lowercased())") {
                    Link("Open in Quill", destination: url)
                }
                ScrollView {
                    Text(meeting.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Forget…") { forgetting = meeting }
                    Spacer()
                    Button("Done") { selected = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 600, height: 440)
            .confirmationDialog("Forget this meeting?", isPresented: Binding(
                get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
                Button("Forget meeting", role: .destructive) {
                    model.forget(meeting)
                    selected = nil
                }
            } message: {
                Text("Remora removes its copy and skips the meeting on future syncs.")
            }
        }
        .onChange(of: model.revision) {
            if let selected, !model.sources.contains(where: { $0.id == selected.sourceID }) { self.selected = nil }
        }
        .confirmationDialog("Disconnect this source?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible, presenting: disconnecting) { source in
            Button("Disconnect and remove imports", role: .destructive) {
                Task { await model.disconnect(source) }
            }
        } message: { _ in
            Text("Remora removes the imported meetings from this source.")
        }
    }

    private struct SearchInput: Hashable {
        let query: String
        let revision: Int
    }

    private func search() async {
        do {
            try await Task.sleep(for: .milliseconds(180))
            let found = try await model.search(query)
            try Task.checkCancellation()
            matches = found
            searchFailed = false
        } catch is CancellationError {
        } catch {
            matches = []
            searchFailed = true
        }
    }
}

private struct LocalMeetingsSection: View {
    let model: MeetingSourcesModel
    @State private var query = ""
    @State private var results: [LocalMeetingSummary] = []
    @State private var loadedRevision: Int?
    @State private var selected: LocalMeetingSummary?
    @State private var failed = false

    var body: some View {
        Section("Recorded meetings") {
            Toggle("Use recordings in chat", isOn: access(.chat))
            Text("Remora chat can send matching transcript and notes excerpts to OpenAI.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Share recordings with MCP clients", isOn: access(.mcp))
            Text("Connected clients can read matching transcript and notes excerpts.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search recordings", text: $query)
            if failed {
                Text("Could not search recordings.").foregroundStyle(.red)
            } else if results.isEmpty, loadedRevision == model.revision {
                Text(query.isEmpty ? "No recorded meetings." : "No matching recordings.").foregroundStyle(.secondary)
            }
            ForEach(loadedRevision == model.revision ? results : []) { item in
                Button { selected = item } label: {
                    LabeledContent {
                        Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                    } label: {
                        Text(item.title)
                        Text(item.client)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: Search(query: query, revision: model.revision)) {
            do {
                let revision = model.revision
                let items = try await model.recordings.search(query)
                try Task.checkCancellation()
                loadedRevision = revision
                results = items
                failed = false
            } catch is CancellationError {
            } catch {
                results = []
                failed = true
            }
        }
        .sheet(item: $selected) { item in
            RecordedMeetingView(model: model, item: item)
        }
    }

    private func access(_ scope: RecordingSearchAccess) -> Binding<Bool> {
        Binding(get: { model.recordingAccess.contains(scope) },
                set: { model.setRecordingAccess(scope, enabled: $0) })
    }

    private struct Search: Equatable {
        let query: String
        let revision: Int
    }
}

private struct RecordedMeetingView: View {
    @Environment(\.dismiss) private var dismiss
    let model: MeetingSourcesModel
    let item: LocalMeetingSummary
    @State private var detail: LocalMeetingDetail?
    @State private var loadedRevision: Int?
    @State private var confirmForget = false
    @State private var forgetFailed = false

    var body: some View {
        VStack(alignment: .leading) {
            if loadedRevision == model.revision, let detail {
                Text(detail.summary.title).font(.headline)
                Text("\(detail.summary.client) · \(detail.summary.startedAt.formatted(date: .long, time: .shortened))")
                    .foregroundStyle(.secondary)
                if detail.summary.interrupted { Text("Recording was interrupted. The transcript may be missing the end of the call.").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let notes = detail.notes {
                            Text(notes)
                        } else {
                            Text(model.generatingNotes.contains(item.id) ? "Generating notes on this Mac…" : "On-device notes unavailable.")
                                .foregroundStyle(.secondary)
                        }
                        Text("Transcript").font(.headline)
                        Text(detail.transcript)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
            }
            if forgetFailed { Text("Could not forget this recording.").foregroundStyle(.red) }
            HStack {
                Button("Forget…") { confirmForget = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 600, height: 440)
        .task(id: model.revision) {
            do {
                let revision = model.revision
                let result = try await model.recordings.detail(id: item.id)
                try Task.checkCancellation()
                loadedRevision = revision
                detail = result
                if result == nil { dismiss() }
            } catch is CancellationError {
            } catch {
                detail = nil
                dismiss()
            }
        }
        .confirmationDialog("Forget this recording?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget recording", role: .destructive) {
                Task {
                    do {
                        try await model.forgetRecording(item.id)
                        dismiss()
                    } catch { forgetFailed = true }
                }
            }
        } message: {
            Text("Remora removes the transcript and notes from this Mac.")
        }
    }
}
