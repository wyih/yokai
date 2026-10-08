import SwiftUI

struct TapZones {
    static let defaults = "previous,controls,next,previous,controls,next,previous,controls,next"
    static let presets = [("default", "默认"), ("l", "L 型"), ("kindlish", "Kindle 型"), ("edge", "边缘"), ("sides", "左右"), ("disabled", "禁用"), ("custom", "自定义")]
    static func mapped(_ action: String, reversed: Bool) -> String {
        if reversed { if action == "previous" { return "next" }; if action == "next" { return "previous" } }
        return action
    }
    static func action(at point: CGPoint, size: CGSize, preset: String, continuous: Bool, invert: String, layout: String, actions: String, reversed: Bool) -> String {
        var x = min(0.999, max(0, point.x / max(size.width, 1)))
        var y = min(0.999, max(0, point.y / max(size.height, 1)))
        if invert == "horizontal" || invert == "both" { x = 1 - x }
        if invert == "vertical" || invert == "both" { y = 1 - y }
        let chosen = preset == "default" ? (continuous ? "l" : "sides") : preset
        switch chosen {
        case "disabled": return "controls"
        case "l":
            if y < 0.33 || (x < 0.33 && y < 0.66) { return "previous" }
            if y >= 0.66 || (x >= 0.66 && y >= 0.33) { return "next" }
            return "controls"
        case "kindlish": return y < 0.33 ? "controls" : x < 0.33 ? "previous" : "next"
        case "edge":
            if x < 0.33 || x >= 0.66 { return "next" }
            return y >= 0.66 ? "previous" : "controls"
        case "sides":
            // Android's LEFT/RIGHT actions follow page direction only in paged readers.
            if x < 0.33 { return continuous ? "previous" : mapped("previous", reversed: reversed) }
            if x >= 0.66 { return continuous ? "next" : mapped("next", reversed: reversed) }
            return "controls"
        default:
            let column = min(2, Int(x * 3)), row = min(2, Int(y * 3))
            let index = layout == "grid" ? row * 3 + column : layout == "rows" ? row : column
            let items = actions.components(separatedBy: ",")
            return mapped(items.indices.contains(index) ? items[index] : "controls", reversed: reversed)
        }
    }
    static func title(_ action: String, continuous: Bool = false) -> String {
        switch action { case "previous": continuous ? "向上滚动" : "上一页"; case "next": continuous ? "向下滚动" : "下一页"; case "controls": "工具栏"; default: "无操作" }
    }
}

struct TapZoneSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tapZones.pager.preset") private var pagerPreset = "default"
    @AppStorage("tapZones.webtoon.preset") private var webtoonPreset = "default"
    @AppStorage("tapZones.pager.invert") private var pagerInvert = "none"
    @AppStorage("tapZones.webtoon.invert") private var webtoonInvert = "none"
    @AppStorage("tapZones.layout") private var layout = "columns"
    @AppStorage("tapZones.actions") private var actions = TapZones.defaults
    @AppStorage("tapZones.followDirection") private var followDirection = true
    @AppStorage("readerMode") private var mode = "vertical"
    @AppStorage("rightToLeft") private var rightToLeft = true
    @State private var continuous = true
    private var preset: Binding<String> { Binding(get: { continuous ? webtoonPreset : pagerPreset }, set: { if continuous { webtoonPreset = $0 } else { pagerPreset = $0 } }) }
    private var invert: Binding<String> { Binding(get: { continuous ? webtoonInvert : pagerInvert }, set: { if continuous { webtoonInvert = $0 } else { pagerInvert = $0 } }) }
    private var reversed: Bool { !continuous && (mode == "rtl" || (mode == "horizontal" && rightToLeft)) && (preset.wrappedValue != "custom" || followDirection) }
    var body: some View {
        Form {
            Section("点按布局") {
                Picker("阅读方式", selection: $continuous) { Text("连续阅读").tag(true); Text("翻页阅读").tag(false) }
                Picker("布局", selection: preset) { ForEach(TapZones.presets, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("反转区域", selection: invert) { Text("不反转").tag("none"); Text("水平").tag("horizontal"); Text("垂直").tag("vertical"); Text("水平和垂直").tag("both") }
                if preset.wrappedValue == "custom" {
                    Picker("自定义布局", selection: $layout) { Text("左右三区").tag("columns"); Text("上下三区").tag("rows"); Text("九宫格").tag("grid") }
                    Toggle("跟随横向翻页方向", isOn: $followDirection)
                }
            }
            Section("区域预览") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(0..<9, id: \.self) { index in
                        let action = TapZones.action(at: CGPoint(x: Double(index % 3) / 3 + 1.0 / 6, y: Double(index / 3) / 3 + 1.0 / 6), size: CGSize(width: 1, height: 1), preset: preset.wrappedValue, continuous: continuous, invert: invert.wrappedValue, layout: layout, actions: actions, reversed: reversed)
                        Group {
                            if preset.wrappedValue == "custom" {
                                Menu {
                                    ForEach(["previous", "next", "controls", "none"], id: \.self) { action in
                                        Button(TapZones.title(TapZones.mapped(action, reversed: reversed), continuous: continuous)) { set(action, at: index) }
                                    }
                                } label: { zone(action) }
                            } else { zone(action) }
                        }
                    }
                }
                Text("原版预设按 Yōkai 的区域和反转规则保留。连续阅读时按屏幕高度滚动；翻页阅读时切换上一页或下一页。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("恢复默认区域") { preset.wrappedValue = "default"; invert.wrappedValue = "none"; actions = TapZones.defaults; layout = "columns"; followDirection = true }
            }
        }
        .navigationTitle("点按区域").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
        .onAppear { continuous = mode == "vertical" || mode == "webtoon" }
    }
    private func zone(_ action: String) -> some View {
        Text(TapZones.title(action, continuous: continuous)).font(.caption).frame(maxWidth: .infinity).frame(height: 90)
            .background((action == "previous" ? Color.orange : action == "next" ? Color.blue : Color.gray).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
    }
    private func set(_ action: String, at index: Int) {
        var items = actions.components(separatedBy: ",")
        while items.count < 9 { items.append("controls") }
        let actual = layout == "grid" ? index : layout == "rows" ? index / 3 : index % 3
        items[actual] = action; actions = items.joined(separator: ",")
    }
}
