import Darwin
import Foundation

/// Keeps the downloaded FydeOS images.
public var imagesDir: URL { Workspace.appSupportURL.appendingPathComponent("images") }

/// Parses "bytes first-last/total" or "bytes */total"; `first` is -1 for the latter.
func contentRange(_ header: String?) throws -> (first: Int64, total: Int64) {
    let malformed = ConfigError.invalid("malformed Content-Range \"\(header ?? "")\"")
    guard let header, header.hasPrefix("bytes ") else { throw malformed }
    let parts = header.dropFirst(6).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let total = Int64(parts[1]) else { throw malformed }
    if parts[0] == "*" { return (-1, total) }
    guard let first = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.flatMap({ Int64($0) }) else {
        throw malformed
    }
    return (first, total)
}

/// Asks for the first byte of `url` and reads the total from the answer's Content-Range.
public func remoteSize(url: String, timeout: TimeInterval = releaseTimeout) async throws -> Int64 {
    guard let u = URL(string: url) else { throw ConfigError.invalid("\(url) is not a URL") }
    var request = URLRequest(url: u)
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    let session = shortSession(timeout: timeout)
    defer { session.invalidateAndCancel() }
    let response: URLResponse
    do {
        (_, response) = try await session.bytes(for: request)
    } catch {
        throw ConfigError.invalid("\(url): \(error.localizedDescription)")
    }
    let http = response as? HTTPURLResponse
    switch http?.statusCode {
    case 206:
        do {
            return try contentRange(http?.value(forHTTPHeaderField: "Content-Range")).total
        } catch {
            throw ConfigError.invalid("\(url): \(error)")
        }
    case 200 where response.expectedContentLength >= 0:
        return response.expectedContentLength
    default:
        throw ConfigError.invalid("\(url): \(statusText(http?.statusCode ?? 0)), no size")
    }
}

/// Fetches `url` into `dest` through `dest.part`, resuming a part left by an earlier attempt, and checks
/// the finished file's size and sha256 before the rename. A mismatch deletes the part.
public func download(url: String, size: Int64, sha256: String, to dest: URL,
                     progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws {
    guard size > 0 else { throw ConfigError.invalid("\(url): no expected size") }
    guard let u = URL(string: url) else { throw ConfigError.invalid("\(url) is not a URL") }
    let part = URL(fileURLWithPath: dest.path + ".part")
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
    if have > size { have = 0 }
    var request = URLRequest(url: u)
    if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
    // Ranges address the file itself, never a compressed transfer of it.
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let receiver = Receiver(url: url, part: part, have: have, size: size, progress: progress)
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.timeoutIntervalForRequest = 60
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: config, delegate: receiver, delegateQueue: queue)
    defer { session.finishTasksAndInvalidate() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        receiver.continuation = continuation
        session.dataTask(with: request).resume()
    }
    let got = try FactorySpec.sha256(of: part)
    guard got == sha256 else {
        try? FileManager.default.removeItem(at: part)
        throw ConfigError.invalid("\(url): downloaded sha256 \(got), expected \(sha256)")
    }
    progress(size, size)
    guard rename(part.path, dest.path) == 0 else { throw WorkspaceError.system("rename \(part.path) -> \(dest.path)", errno) }
}

/// Writes the body into the part file from `have` on and reports progress every 1 %.
private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: String
    let part: URL
    var have: Int64
    let size: Int64
    let progress: (Int64, Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var fd: Int32 = -1
    private var done: Int64 = 0
    private var lastStep: Int64 = -1
    private var failure: Error?
    private var complete = false

    init(url: String, part: URL, have: Int64, size: Int64, progress: @escaping (Int64, Int64) -> Void) {
        self.url = url
        self.part = part
        self.have = have
        self.size = size
        self.progress = progress
    }

    private func fail(_ message: String) -> URLSession.ResponseDisposition {
        failure = ConfigError.invalid(message)
        return .cancel
    }

    private func decide(_ response: URLResponse) -> URLSession.ResponseDisposition {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        switch code {
        case 200:
            have = 0
            if response.expectedContentLength >= 0, response.expectedContentLength != size {
                return fail("\(url) is \(response.expectedContentLength) bytes, expected \(size)")
            }
        case 206:
            let header = http?.value(forHTTPHeaderField: "Content-Range")
            guard let range = try? contentRange(header) else { return fail("\(url): malformed Content-Range \"\(header ?? "")\"") }
            guard range.first == have, range.total == size else {
                return fail("\(url): asked for bytes \(have)- of \(size), got Content-Range \"\(header ?? "")\"")
            }
        case 416:
            guard have == size else {
                try? FileManager.default.removeItem(at: part)
                return fail("\(url): \(statusText(code)) for bytes \(have)- of \(size)")
            }
            complete = true
            return .cancel
        default:
            return fail("\(url): \(statusText(code))")
        }
        fd = Darwin.open(part.path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0, ftruncate(fd, off_t(have)) == 0, lseek(fd, off_t(have), SEEK_SET) == have else {
            return fail("downloading \(url): \(part.path): \(String(cString: strerror(errno)))")
        }
        done = have
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(decide(response))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard done + Int64(data.count) <= size else {
            failure = ConfigError.invalid("downloading \(url): more than the expected \(size) bytes")
            dataTask.cancel()
            return
        }
        let ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        guard ok else {
            failure = ConfigError.invalid("downloading \(url): \(part.path): \(String(cString: strerror(errno)))")
            dataTask.cancel()
            return
        }
        done += Int64(data.count)
        if done * 100 / size != lastStep {
            lastStep = done * 100 / size
            progress(done, size)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if fd >= 0 {
            if close(fd) != 0, failure == nil {
                failure = ConfigError.invalid("downloading \(url): \(part.path): \(String(cString: strerror(errno)))")
            }
            fd = -1
        }
        let result: Result<Void, Error>
        if let failure {
            result = .failure(failure)
        } else if complete {
            result = .success(())
        } else if let error {
            result = .failure(ConfigError.invalid("downloading \(url): \(error.localizedDescription)"))
        } else if done != size {
            result = .failure(ConfigError.invalid("downloading \(url): got \(done) of \(size) bytes"))
        } else {
            result = .success(())
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}
