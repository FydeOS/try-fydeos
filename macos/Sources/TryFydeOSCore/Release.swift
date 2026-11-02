import Foundation

/// The latest image the release API lists for a board.
public struct Release: Equatable, Sendable {
    public var version: String
    public var releaseDate: String
    public var fileName: String
    public var sha256: String
    public var url: String

    public init(version: String, releaseDate: String, fileName: String, sha256: String, url: String) {
        self.version = version
        self.releaseDate = releaseDate
        self.fileName = fileName
        self.sha256 = sha256
        self.url = url
    }
}

public let releaseTimeout: TimeInterval = 5

func shortSession(timeout: TimeInterval) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.urlCache = nil
    return URLSession(configuration: config)
}

func statusText(_ code: Int) -> String {
    "\(code) \(HTTPURLResponse.localizedString(forStatusCode: code))"
}

private struct Listing: Decodable {
    struct Entry: Decodable {
        struct Download: Decodable {
            var type: String?
            var url: String?
        }
        var board: String?
        var version: String?
        var releaseDate: String?
        var fileName: String?
        var checksum: String?
        var isEOL: Bool?
        var downloadUrls: [Download]?
    }
    var list: [Entry]?
}

/// Asks the release API for `board`'s entry and its official download.
public func fetchRelease(api: String, board: String, appVersion: String, timeout: TimeInterval = releaseTimeout) async throws -> Release {
    guard let url = URL(string: api) else { throw ConfigError.invalid("\(api) is not a URL") }
    var request = URLRequest(url: url)
    request.setValue("Try FydeOS/\(appVersion)", forHTTPHeaderField: "User-Agent")
    let session = shortSession(timeout: timeout)
    defer { session.finishTasksAndInvalidate() }
    let data: Data, response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch {
        throw ConfigError.invalid("\(api): \(error.localizedDescription)")
    }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw ConfigError.invalid("\(api): \(statusText(code))") }
    guard data.count <= 4 << 20 else { throw ConfigError.invalid("\(api): answer larger than 4 MiB") }
    let listing: Listing
    do {
        listing = try JSONDecoder().decode(Listing.self, from: data)
    } catch {
        throw ConfigError.invalid("\(api): malformed JSON: \(error)")
    }
    for e in listing.list ?? [] where e.board == board {
        if e.isEOL == true { throw ConfigError.invalid("\(api): \(board) is end of life") }
        let checksum = e.checksum ?? ""
        guard isSHA256(checksum) else { throw ConfigError.invalid("\(api): \(board) has a malformed checksum \"\(checksum)\"") }
        guard let official = e.downloadUrls?.first(where: { $0.type == "official" }) else {
            throw ConfigError.invalid("\(api): \(board) has no official download")
        }
        let link = official.url ?? "", fileName = e.fileName ?? ""
        guard let name = try? urlFileName(link), isHTTPS(link), name == fileName else {
            throw ConfigError.invalid("\(api): \(board) has a malformed download \"\(link)\" for \"\(fileName)\"")
        }
        return Release(version: e.version ?? "", releaseDate: e.releaseDate ?? "", fileName: fileName, sha256: checksum, url: link)
    }
    throw ConfigError.invalid("\(api) lists no \(board) image")
}
