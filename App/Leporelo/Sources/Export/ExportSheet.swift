import AppKit
import LeporeloCore
import SwiftUI

/// "Exportovat pro Canva" (spec 6.5): the preflight list (errors red, warnings yellow; a click on
/// a spread's problem shows it in the editor), "Rozumím varováním", the folder panel, progress
/// with "Zrušit", and the result with "Zobrazit ve Finderu" / "Otevřít složku". The sheet cannot
/// be closed while an export runs.
struct ExportSheet: View {
    let model: ExportModel
    let onClose: () -> Void

    @State private var destinationProblem: String?
    @State private var overwrite: OverwriteRequest?

    private struct OverwriteRequest: Identifiable {
        let directory: URL
        let files: [String]
        var id: URL { directory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            issueList
            if model.hasWarnings {
                Toggle("Rozumím varováním", isOn: Binding(get: { model.acceptedWarnings },
                                                          set: { model.acceptedWarnings = $0 }))
                    .disabled(model.isExporting)
            }
            phaseView
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .interactiveDismissDisabled(model.isExporting)
        .onAppear { model.startObserving() }
        .onDisappear { model.close() }
        .alert("Tuto složku nejde použít", isPresented: Binding(get: { destinationProblem != nil },
                                                                 set: { if !$0 { destinationProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(destinationProblem ?? "")
        }
        .alert(ExportLogic.overwriteTitle, isPresented: Binding(get: { overwrite != nil },
                                                                 set: { if !$0 { overwrite = nil } }),
               presenting: overwrite) { request in
            Button("Přepsat", role: .destructive) { model.startExport(to: request.directory) }
            Button("Zrušit", role: .cancel) {}
        } message: { request in
            Text("Nahradí se: \(request.files.joined(separator: ", ")). Ostatní soubory ve složce zůstanou.")
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title).font(.title2.weight(.semibold))
            Text(summaryLine).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var summaryLine: String {
        guard model.hasPreflight else { return "Kontroluji album…" }
        let errors = model.issues.filter { $0.severity == .error }.count
        let warnings = model.issues.count - errors
        if errors == 0 && warnings == 0 { return "Kontrola před exportem nenašla žádné problémy." }
        var parts: [String] = []
        if errors > 0 { parts.append(CzechPlural.count(errors, one: "chyba", few: "chyby", many: "chyb")) }
        if warnings > 0 { parts.append(CzechPlural.count(warnings, one: "varování", few: "varování", many: "varování")) }
        let joined = parts.joined(separator: ", ")
        return errors > 0 ? "\(joined). Chyby je potřeba opravit před exportem." : "\(joined)."
    }

    @ViewBuilder private var issueList: some View {
        if !model.hasPreflight {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.issues.isEmpty {
            ContentUnavailableView("Vše v pořádku", systemImage: "checkmark.seal",
                                   description: Text("Album je připravené k tisku."))
                .frame(maxHeight: .infinity)
        } else {
            List(model.rows) { row in
                IssueRowView(row: row, canJump: row.canJump && !model.isExporting) { model.jump(to: row) }
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var phaseView: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case let .exporting(done, total):
            VStack(alignment: .leading, spacing: 6) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("Hotovo \(done) z \(total)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Připravuji export…").font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .finished(summary):
            VStack(alignment: .leading, spacing: 6) {
                Label(summary.headline, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(summary.folderPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !summary.steps.isEmpty {
                    Text("Co dál:").font(.callout.weight(.medium)).padding(.top, 4)
                    ForEach(summary.steps, id: \.self) { Text($0).font(.callout) }
                }
                Text("Celý postup je v souboru \(ExportInstructions.fileName).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Zobrazit ve Finderu") { model.reveal(summary.result) }
                    Button("Otevřít složku") { model.openFolder(summary.result) }
                }
            }
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if let detail = failure.detail, !detail.isEmpty {
                    DisclosureGroup("Technické podrobnosti") {
                        Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if model.isExporting {
                Button("Zrušit") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
                    .help("Zruší export, rozpracované soubory se smažou")
            } else {
                Button("Zavřít") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button(model.exportButtonTitle) { chooseFolder() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
                .help(exportHelp)
        }
    }

    private var exportHelp: String {
        if model.waitingForOriginals > 0 { return "Některé originály se ještě stahují do projektu" }
        if model.hasErrors { return "Nejdřív opravte chyby" }
        if model.hasWarnings && !model.acceptedWarnings { return "Potvrďte, že rozumíte varováním" }
        return "Vyberte složku pro export"
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exportovat"
        panel.message = "Vyberte složku, do které se uloží soubory pro tisk"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { choose(url) }
        }
    }

    private func choose(_ directory: URL) {
        switch model.check(destination: directory) {
        case .ok: model.startExport(to: directory)
        case let .invalid(message): destinationProblem = message
        case let .needsOverwrite(files): overwrite = OverwriteRequest(directory: directory, files: files)
        }
    }
}

private struct IssueRowView: View {
    let row: ExportIssueRow
    let canJump: Bool
    let jump: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: row.issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(row.issue.severity == .error ? Color.red : Color.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text)
                if let hint = row.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let place = row.place {
                if canJump {
                    Button(place, action: jump)
                        .buttonStyle(.link)
                        .help("Ukázat v editoru")
                } else {
                    Text(place).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if canJump { jump() } }
        .accessibilityElement(children: .combine)
        .accessibilityHint(canJump ? "Ukáže dvoustranu v editoru" : "")
    }
}
