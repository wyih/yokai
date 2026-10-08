import Foundation

// A single queue per file keeps older snapshots from overwriting newer ones.
// Mutable failure state is confined to queue; each input is a value snapshot.
final class JSONFileWriter<Value: Encodable & Sendable>: @unchecked Sendable {
    private let file: URL
    private let queue = DispatchQueue(label: "com.wyih.yokai.json-writer", qos: .utility)
    private var failure: Error?

    init(file: URL) { self.file = file }
    func write(_ value: Value, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            do {
                try JSONEncoder().encode(value).write(to: self.file, options: .atomic)
                self.failure = nil
            } catch { self.failure = error }
            let message = self.failure?.localizedDescription
            DispatchQueue.main.async { completion(message) }
        }
    }
    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let failure = self.failure { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            }
        }
    }
}
