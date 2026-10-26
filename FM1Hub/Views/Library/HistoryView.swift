import SwiftUI

struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(CatalogStore.self) private var catalog
    @State private var confirmClear = false

    private var grouped: [(String, [InstallRecord])] {
        let f = DateFormatter(); f.dateStyle = .full
        var out: [(String, [InstallRecord])] = []
        for r in library.history {
            let k = f.string(from: r.date)
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1.append(r) } else { out.append((k, [r])) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if library.history.isEmpty {
                        EmptyState(icon: "clock.arrow.circlepath", title: "Nothing installed yet", text: "Every install from this app is remembered here: what went on the FM-1, when, and whether it worked.")
                    } else {
                        summary
                        ForEach(grouped, id: \.0) { day, rs in
                            VStack(alignment: .leading, spacing: 6) {
                                SectionHeader(text: day)
                                VStack(spacing: 0) {
                                    ForEach(rs) { r in
                                        row(r)
                                        if r.id != rs.last?.id { Divider().overlay(Theme.stroke) }
                                    }
                                }
                                .padding(.horizontal, 14).card()
                            }
                        }
                    }
                }
                .padding(16)
            }
            .hubBackground()
            .navigationTitle("History")
            .toolbar {
                if !library.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { Button("Clear") { confirmClear = true } }
                }
            }
            .confirmationDialog("Clear the history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { library.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var summary: some View {
        let ok = library.history.filter(\.success)
        let distinct = Set(ok.map { $0.firmwareId ?? $0.product }).count
        return HStack(spacing: 0) {
            stat("\(ok.count)", "installs")
            Divider().overlay(Theme.stroke).frame(height: 32)
            stat("\(distinct)", "firmwares tried")
            Divider().overlay(Theme.stroke).frame(height: 32)
            stat("\(library.history.count - ok.count)", "failed")
        }
        .padding(.vertical, 12).card()
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(n).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.textFaint)
        }.frame(maxWidth: .infinity)
    }

    private func row(_ r: InstallRecord) -> some View {
        let c = r.firmwareId.map { Look.colour(for: $0) } ?? Theme.textDim
        return HStack(spacing: 12) {
            Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.success ? Theme.ok : Theme.err)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(r.version).font(.system(size: 13, design: .rounded)).foregroundStyle(c)
                    Chip(text: sourceText(r.source), tint: Theme.textDim)
                }
                if let b = r.identityBefore, let a = r.identityAfter {
                    Text("\(b) → \(a)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                } else if !r.product.isEmpty {
                    Text(r.product).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                }
                if let e = r.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.err).lineLimit(3) }
            }
            Spacer()
            Text(r.date, style: .time).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 10)
    }

    private func sourceText(_ s: InstallSource) -> String {
        switch s {
        case .hub: return "hub"
        case .stock: return "official"
        case .snapshot: return "backup"
        case .file: return "file"
        case .resume: return "resumed"
        }
    }
}
