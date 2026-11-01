import Foundation
import CoreGraphics
import Vision

/// One line of text found in the flattened canvas, its box in document pixels with a top-left origin.
nonisolated struct TextLine: Equatable, Sendable {
    let id: Int
    let text: String
    let box: CGRect

    var json: JSONValue {
        .object(["id": .int(id), "text": .string(text), "box": .object([
            "x": .int(Int(box.minX.rounded())), "y": .int(Int(box.minY.rounded())),
            "width": .int(Int(box.width.rounded())), "height": .int(Int(box.height.rounded()))])])
    }
}

/// Carries a CGImage into Vision's detached task.
nonisolated private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

nonisolated enum TextLines {
    /// Vision's box (normalized, bottom-left origin) as document pixels with a top-left origin.
    static func documentRect(fromNormalized box: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
    }

    /// The lines whose box's center lies inside `path` (document pixels), as "these lines" means.
    static func lines(_ lines: [TextLine], inside path: CGPath) -> [TextLine] {
        lines.filter { path.contains(CGPoint(x: $0.box.midX, y: $0.box.midY), using: .winding) }
    }

    /// A highlighter mark over a line: 15% of its height above and below, a few pixels either side.
    static func highlightRect(for box: CGRect, verticalPadding: CGFloat = 0.15, horizontalPadding: CGFloat = 4) -> CGRect {
        box.insetBy(dx: -horizontalPadding, dy: -box.height * verticalPadding)
    }

    /// A mark's corner radius: slightly rounded, never more than a quarter of its height. Never past half either side
    /// either, which `CGPath(roundedRect:…)` traps on.
    static func cornerRadius(for rect: CGRect) -> CGFloat {
        max(0, min(rect.height / 4, rect.width / 2, 6))
    }

    /// Reading order: top to bottom, and left to right along lines that share a row.
    static func readingOrder(_ boxes: [(text: String, box: CGRect)]) -> [TextLine] {
        // Rows from the top: a box joins the row above when its center is within half that row's first box's height.
        var rows: [[(text: String, box: CGRect)]] = []
        for item in boxes.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let first = rows.last?.first, abs(item.box.midY - first.box.midY) < first.box.height / 2 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        let ordered = rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
        return ordered.enumerated().map { TextLine(id: $0.offset + 1, text: $0.element.text, box: $0.element.box) }
    }

    /// Recognizes the text in `image` on the Mac (nothing leaves it), as lines in the image's pixels.
    static func recognize(_ image: CGImage) async throws -> [TextLine] {
        let box = ImageBox(image: image)
        // VERIFY(macOS): VNRecognizeTextRequest may be marked deprecated in the macOS 26 SDK in favor of Swift's
        // RecognizeTextRequest; a warning only. Its results should be [VNRecognizedTextObservation].
        let found = try await Task.detached(priority: .userInitiated) { () throws -> [(text: String, box: CGRect)] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: box.image, options: [:])
            try handler.perform([request])
            let width = box.image.width, height = box.image.height
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                return (text: text, box: TextLines.documentRect(fromNormalized: observation.boundingBox, width: width, height: height))
            }
        }.value
        return readingOrder(found)
    }
}

/// A highlighter color, by name or as hex.
nonisolated struct HighlightColor: Equatable, Sendable {
    /// "Pink", or "#12AB34" for one given as hex: what the layer is named after.
    let name: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    static let named: [String: String] = [
        "pink": "FF7AC6", "yellow": "FFE24D", "green": "8EF08A", "blue": "7CC8FF", "orange": "FFB35C",
        "purple": "C9A2FF", "red": "FF7A7A", "cyan": "6FF0F0", "gray": "C8C8C8", "grey": "C8C8C8",
    ]

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hex = Self.named[value] {
            self.init(hex: hex, name: value.prefix(1).uppercased() + value.dropFirst())
        } else {
            let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
            self.init(hex: digits, name: nil)
        }
    }

    private init?(hex: String, name: String?) {
        var digits = hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
        self.name = name ?? "#" + digits.uppercased()
        red = CGFloat((number >> 16) & 0xFF) / 255
        green = CGFloat((number >> 8) & 0xFF) / 255
        blue = CGFloat(number & 0xFF) / 255
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
    }
}
