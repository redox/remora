import Storage
import SwiftUI

/// Settings › Memory › Time rules: project attribution rules for the time ledger. A rule needs a
/// project and at least one matcher.
struct TimeRulesView: View {
    let db: AppDatabase

    private struct Row: Identifiable {
        let rule: TimeRule
        let id: Int64
    }

    @State private var rules: [Row] = []
    @State private var selection: Int64?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(rules, selection: $selection) {
                TableColumn("Project") { Text($0.rule.project) }
                TableColumn("App") { Text($0.rule.app ?? "") }
                TableColumn("Domain") { Text($0.rule.domain ?? "") }
                TableColumn("Title contains") { Text($0.rule.titleContains ?? "") }
            }
            .frame(minHeight: 140)
            HStack(spacing: 0) {
                Button("Add rule", systemImage: "plus") { adding = true }
                    .labelStyle(.iconOnly)
                Button("Remove rule", systemImage: "minus") { remove() }
                    .labelStyle(.iconOnly)
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            Text("Time in a matching app, site or window counts toward the project.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $adding) {
            AddTimeRuleSheet { rule in
                do {
                    try TimeLedgerStore(db).addRule(rule)
                    error = nil
                } catch {
                    self.error = "Could not save the rule."
                }
                reload()
            }
        }
    }

    private func reload() {
        do { rules = try TimeLedgerStore(db).rules().compactMap { r in r.id.map { Row(rule: r, id: $0) } }; error = nil } catch { self.error = "Could not read the rules." }
    }

    private func remove() {
        guard let selection else { return }
        do { try TimeLedgerStore(db).removeRule(id: selection) } catch { self.error = "Could not remove the rule." }
        self.selection = nil
        reload()
    }
}

private struct AddTimeRuleSheet: View {
    let onAdd: (TimeRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var app = ""
    @State private var domain = ""
    @State private var title = ""

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var valid: Bool {
        Self.clean(project) != nil && [app, domain, title].contains { Self.clean($0) != nil }
    }

    var body: some View {
        Form {
            TextField("Project", text: $project)
            TextField("App", text: $app)
            TextField("Domain", text: $domain)
            TextField("Title contains", text: $title)
            if Self.clean(project) != nil, !valid {
                Text("Add at least one matcher: an app, a domain or title text.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    guard let p = Self.clean(project) else { return }
                    onAdd(TimeRule(project: p, app: Self.clean(app), domain: Self.clean(domain),
                                   titleContains: Self.clean(title), createdAt: .now))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
