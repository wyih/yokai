import Foundation

enum MangaDescription {
    static func render(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: text) else { return AttributedString(text) }
        var result = AttributedString()
        var previousBlock: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            if block != previousBlock {
                if !result.characters.isEmpty { result += AttributedString("\n\n") }
                let listDepth = components.filter { if case .listItem = $0.kind { return true }; return false }.count
                if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
                   case .listItem(let ordinal) = item.kind {
                    let ordered = components.drop(while: { $0.identity != item.identity }).dropFirst().first?.kind == .orderedList
                    result += AttributedString(String(repeating: "  ", count: max(0, listDepth - 1)) + (ordered ? "\(ordinal). " : "• "))
                }
            }
            var span = AttributedString(parsed[run.range])
            span.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.softBreak) == true || run.inlinePresentationIntent?.contains(.lineBreak) == true {
                span = AttributedString("\n")
            } else if components.contains(where: { if case .header = $0.kind { return true }; return false }) {
                span.inlinePresentationIntent = (span.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            }
            result += span
            previousBlock = block
        }
        return result
    }
}
