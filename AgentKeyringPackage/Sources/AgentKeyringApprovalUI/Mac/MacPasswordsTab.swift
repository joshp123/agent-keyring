// Written by AI on 2026.11.21 by model claude opus 5.5, from the Paper page
// "Agent Keyring (Holistic)", board 3 ("Mac: Passwords"), and the copy ledger.
//
// Passwords: the three rules explained at the top, the filter with its
// counts, and the table of every password with how often agents asked for
// it and how he answered, sortable by each column. A rule changed in the
// table waits, with the others changed, for one Touch ID.

#if os(macOS)
import AppKit
import AgentKeyringDesign
import SwiftUI

public struct MacPasswordsTab: View {
    @Bindable var model: MacMainModel
    @State private var sorting = false

    public init(model: MacMainModel) { self.model = model }

    public var body: some View {
        // The bands above and below the table set their own margins from the
        // tokens: no part draws an everyday window's top band and bottom bar yet.
        VStack(spacing: 0) {
            HStack(spacing: KeyringSpace.s4) {
                KeyringHint(symbol: "info.circle.fill", MainWindowCopy.rulesExplained)
                KeyringButton(.plain(MainWindowCopy.sortWithAI) { sorting = true })
            }
            .padding([.horizontal, .top], KeyringSpace.s5)
            HStack {
                Picker(MainWindowCopy.all, selection: $model.filter) {
                    Text(MainWindowCopy.filter(MainWindowCopy.all, model.count(nil))).tag(LoginRule?.none)
                    ForEach(LoginRule.allCases, id: \.self) { Text(MainWindowCopy.filter($0.name, model.count($0))).tag(LoginRule?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
            }
            .padding(KeyringSpace.s5)
            table
            Divider()
            footer.padding(.horizontal, KeyringSpace.s5).padding(.vertical, KeyringSpace.s3)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text(MainWindowCopy.search(model.snapshot.logins.count)))
        .sheet(isPresented: $sorting) {
            SortWithAISheet(model: model) { sorting = false }
                .frame(width: KeyringSize.measure + 2 * KeyringSpace.s10)
        }
    }

    private var table: some View {
        // A table's row is as tall as its cells' lines, but a cell's text does
        // not wrap to its column. So the account sits under the website, in the
        // one wide column, rather than in a narrow column of its own where a
        // long address would be cut off.
        Table(model.visibleLogins, sortOrder: $model.sortOrder) {
            TableColumn(MainWindowCopy.website, value: \.site) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s2) {
                        KeyringText(row.site, as: .heading)
                        if row.isTestPassword { KeyringText(MainWindowCopy.testPassword, as: .caption) }
                    }
                    KeyringText(row.account, as: .meta)
                }
            }
            .width(min: 320)
            TableColumn(MainWindowCopy.asked, value: \.asked) { KeyringText("\($0.asked)").monospacedDigit() }
                .width(56).alignment(.trailing)
            TableColumn(MainWindowCopy.approved, value: \.approved) { KeyringText("\($0.approved)").monospacedDigit() }
                .width(76).alignment(.trailing)
            TableColumn(MainWindowCopy.denied, value: \.denied) { KeyringText("\($0.denied)").monospacedDigit() }
                .width(56).alignment(.trailing)
            TableColumn(MainWindowCopy.rule, value: \.ruleOrder) { row in
                Picker(MainWindowCopy.rule, selection: Binding(get: { model.rule(of: row) }, set: { model.choose($0, for: row) })) {
                    ForEach(LoginRule.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            .width(120)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: KeyringSpace.s3) {
            if model.pending.isEmpty {
                KeyringText(imported, as: .meta).frame(maxWidth: .infinity, alignment: .leading)
                KeyringButton(.plain(model.snapshot.sampleOnly ? MainWindowCopy.copyFromPasswords : MainWindowCopy.copyAgain, perform: model.importAgain))
            } else {
                KeyringText(model.pendingSentence, as: .body).frame(maxWidth: .infinity, alignment: .leading)
                KeyringButton(.plain(MainWindowCopy.cancel, perform: model.cancelChanges))
                KeyringButton(.approve(model.isWorking ? MainWindowCopy.useTouchIDToSave : MainWindowCopy.saveWithTouchID,
                    isEnabled: !model.isWorking, perform: model.save))
            }
        }
    }

    private var imported: String {
        if model.snapshot.sampleOnly { return MainWindowCopy.sampleOnly }
        guard let at = model.snapshot.importedAt else { return MainWindowCopy.noneCopied }
        return MainWindowCopy.copiedOn(at.formatted(.dateTime.day().month(.wide)))
    }
}

/// Sort with AI: copy a prompt with names only, then turn the agent's reply
/// into pending changes, reviewed in the table and saved with Touch ID.
public struct SortWithAISheet: View {
    let model: MacMainModel
    let close: () -> Void
    @State private var copied = false
    @State private var nothingFound = false

    public init(model: MacMainModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        KeyringPage(title: MainWindowCopy.sortTitle, sentence: MainWindowCopy.sortBody,
                    status: nothingFound ? .problem(MainWindowCopy.noSuggestions) : nil,
                    primary: .advance(MainWindowCopy.applySuggestions) { apply() },
                    secondary: .plain(MainWindowCopy.cancel, perform: close),
                    aside: .plain(copied ? MainWindowCopy.promptCopied : MainWindowCopy.copyPrompt) { copy() }) {
            KeyringHint(symbol: "doc.on.clipboard", MainWindowCopy.applyHow, tone: .plain)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.sortPrompt, forType: .string)
        copied = true
        nothingFound = false
    }

    private func apply() {
        let reply = NSPasteboard.general.string(forType: .string) ?? ""
        if reply != model.sortPrompt, model.applySuggestions(reply) > 0 { close() } else { nothingFound = true }
    }
}
#endif
