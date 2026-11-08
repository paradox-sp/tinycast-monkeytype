import Foundation

@MainActor
final class PassageProvider {
    private struct QuoteRecord: Decodable, Sendable {
        let id: Int
        let text: String
        let source: String?
        let length: Int?
    }

    private struct QuoteFile: Decodable, Sendable {
        let quotes: [QuoteRecord]
        let groups: [[Int]]
    }

    private struct Collection: Sendable {
        let passages: [Passage]
        let categories: [[Int]]
    }

    private let session: URLSession
    private static let categoryNames = ["short", "medium", "long", "extraLong"]
    private var collection: Collection?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func randomPassage(for mode: PracticeMode) async throws -> Passage {
        let current: Collection
        if let collection {
            current = collection
        } else {
            let fetched = try await Self.fetch(using: session)
            try Task.checkCancellation()
            collection = fetched
            current = fetched
        }
        if mode.quoteType == "all", let passage = current.passages.randomElement() { return passage }
        guard let index = Self.categoryNames.firstIndex(of: mode.quoteType),
              let passageIndex = current.categories[index].randomElement() else {
            throw ProviderError.unavailable("No quotes are available for this practice mode.")
        }
        return current.passages[passageIndex]
    }

    @concurrent
    private static func fetch(using session: URLSession) async throws -> Collection {
        let url = URL(string: "https://raw.githubusercontent.com/monkeytypegame/monkeytype/master/frontend/static/quotes/english.json")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.unavailable("The quote collection could not be downloaded.")
        }
        let file = try JSONDecoder().decode(QuoteFile.self, from: data)
        guard file.groups.count == 4, file.groups.allSatisfy({ $0.count == 2 && $0[0] <= $0[1] }) else {
            throw ProviderError.unavailable("The quote collection has unsupported length categories.")
        }
        var passages: [Passage] = []
        passages.reserveCapacity(file.quotes.count)
        var categories = [[Int]](repeating: [], count: 4)
        for record in file.quotes where !record.text.isEmpty {
            let index = passages.count
            passages.append(Passage(id: record.id, text: record.text, source: record.source ?? ""))
            let length = record.length ?? record.text.utf16.count
            for category in file.groups.indices where (file.groups[category][0]...file.groups[category][1]).contains(length) {
                categories[category].append(index)
            }
        }
        guard !passages.isEmpty else { throw ProviderError.unavailable("The quote collection is empty.") }
        return Collection(passages: passages, categories: categories)
    }

    private enum ProviderError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): return message }
        }
    }
}
