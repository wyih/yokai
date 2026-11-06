import SwiftUI

struct BookCover: View {
    let book: ComicBook
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var image: UIImage?
    @ObservedObject private var covers = SourceCoverCache.shared

    var body: some View {
        Color.secondary.opacity(0.12).aspectRatio(2.0 / 3.0, contentMode: .fit).overlay {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "book.closed").foregroundStyle(.secondary) }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(book.id):\(library.coverRevisions[book.id, default: 0])") {
            let loaded = await library.loadCover(for: book)
            if !Task.isCancelled { image = loaded }
        }
        .task(id: (book.origin?.thumbnail ?? "") + extensions.sources.map(\.id).joined() + "\n\(covers.revisions[book.origin?.sourceID ?? "", default: 0])") {
            if let source = extensions.sources.first(where: { $0.id == book.origin?.sourceID }) { await library.cacheSourceCover(book, source: source) }
        }
    }
}

struct CoverPreview: View {
    let book: ComicBook?
    let source: MangaSource?
    let url: String?
    let title: String
    @EnvironmentObject private var library: ComicLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image, animation: nil, imageTransform: ReaderImageTransform(), playing: false) { _ in }
                        .accessibilityIdentifier("coverZoomView")
                        .accessibilityLabel("封面，双击或双指缩放")
                } else if loading { ProgressView().tint(.white) }
                else { ContentUnavailableView("暂无封面", systemImage: "photo") }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("closeCoverPreview") } }
            .preferredColorScheme(.dark)
            .task {
                if let book { image = await localCover(book, names: ["custom-cover.jpg"]) }
                if image == nil, let source, let url, !url.isEmpty { image = try? await SourceCoverCache.load(source: source, url: url) }
                if image == nil, let book { image = await localCover(book, names: ["source-cover.jpg", "cover.jpg"]) }
                loading = false
            }
        }
    }

    private func localCover(_ book: ComicBook, names: [String]) async -> UIImage? {
        let directory = library.root.appendingPathComponent(book.id)
        return await Task.detached(priority: .userInitiated) {
            for name in names {
                if let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) { return image.preparingForDisplay() ?? image }
            }
            return nil
        }.value
    }
}
