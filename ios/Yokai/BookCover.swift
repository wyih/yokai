import SwiftUI

struct BookCover: View {
    let book: ComicBook
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.12).aspectRatio(2.0 / 3.0, contentMode: .fit).overlay {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "book.closed").foregroundStyle(.secondary) }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(book.id):\(library.coverRevisions[book.id, default: 0])") {
            let loaded = await library.loadCover(for: book)
            if !Task.isCancelled { image = loaded }
        }
        .task(id: (book.origin?.thumbnail ?? "") + extensions.sources.map(\.id).joined()) {
            if let source = extensions.sources.first(where: { $0.id == book.origin?.sourceID }) { await library.cacheSourceCover(book, source: source) }
        }
    }
}
