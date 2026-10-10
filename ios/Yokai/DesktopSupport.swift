#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopReaderActionKey: FocusedValueKey {
    typealias Value = (String) -> Void
}
extension FocusedValues {
    var desktopReaderAction: DesktopReaderActionKey.Value? {
        get { self[DesktopReaderActionKey.self] }
        set { self[DesktopReaderActionKey.self] = newValue }
    }
}

struct DesktopReaderCommands: Commands {
    @FocusedValue(\.desktopReaderAction) private var action
    var body: some Commands {
        CommandMenu("阅读") {
            Group {
                Button("向左翻页") { action?("left") }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("向右翻页") { action?("right") }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("向上翻页") { action?("previous") }.keyboardShortcut(.upArrow, modifiers: [])
                Button("向下翻页") { action?("next") }.keyboardShortcut(.downArrow, modifiers: [])
                Button("继续阅读") { action?("next") }.keyboardShortcut(.space, modifiers: [])
                Divider()
                Button("上一章") { action?("previousChapter") }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("下一章") { action?("nextChapter") }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("切换阅读工具栏") { action?("controls") }.keyboardShortcut("t", modifiers: .command)
                Button("关闭阅读器") { action?("close") }.keyboardShortcut(.escape, modifiers: [])
            }.disabled(action == nil)
        }
    }
}

@MainActor
final class DesktopReaderActivity {
    private var activity: NSObjectProtocol?
    func apply(keepAwake: Bool) {
        if keepAwake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "阅读漫画")
        } else if !keepAwake, let value = activity {
            ProcessInfo.processInfo.endActivity(value); activity = nil
        }
    }
}
#endif
