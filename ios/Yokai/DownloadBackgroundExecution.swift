import BackgroundTasks
import UIKit

/// A finite batch explicitly requested through Download / Resume. Automatic
/// library updates and reader prefetching do not create continued-processing UI.
@MainActor
final class DownloadBackgroundExecution {
    #if READING_HUB
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.wyih.qiyereader") + ".yokai.download"
    #else
    static let identifier = "com.wyih.yokai.download"
    #endif
    private var requestIdentifier: String?
    private var task: BGTask?
    private var members = Set<String>()
    var changed: ((String?) -> Void)?
    var granted: (() -> Void)?
    var expired: ((Set<String>) -> Void)?
    var active: Bool { task != nil }

    func request(_ ids: Set<String>, jobs: [ChapterDownload]) {
        guard !ids.isEmpty, UIApplication.shared.applicationState == .active else { return }
        guard #available(iOS 26.0, *) else { return }
        members.formUnion(ids)
        if requestIdentifier != nil { report(jobs); return }
        let identifier = Self.identifier + "." + UUID().uuidString.lowercased()
        // A new identifier distinguishes a late launch callback for a cancelled
        // batch from a subsequent Resume request. Each handler is registered once.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.requestIdentifier == identifier else { value.setTaskCompleted(success: false); return }
                    self.task = value
                    value.expirationHandler = { [weak self] in
                        Task { @MainActor in
                            guard let self, self.task === value else { return }
                            let interrupted = self.members
                            // Stop the queue and save checkpoints before acknowledging expiration.
                            self.expired?(interrupted)
                            self.finish(success: false)
                        }
                    }
                    self.changed?(nil)
                    self.granted?()
                }
            }
        guard registered else {
            members.removeAll(); changed?("当前安装环境未允许后台下载，切回 App 后可继续。"); return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "漫画下载", subtitle: "正在准备章节…")
        request.strategy = .fail
        requestIdentifier = identifier
        do { try BGTaskScheduler.shared.submit(request); changed?(nil) }
        catch {
            requestIdentifier = nil; members.removeAll()
            let failure = error as NSError
            changed?(failure.domain == BGTaskScheduler.errorDomain && failure.code == BGTaskScheduler.Error.Code.notPermitted.rawValue
                ? "当前安装环境未允许后台下载，切回 App 后可继续。"
                : "系统暂未允许持续后台下载，切回 App 后可继续。")
        }
    }

    func report(_ jobs: [ChapterDownload]) {
        guard requestIdentifier != nil else { return }
        let rows = jobs.filter { members.contains($0.id) }
        let pending = rows.filter { $0.state == .queued || $0.state == .downloading }
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            let total = rows.reduce(Int64(0)) { $0 + Int64(max(1, $1.total) + 1) }
            let done = rows.reduce(Int64(0)) { value, job in
                value + (job.state == .completed ? Int64(max(1, job.total) + 1) : Int64(job.total > 0 ? 1 + (job.received ?? job.completed) : 0))
            }
            task.progress.totalUnitCount = max(1, total)
            task.progress.completedUnitCount = min(done, total)
            let current = pending.first(where: { $0.state == .downloading }) ?? pending.first
            task.updateTitle("漫画下载", subtitle: current.map { "\($0.manga.title) · \($0.chapter.name) · \($0.received ?? $0.completed)/\($0.total)" } ?? "下载完成")
        }
        if pending.isEmpty { finish(success: !rows.isEmpty && rows.allSatisfy { $0.state == .completed }) }
    }

    func contains(_ id: String) -> Bool { members.contains(id) }
    private func finish(success: Bool) {
        let value = task
        let identifier = requestIdentifier
        task = nil; requestIdentifier = nil; members.removeAll()
        if let value { value.expirationHandler = nil; value.setTaskCompleted(success: success) }
        else if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
    }
}
