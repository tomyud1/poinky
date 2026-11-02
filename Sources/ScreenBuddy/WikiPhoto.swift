import Foundation

/// Finds a photo of a real thing (the lead image of its Wikipedia article) for the polaroid pinned
/// next to a 3D model or lesson. Only the photo's name (e.g. "Iron Dome") is sent, to Wikipedia.
enum WikiPhoto {
    struct Photo { let dataURL: String; let title: String }

    static func find(_ query: String, width: Int = 640) async -> Photo? {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: query), .init(name: "gsrlimit", value: "3"),
            .init(name: "prop", value: "pageimages"), .init(name: "piprop", value: "thumbnail"),
            .init(name: "pithumbsize", value: "\(width)"), .init(name: "redirects", value: "1"),
        ]
        guard let url = c.url,
              let json = try? JSONSerialization.jsonObject(with: try await get(url).0) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return nil }
        // Search order is in "index"; take the best match that has an image.
        let ranked = pages.values.sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
        for page in ranked {
            guard let src = (page["thumbnail"] as? [String: Any])?["source"] as? String, let imgURL = URL(string: src),
                  let (data, resp) = try? await get(imgURL), !data.isEmpty, data.count < 3_000_000 else { continue }
            let type = (resp as? HTTPURLResponse)?.mimeType ?? "image/jpeg"
            guard type.hasPrefix("image/") else { continue }
            return Photo(dataURL: "data:\(type);base64,\(data.base64EncodedString())", title: page["title"] as? String ?? query)
        }
        return nil
    }

    private static func get(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Poinky/1.0 (macOS desktop app)", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: req)
    }
}
