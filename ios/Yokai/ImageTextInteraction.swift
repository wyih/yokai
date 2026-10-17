import SwiftUI
import VisionKit

struct ReaderImageTextView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 16.0, macCatalyst 17.0, *) {
                    if ImageAnalyzer.isSupported {
                        LiveTextContent(image: image)
                    } else {
                        ContentUnavailableView("此设备不支持实况文本", systemImage: "text.viewfinder",
                                               description: Text("系统无法在此设备上识别图片文字。"))
                    }
                } else {
                    ContentUnavailableView("系统版本不支持实况文本", systemImage: "text.viewfinder",
                                           description: Text("需要 iOS 16 或 macOS 14 及更新版本。"))
                }
            }
            .navigationTitle("图片文字").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("readerImageTextDone") } }
        }
        .accessibilityIdentifier("readerImageTextSheet")
    }
}

@available(iOS 16.0, macCatalyst 17.0, *)
private struct LiveTextContent: View {
    let image: UIImage
    @State private var analysis: ImageAnalysis?
    @State private var error: String?
    @State private var attempt = 0
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            LiveTextImage(image: image, analysis: analysis)
                .accessibilityIdentifier("readerImageTextImage")
            Group {
                if let error {
                    VStack {
                        Text(error)
                        Button("重新识别") { attempt += 1 }.accessibilityIdentifier("readerImageTextRetry")
                    }
                } else if let analysis {
                    if analysis.hasResults(for: .text) {
                        Text("选择图片中的文字即可复制，可缩放图片。")
                    } else {
                        Text("未识别到文字。")
                    }
                } else {
                    ProgressView("正在识别文字…")
                }
            }.font(.footnote).padding().frame(maxWidth: .infinity).background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(copied ? "已复制全部文字" : "复制全部文字", systemImage: "doc.on.doc") {
                    guard let analysis else { return }
                    UIPasteboard.general.string = analysis.transcript; copied = true
                }
                .disabled(analysis?.hasResults(for: .text) != true)
                .accessibilityIdentifier("readerImageTextCopyAll")
            }
        }
        .task(id: attempt) {
            error = nil; analysis = nil; copied = false
            do {
                let result = try await ImageAnalyzer().analyze(image, configuration: .init(.text))
                guard !Task.isCancelled else { return }
                analysis = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "文字识别失败：" + error.localizedDescription
            }
        }
    }
}

@available(iOS 16.0, macCatalyst 17.0, *)
private struct LiveTextImage: UIViewRepresentable {
    let image: UIImage
    let analysis: ImageAnalysis?

    func makeUIView(context: Context) -> TextImageScrollView { TextImageScrollView(image: image) }
    func updateUIView(_ view: TextImageScrollView, context: Context) {
        if view.interaction.analysis !== analysis {
            view.interaction.analysis = analysis
            view.interaction.selectableItemsHighlighted = analysis?.hasResults(for: .text) == true
        }
    }

    final class TextImageScrollView: UIScrollView, UIScrollViewDelegate {
        let imageView: UIImageView
        let interaction = ImageAnalysisInteraction()
        private var previousSize = CGSize.zero

        init(image: UIImage) {
            imageView = UIImageView(image: image)
            super.init(frame: .zero)
            delegate = self
            imageView.contentMode = .scaleAspectFit
            imageView.isUserInteractionEnabled = true
            imageView.addInteraction(interaction)
            interaction.preferredInteractionTypes = .textSelection
            addSubview(imageView)
            contentSize = image.size
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
            if bounds.size != previousSize {
                previousSize = bounds.size
                let widthScale = bounds.width / max(image.size.width, 1)
                minimumZoomScale = min(widthScale, bounds.height / max(image.size.height, 1), 1)
                maximumZoomScale = max(5, widthScale * 5)
                // Fit tall pages to the width so their text stays readable while scrolling.
                zoomScale = min(widthScale, 1)
            }
            imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                       y: max(contentSize.height, bounds.height) / 2)
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { setNeedsLayout() }
    }
}
