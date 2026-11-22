import Memory
import Storage
import SwiftUI

/// Settings' local wiki inspector: bounded, cancellable reads and explicit refresh/load-more.
struct WikiBrowserView: View {
    let db: AppDatabase

    @State private var type: WikiPageType?
    @State private var query = ""
    @State private var result: WikiBrowserResult?
    @State private var selected: WikiPage?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var limit = WikiBrowserRequest.pageSize
    @State private var refreshID = 0

    static let searchDebounce: Duration = .milliseconds(250)

    private static let filters: [(String, WikiPageType?)] = [
        ("All", nil), ("People", .person), ("Projects", .project), ("Topics", .topic), ("Tools", .tool), ("Orgs", .org),
    ]
    private struct LoadKey: Hashable {
        var request: WikiBrowserRequest
        var refresh: Int
    }
    private var request: WikiBrowserRequest { WikiBrowserRequest(query: query, type: type, limit: limit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search pages", text: $query, prompt: Text("Search pages"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Search memory pages")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel("Clear search")
                }
                Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh wiki")
                    .help("Refresh wiki")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Self.filters, id: \.0) { filter in
                        Button { type = filter.1 } label: {
                            Text(filter.0).font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(QuietButtonStyle(selected: type == filter.1))
                        .accessibilityAddTraits(type == filter.1 ? .isSelected : [])
                    }
                }
            }
            if loading {
                ProgressView(request.isSearching ? "Searching…" : "Loading pages…").controlSize(.small)
            } else if loadFailed {
                HStack {
                    Text("The wiki could not be read.").foregroundStyle(.secondary)
                    Button("Retry") { refreshID += 1 }
                }
            } else if let result {
                if result.pages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.emptyMessage).font(.callout.weight(.medium))
                        Text(request.isSearching || type != nil
                             ? "Try another search or choose All."
                             : "Pages appear as background memory organizes captured text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    Text("\(result.pages.count) \(result.pages.count == 1 ? "page" : "pages")")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(result.pages, id: \.slug) { page in
                        Button { selected = page } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(page.title).font(.callout.weight(.semibold)).foregroundStyle(Color.primary)
                                        Text(page.type.rawValue.capitalized).font(.caption).foregroundStyle(Color.secondary)
                                        Spacer()
                                        Text(page.lastSeen.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(Color.secondary)
                                    }
                                    if !page.summary.isEmpty {
                                        Text(page.summary).lineLimit(2).font(.callout).foregroundStyle(Color.secondary)
                                    }
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 7).padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    if result.hasMore {
                        if limit < WikiBrowserRequest.maxPages {
                            Button("Load more") { limit += WikiBrowserRequest.pageSize }
                        } else {
                            Text("Showing the first \(result.pages.count) pages. Use search to narrow the results.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: query) { limit = WikiBrowserRequest.pageSize }
        .onChange(of: type) { limit = WikiBrowserRequest.pageSize }
        .task(id: LoadKey(request: request, refresh: refreshID)) { await reload(request) }
        .sheet(item: Binding(get: { selected.map(PageRef.init) }, set: { selected = $0?.page })) { ref in
            WikiPageDetail(db: db, page: ref.page) {
                selected = nil
                refreshID += 1
            }
        }
    }

    private struct PageRef: Identifiable {
        let page: WikiPage
        var id: String { page.slug }
    }

    private func reload(_ request: WikiBrowserRequest) async {
        guard !Task.isCancelled else { return }
        loading = true
        result = nil
        loadFailed = false
        defer { if !Task.isCancelled { loading = false } }
        do {
            if request.isSearching { try await Task.sleep(for: Self.searchDebounce) }
            try Task.checkCancellation()
            let loaded = try await Task.detached(priority: .userInitiated) { [db] in try request.load(db) }.value
            guard !Task.isCancelled else { return }
            result = loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}

private struct WikiPageDetail: View {
    let db: AppDatabase
    let page: WikiPage
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var facts: [WikiFact] = []
    @State private var loading = true
    @State private var refreshID = 0
    @State private var confirmDelete = false
    @State private var readError: String?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(page.title).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !page.summary.isEmpty { Text(page.summary).italic() }
                    if !page.body.isEmpty {
                        Text((try? AttributedString(markdown: page.body,
                                                     options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                             ?? AttributedString(page.body))
                    }
                    if !page.aliases.isEmpty {
                        Text("Also known as: " + page.aliases.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Mentioned \(page.mentionCount) times · last seen \(page.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout).foregroundStyle(.secondary)
                    if loading { ProgressView("Loading facts…").controlSize(.small) }
                    let current = facts.filter { $0.invalidAt == nil }
                    let past = facts.filter { $0.invalidAt != nil }
                    if !current.isEmpty {
                        Text("Facts").font(.headline)
                        ForEach(current, id: \.id) { f in
                            Text("• \(f.fact) — since \(f.validAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    if !past.isEmpty {
                        DisclosureGroup("History") {
                            ForEach(past, id: \.id) { f in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(f.fact).strikethrough()
                                    Text("until \((f.invalidAt ?? f.validAt).formatted(date: .abbreviated, time: .omitted))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            if let readError {
                HStack {
                    Text(readError).font(.footnote).foregroundStyle(.red)
                    Button("Retry") { refreshID += 1 }
                }
            }
            if let deleteError { Text(deleteError).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button("Delete page…", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task(id: refreshID) { await loadFacts() }
        .confirmationDialog("Delete this page and its facts? Remora may recreate it if it sees it again.",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                do {
                    try WikiStore(db).delete(slug: page.slug)
                    onDeleted()
                } catch {
                    deleteError = "Could not delete the page."
                }
            }
        }
    }

    private func loadFacts() async {
        guard !Task.isCancelled else { return }
        loading = true
        facts = []
        readError = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let rows = try await Task.detached(priority: .userInitiated) { [db, slug = page.slug] in
                try WikiStore(db).facts(slug: slug, includeInvalid: true)
            }.value
            guard !Task.isCancelled else { return }
            facts = rows
        } catch {
            guard !Task.isCancelled else { return }
            readError = "The page details could not be read."
        }
    }

}
