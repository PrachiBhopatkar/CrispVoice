import Foundation

struct CrispResult: Equatable {
    let variants: [String]

    enum ParseError: Error { case noJSONObject, decodeFailed }

    private struct Payload: Decodable {
        let variants: [String]
    }

    /// Extracts the first top-level JSON object from `text` (tolerating code
    /// fences / surrounding prose) and decodes its `variants` array.
    static func parse(_ text: String) throws -> CrispResult {
        guard let jsonObject = firstJSONObject(in: text) else {
            throw ParseError.noJSONObject
        }

        guard let data = jsonObject.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ParseError.decodeFailed
        }

        return CrispResult(variants: payload.variants)
    }

    private static func firstJSONObject(in text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var inString = false
        var isEscaping = false

        for index in text.indices {
            let character = text[index]

            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == "\"" {
                inString.toggle()
                continue
            }

            guard !inString else { continue }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
            }
        }

        return nil
    }
}
