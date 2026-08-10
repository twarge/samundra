// Tokenized entry for element symbols, with autocompletion drawn from the
// bundled NIST catalog so only elements that actually have lines can be
// chosen. Backed by NSTokenField — SwiftUI has no native token field.

import AppKit
import SwiftUI

struct ElementTokenField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",; ")
        field.placeholderString = "Any"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.completionDelay = 0.1
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        let tokens = Self.orderedTokens(from: text)
        if field.currentEditor() == nil,
           ((field.objectValue as? [String]) ?? []) != tokens {
            field.objectValue = tokens
        }
    }

    /// Parse preserving entry order, canonicalized and deduplicated.
    static func orderedTokens(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { ",; ".contains($0) }).compactMap { token in
            let symbol = token.trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { return nil }
            let canonical = symbol.prefix(1).uppercased() + symbol.dropFirst().lowercased()
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: ElementTokenField

        private lazy var symbols: [String] =
            Set(AtomicLineDatabase.shared.lines.map(\.element)).sorted()
        private lazy var canonical: [String: String] =
            Dictionary(uniqueKeysWithValues: symbols.map { ($0.lowercased(), $0) })

        init(_ parent: ElementTokenField) {
            self.parent = parent
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let prefix = substring.lowercased()
            guard !prefix.isEmpty else { return [] }
            let matches = symbols.filter { $0.lowercased().hasPrefix(prefix) }
            selectedIndex?.pointee = matches.isEmpty ? -1 : 0
            return matches
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            tokens.compactMap { token in
                (token as? String).flatMap {
                    canonical[$0.trimmingCharacters(in: .whitespaces).lowercased()]
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            push(notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            push(notification)
        }

        /// Writes completed, valid tokens back to the binding; a partial
        /// symbol still being typed is not yet a token and is ignored.
        private func push(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let tokens = ((field.objectValue as? [Any]) ?? []).compactMap { $0 as? String }
            let joined = tokens.compactMap { canonical[$0.lowercased()] }
                .joined(separator: ", ")
            if joined != parent.text {
                parent.text = joined
            }
        }
    }
}
