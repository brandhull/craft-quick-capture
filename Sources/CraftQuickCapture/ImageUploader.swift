import Foundation

enum UploadError: LocalizedError {
    case allHostsFailed
    var errorDescription: String? { "Image upload failed (tmpfiles.org and litterbox both unreachable)" }
}

/// Craft's API only ingests images it can fetch from a public URL (data URIs are
/// silently dropped). We relay through a short-lived host; Craft copies the image
/// to its own CDN within seconds of the blocks-add call, then the temp copy expires.
enum ImageUploader {
    static func upload(_ data: Data, filename: String) async throws -> String {
        if let url = try? await uploadTmpfiles(data, filename: filename) { return url }
        if let url = try? await uploadLitterbox(data, filename: filename) { return url }
        throw UploadError.allHostsFailed
    }

    private static func multipartBody(boundary: String, fields: [String: String],
                                      fileField: String, filename: String, data: Data) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func post(_ urlString: String, boundary: String, body: Data) async throws -> Data {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CraftError.http(http.statusCode)
        }
        return data
    }

    /// tmpfiles.org — 60 min retention. Returned page URL must be rewritten
    /// to the /dl/ direct link or Craft gets an HTML page.
    private static func uploadTmpfiles(_ data: Data, filename: String) async throws -> String {
        let boundary = "----CQC\(UUID().uuidString)"
        let body = multipartBody(boundary: boundary, fields: [:],
                                 fileField: "file", filename: filename, data: data)
        let resp = try await post("https://tmpfiles.org/api/v1/upload", boundary: boundary, body: body)
        guard let obj = try JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let payload = obj["data"] as? [String: Any],
              let url = payload["url"] as? String
        else { throw CraftError.badResponse }
        return url.replacingOccurrences(of: "tmpfiles.org/", with: "tmpfiles.org/dl/")
    }

    /// litterbox.catbox.moe — 1 h retention, returns the direct URL as plain text.
    private static func uploadLitterbox(_ data: Data, filename: String) async throws -> String {
        let boundary = "----CQC\(UUID().uuidString)"
        let body = multipartBody(boundary: boundary,
                                 fields: ["reqtype": "fileupload", "time": "1h"],
                                 fileField: "fileToUpload", filename: filename, data: data)
        let resp = try await post("https://litterbox.catbox.moe/resources/internals/api.php",
                                  boundary: boundary, body: body)
        let url = String(decoding: resp, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("https://") else { throw CraftError.badResponse }
        return url
    }
}
