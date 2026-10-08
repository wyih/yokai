import SwiftUI
import Photos

struct ImageShareItem: Identifiable { let id = UUID(); let image: UIImage }

struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum ReaderImageActions {
    static func saveToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SourceError.message("请在系统设置中允许 Yōkai 添加照片。") }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
    }
}

struct ReaderColorFilter: ViewModifier {
    @AppStorage("reader.colorFilter") private var enabled = false
    @AppStorage("reader.colorFilterValue") private var value = 0
    @AppStorage("reader.colorFilterMode") private var mode = 0
    private var blend: BlendMode {
        switch mode { case 1: .multiply; case 2: .screen; case 3: .overlay; case 4: .lighten; case 5: .darken; default: .normal }
    }
    func body(content: Content) -> some View {
        content.overlay {
            if enabled {
                let color = UInt32(truncatingIfNeeded: value)
                Color(red: Double((color >> 16) & 255) / 255, green: Double((color >> 8) & 255) / 255,
                      blue: Double(color & 255) / 255, opacity: Double(color >> 24) / 255)
                    .blendMode(blend).allowsHitTesting(false)
            }
        }.compositingGroup()
    }
}

struct ReaderColorSettingsView: View {
    @AppStorage("reader.colorFilter") private var enabled = false
    @AppStorage("reader.colorFilterValue") private var value = 0
    @AppStorage("reader.colorFilterMode") private var mode = 0
    private func component(_ shift: Int) -> Binding<Double> {
        Binding(get: { Double((UInt32(truncatingIfNeeded: value) >> shift) & 255) }, set: { newValue in
            let old = UInt32(truncatingIfNeeded: value)
            let color = (old & ~(UInt32(255) << shift)) | (UInt32(newValue.rounded()) << shift)
            value = Int(Int32(bitPattern: color))
        })
    }
    var body: some View {
        Form {
            Toggle("自定义颜色滤镜", isOn: $enabled)
            Section {
                Picker("混合模式", selection: $mode) {
                    Text("默认").tag(0); Text("正片叠底").tag(1); Text("滤色").tag(2)
                    Text("叠加").tag(3); Text("变亮").tag(4); Text("变暗").tag(5)
                }
                channel("透明度", shift: 24); channel("红色", shift: 16); channel("绿色", shift: 8); channel("蓝色", shift: 0)
            }.disabled(!enabled)
            Section("预览") {
                HStack(spacing: 0) { Color.white; Color.gray; Color.black; Color.red; Color.green; Color.blue }
                    .frame(height: 100).modifier(ReaderColorFilter())
                Button("恢复默认") { enabled = false; value = 0; mode = 0 }
            }
        }.navigationTitle("颜色滤镜").navigationBarTitleDisplayMode(.inline)
    }
    private func channel(_ name: String, shift: Int) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(name, value: "\(Int(component(shift).wrappedValue))")
            Slider(value: component(shift), in: 0...255, step: 1).accessibilityLabel(name)
        }
    }
}
