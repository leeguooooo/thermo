import AgentCore
import Foundation

/// Downloads one catalog when a page opens. No cookies, https all the way, a size cap.
enum StoreFetch {
    static let limit = 2 << 20

    static func data(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse,
              http.statusCode == 200, http.url?.scheme?.lowercased() == "https", data.count <= limit else { return nil }
        return data
    }
}
