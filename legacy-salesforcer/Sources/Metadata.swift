import AppKit
import Foundation

struct AppError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

final class ProcessPipeCapture {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe, stderr: Pipe) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            self?.lock.lock(); self?.stdoutData = data; self?.lock.unlock()
            self?.group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            self?.lock.lock(); self?.stderrData = data; self?.lock.unlock()
            self?.group.leave()
        }
    }

    func notify(_ completion: @escaping (Data, Data) -> Void) {
        group.notify(queue: .main) { [self] in
            self.lock.lock(); let out = self.stdoutData; let err = self.stderrData; self.lock.unlock()
            completion(out, err)
        }
    }
}

struct SchemaObject: Codable, Equatable {
    let apiName: String
    let label: String
    let custom: Bool
    let queryable: Bool
}

struct SchemaField: Codable, Equatable {
    let apiName: String
    let label: String
    let type: String
    let custom: Bool
    let calculated: Bool
    let nillable: Bool
    let filterable: Bool
    let sortable: Bool
    let relationshipName: String?
    let referenceTo: [String]
}

struct MetadataResponse: Decodable {
    let ok: Bool
    let kind: String?
    let message: String?
    let objectApiName: String?
    let objects: [SchemaObject]?
    let fields: [SchemaField]?
}

struct SchemaCacheEnvelope<Value: Codable>: Codable {
    let version: Int
    let fetchedAt: Date
    let value: Value
}

enum SchemaHelpers {
    static let freshness: TimeInterval = 24 * 60 * 60
    static func isFresh(_ date: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(date) < freshness }
    static func matches(_ query: String, label: String, apiName: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || label.localizedCaseInsensitiveContains(needle) || apiName.localizedCaseInsensitiveContains(needle)
    }
    static func insert(_ text: String, in original: String, range: NSRange) -> String {
        guard let swiftRange = Range(range, in: original) else { return original }
        return original.replacingCharacters(in: swiftRange, with: text)
    }
}

final class MetadataRunner {
    private var process: Process?
    private var token: UUID?

    func run(operation: String, objectApiName: String? = nil, interactive: Bool, completion: @escaping (Result<MetadataResponse, Error>) -> Void) {
        cancel()
        guard let resources = Bundle.main.resourceURL else { completion(.failure(AppError("Metadata backend missing."))); return }
        let backend = resources.appendingPathComponent("metadata_backend.R").path
        let candidates = ["/usr/local/bin/Rscript", "/opt/homebrew/bin/Rscript", "/usr/bin/Rscript"]
        guard FileManager.default.fileExists(atPath: backend), let rscript = candidates.first(where: FileManager.default.fileExists) else {
            completion(.failure(AppError("The metadata backend or Rscript is unavailable."))); return
        }
        let current = UUID(); token = current
        let task = Process(); let input = Pipe(); let output = Pipe(); let errorPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: rscript)
        task.arguments = ["--vanilla", backend]
        var environment = ProcessInfo.processInfo.environment
        environment["SOQL_QUICK_RESOURCE_DIR"] = resources.path
        task.environment = environment
        task.standardInput = input; task.standardOutput = output; task.standardError = errorPipe
        let capture = ProcessPipeCapture(stdout: output, stderr: errorPipe)
        process = task
        task.terminationHandler = { [weak self] _ in
            capture.notify { stdoutData, stderrData in
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                guard self?.token == current else { return }
                self?.token = nil; self?.process = nil
                guard let line = stdout.split(separator: "\n").last(where: { $0.hasPrefix("SOQL_QUICK_RESULT:") }) else {
                    completion(.failure(AppError(stderr.isEmpty ? "Metadata returned no response." : String(stderr.prefix(1500))))); return
                }
                do { completion(.success(try JSONDecoder().decode(MetadataResponse.self, from: Data(line.dropFirst("SOQL_QUICK_RESULT:".count).utf8)))) }
                catch { completion(.failure(AppError("Metadata response could not be decoded: \(error.localizedDescription)"))) }
            }
        }
        do {
            try task.run()
            var request: [String: Any] = ["operation": operation, "authMode": interactive ? "interactive" : "cached"]
            if let objectApiName { request["objectApiName"] = objectApiName }
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
            try? input.fileHandleForWriting.close()
        } catch { token = nil; process = nil; completion(.failure(error)) }
    }

    func cancel() { token = nil; if process?.isRunning == true { process?.terminate() }; process = nil }
}

final class MetadataService {
    private static let cacheVersion = 3
    private let runner = MetadataRunner()
    private let fileManager = FileManager.default
    private var paused = false
    private var pending: (() -> Void)?
    private var activeRetry: (() -> Void)?
    private let cacheQueue = DispatchQueue(label: "SOQLQuick.SchemaCache", qos: .utility)

    private var schemaDirectory: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SOQL Quick/schema", isDirectory: true)
    }
    private var objectsURL: URL { schemaDirectory.appendingPathComponent("objects.json") }
    private func fieldsURL(_ object: String) -> URL { schemaDirectory.appendingPathComponent("fields-\(object).json") }

    func pause() {
        paused = true
        if pending == nil { pending = activeRetry }
        runner.cancel()
    }
    func resume() { paused = false; let work = pending; pending = nil; work?() }
    func shutdown() { pause(); pending = nil }

    func cachedObjects(_ completion: @escaping ([SchemaObject], Date?) -> Void) {
        readCache([SchemaObject].self, url: objectsURL, completion: completion)
    }
    func cachedFields(object: String, completion: @escaping ([SchemaField], Date?) -> Void) {
        readCache([SchemaField].self, url: fieldsURL(object), completion: completion)
    }

    func refreshObjects(interactive: Bool, completion: @escaping (MetadataResponse) -> Void) {
        let work: () -> Void = { [weak self] in
            self?.perform(operation: "list_objects", object: nil, interactive: interactive, completion: completion)
        }
        if paused { pending = work } else { activeRetry = work; work() }
    }
    func refreshFields(object: String, interactive: Bool = false, completion: @escaping (MetadataResponse) -> Void) {
        let work: () -> Void = { [weak self] in
            self?.perform(operation: "describe_object", object: object, interactive: interactive, completion: completion)
        }
        if paused { pending = work } else { activeRetry = work; work() }
    }

    private func perform(operation: String, object: String?, interactive: Bool, completion: @escaping (MetadataResponse) -> Void) {
        runner.run(operation: operation, objectApiName: object, interactive: interactive) { [weak self] result in
            self?.activeRetry = nil
            switch result {
            case .failure(let error): completion(MetadataResponse(ok: false, kind: "metadata", message: error.localizedDescription, objectApiName: object, objects: nil, fields: nil))
            case .success(let response):
                if response.ok, let self {
                    if let objects = response.objects { self.writeCache(objects, url: self.objectsURL) }
                    if let fields = response.fields, let object { self.writeCache(fields, url: self.fieldsURL(object)) }
                }
                completion(response)
            }
        }
    }

    private func readCache<T: Codable>(_ type: T.Type, url: URL, completion: @escaping (T, Date?) -> Void) where T: ExpressibleByArrayLiteral {
        cacheQueue.async {
            do {
                let envelope = try JSONDecoder.schemaDecoder.decode(SchemaCacheEnvelope<T>.self, from: Data(contentsOf: url))
                guard envelope.version == Self.cacheVersion else {
                    DispatchQueue.main.async { completion([], nil) }
                    return
                }
                DispatchQueue.main.async { completion(envelope.value, envelope.fetchedAt) }
            } catch {
                DispatchQueue.main.async { completion([], nil) }
            }
        }
    }
    private func writeCache<T: Codable>(_ value: T, url: URL) {
        cacheQueue.async { [fileManager, schemaDirectory] in
            try? fileManager.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
            let envelope = SchemaCacheEnvelope(version: Self.cacheVersion, fetchedAt: Date(), value: value)
            if let data = try? JSONEncoder.schemaEncoder.encode(envelope) { try? data.write(to: url, options: .atomic) }
        }
    }
}

extension JSONEncoder { static var schemaEncoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var schemaDecoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
