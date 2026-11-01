import AppKit
import CoreGraphics

/// Why a tool call couldn't be carried out. Sent back to the model as the call's result, so it can try again.
nonisolated enum ToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case malformedArguments
    case invalidArgument(String, expected: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "There is no tool called “\(name)”."
        case .malformedArguments: "The arguments aren’t a JSON object."
        case .invalidArgument(let key, let expected): "`\(key)` should be \(expected)."
        case .failed(let message): message
        }
    }

    static let noDocument = ToolError.failed("No document is open.")
    static let busy = ToolError.failed("The editor is busy: a dialog, transform, crop, text edit or gesture is in progress, "
        + "or another operation is running. Ask the user to finish it, then try again.")
}

/// A tool call's arguments: the JSON object the model wrote, read leniently (a number may come as text, and so on).
nonisolated struct ToolArguments: Equatable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue] = [:]) { self.values = values }

    /// An empty string is no arguments, as some models send for tools without parameters.
    init(json: String) throws {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { values = [:]; return }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { throw ToolError.malformedArguments }
        switch value {
        case .object(let object): values = object
        case .null: values = [:]
        default: throw ToolError.malformedArguments
        }
    }

    private func lookup(_ key: String) -> JSONValue? {
        guard let value = values[key], value != .null else { return nil }
        return value
    }

    func int(_ key: String) throws -> Int? {
        guard let value = lookup(key) else { return nil }
        if let number = Self.integer(value) { return number }
        throw ToolError.invalidArgument(key, expected: "a whole number")
    }

    func double(_ key: String) throws -> Double? {
        switch lookup(key) {
        case nil: return nil
        case .number(let number)? where number.isFinite: return number
        case .string(let text)? where Double(text.trimmingCharacters(in: .whitespaces))?.isFinite == true:
            return Double(text.trimmingCharacters(in: .whitespaces))
        default: throw ToolError.invalidArgument(key, expected: "a number")
        }
    }

    func bool(_ key: String) throws -> Bool? {
        switch lookup(key) {
        case nil: return nil
        case .bool(let flag)?: return flag
        case .string(let text)? where ["true", "false"].contains(text.lowercased()): return text.lowercased() == "true"
        default: throw ToolError.invalidArgument(key, expected: "true or false")
        }
    }

    func string(_ key: String) throws -> String? {
        switch lookup(key) {
        case nil: return nil
        case .string(let text)?: return text
        default: throw ToolError.invalidArgument(key, expected: "a string")
        }
    }

    /// A list of whole numbers; a single number counts as a list of one.
    func ints(_ key: String) throws -> [Int]? {
        switch lookup(key) {
        case nil: return nil
        case .array(let items)?:
            let numbers = items.compactMap(Self.integer)
            guard numbers.count == items.count else { throw ToolError.invalidArgument(key, expected: "a list of whole numbers") }
            return numbers
        case let single?:
            guard let number = Self.integer(single) else { throw ToolError.invalidArgument(key, expected: "a list of whole numbers") }
            return [number]
        }
    }

    private static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .number(let number) where number.isFinite && abs(number) < 1e12: return Int(number.rounded())
        case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

nonisolated struct PixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// `resize_image`'s arithmetic: the new canvas size from whichever sides the model gave.
nonisolated enum ResizePlan {
    /// `longEdge` scales the longer side to it and the other to match. A width or height alone keeps the aspect ratio
    /// (or the other side, with `keepAspect` off); both are used as given.
    static func size(from current: PixelSize, width: Int?, height: Int?, longEdge: Int?, keepAspect: Bool = true) throws -> PixelSize {
        for (key, value) in [("width", width), ("height", height), ("long_edge", longEdge)] {
            if let value, value < 1 { throw ToolError.invalidArgument(key, expected: "at least 1") }
        }
        let w = Double(current.width), h = Double(current.height)
        func scaled(_ side: Double, by factor: Double) -> Int { max(1, Int((side * factor).rounded())) }
        let result: PixelSize
        if let longEdge {
            let factor = Double(longEdge) / max(w, h)
            result = current.width >= current.height
                ? PixelSize(width: longEdge, height: scaled(h, by: factor))
                : PixelSize(width: scaled(w, by: factor), height: longEdge)
        } else if let width, let height {
            result = PixelSize(width: width, height: height)
        } else if let width {
            result = PixelSize(width: width, height: keepAspect ? scaled(h, by: Double(width) / w) : current.height)
        } else if let height {
            result = PixelSize(width: keepAspect ? scaled(w, by: Double(height) / h) : current.width, height: height)
        } else {
            throw ToolError.failed("Give width, height or long_edge.")
        }
        guard result.width <= DocumentLimits.maxSide, result.height <= DocumentLimits.maxSide,
              result.width * result.height <= DocumentLimits.maxSurfacePixels else {
            throw ToolError.failed("\(result.width) × \(result.height) is too large: at most \(DocumentLimits.maxSide.formatted()) pixels a side and \(DocumentLimits.maxSurfaceMegapixels) megapixels.")
        }
        return result
    }
}

/// The tools the model can call. Adding one: a case here, its description and schema, and its branch in
/// `AssistantToolRunner.perform`.
nonisolated enum AssistantTool: String, CaseIterable, Sendable {
    case getDocumentInfo = "get_document_info"
    case resizeImage = "resize_image"
    case exportPNG = "export_png"
    case recognizeText = "recognize_text"
    case highlightLines = "highlight_lines"
    case undo

    var summary: String {
        switch self {
        case .getDocumentInfo: "The canvas's size and resolution, its name, its layers (bottom to top), the active layer and the selection's bounds."
        case .resizeImage: "Resizes the whole image (Image Size), resampling every layer. Give width, height or long_edge in pixels; the missing side follows the aspect ratio. One undo step."
        case .exportPNG: "Exports the flattened canvas as a PNG. The user picks where in a save panel; the result says where it was saved, or that they cancelled."
        case .recognizeText: "Finds the lines of text in the flattened canvas, on this Mac. Returns each line's id, text and box in document pixels (top-left origin). Call it before highlight_lines."
        case .highlightLines: "Draws highlighter marks over lines found by recognize_text, by id, on a layer of their own per color (made if missing, multiplied over the text). One undo step."
        case .undo: "Undoes the last change to the document, as Edit › Undo does."
        }
    }

    var parameters: JSONValue {
        func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties),
                     "required": .array(required.map(JSONValue.string))])
        }
        func property(_ type: String, _ description: String) -> JSONValue {
            .object(["type": .string(type), "description": .string(description)])
        }
        switch self {
        case .getDocumentInfo, .exportPNG, .undo:
            return schema([:])
        case .resizeImage:
            return schema([
                "width": property("integer", "New width in pixels."),
                "height": property("integer", "New height in pixels."),
                "long_edge": property("integer", "New length of the longer side in pixels; the shorter follows."),
                "keep_aspect": property("boolean", "Keep the aspect ratio when only width or height is given. Default true."),
                "resolution": property("number", "Pixels per inch, 1–9600. Default: unchanged."),
            ])
        case .recognizeText:
            return schema([
                "within_selection": property("boolean", "Only lines whose center is inside the user's selection. Default false."),
            ])
        case .highlightLines:
            return schema([
                "line_ids": .object(["type": .string("array"), "items": .object(["type": .string("integer")]),
                                     "description": .string("Ids of lines from recognize_text.")]),
                "color": property("string", "pink, yellow, green, blue, orange, purple, red, cyan or gray, or a hex color like #FF7AC6."),
                "layer_name": property("string", "Layer to draw on. Default “Highlight <Color>”, one per color."),
            ], required: ["line_ids", "color"])
        }
    }

    static var definitions: [ToolDefinition] {
        allCases.map { ToolDefinition(name: $0.rawValue, description: $0.summary, parameters: $0.parameters) }
    }
}

/// A tool call's result: the JSON text the model reads, and the line the chat shows.
nonisolated struct ToolOutcome: Equatable, Sendable {
    let content: String
    let summary: String
    let failed: Bool
}

/// Carries out the model's tool calls on one project's session, on the main actor, each document change one undo step.
@MainActor
final class AssistantToolRunner {
    let session: EditorSession
    let controller: ProjectController
    /// The document's name for exports: the project's, or the tab's while it's unsaved.
    var sourceName: () -> String = { "Untitled" }
    /// The lines `recognize_text` last found, for `highlight_lines` to look up by id while the canvas stays as it was.
    private var recognized: (documentID: UUID, size: CGSize, lines: [TextLine])?

    init(session: EditorSession, controller: ProjectController) {
        self.session = session
        self.controller = controller
    }

    func forgetRecognizedText() { recognized = nil }

    func run(_ call: ToolCall) async -> ToolOutcome {
        guard let tool = AssistantTool(rawValue: call.function.name) else {
            return Self.failure(call.function.name, ToolError.unknownTool(call.function.name))
        }
        do {
            let (result, summary) = try await perform(tool, ToolArguments(json: call.function.arguments))
            return ToolOutcome(content: result.encodedString, summary: summary, failed: false)
        } catch {
            return Self.failure(tool.rawValue, error)
        }
    }

    private static func failure(_ name: String, _ error: Error) -> ToolOutcome {
        let message = error.localizedDescription
        return ToolOutcome(content: JSONValue.object(["error": .string(message)]).encodedString,
                           summary: "\(name) failed: \(message)", failed: true)
    }

    /// Edits wait for whatever's in progress: a sheet, a dialog, a gesture, a transform, a long operation.
    private func requireEditable() throws {
        guard session.document != nil else { throw ToolError.noDocument }
        guard controller.window?.attachedSheet == nil, session.canEditLayers, controller.canStart else { throw ToolError.busy }
    }

    private func perform(_ tool: AssistantTool, _ arguments: ToolArguments) async throws -> (JSONValue, String) {
        switch tool {
        case .getDocumentInfo: return (try documentInfo(), "Read the document’s info")
        case .resizeImage: return try await resize(arguments)
        case .exportPNG: return try await exportPNG()
        case .recognizeText: return try await recognizeText(arguments)
        case .highlightLines: return try highlightLines(arguments)
        case .undo: return try undo()
        }
    }

    // MARK: Tools

    private func documentInfo() throws -> JSONValue {
        guard let document = session.document else { throw ToolError.noDocument }
        let layers: [JSONValue] = document.layers.map { layer in
            var record: [String: JSONValue] = [
                "id": .string(layer.id.uuidString), "name": .string(layer.name), "visible": .bool(layer.isVisible),
                "opacity": .number((layer.opacity * 100).rounded() / 100), "blend_mode": .string(layer.blendMode.rawValue),
                "kind": .string(Self.kind(of: layer)),
            ]
            if let parent = layer.parentID { record["folder_id"] = .string(parent.uuidString) }
            return .object(record)
        }
        return .object([
            "width": .int(document.width), "height": .int(document.height), "resolution": .number(document.resolution),
            "sourceName": .string(sourceName()),
            "layers": .array(layers), "layer_order": .string("bottom_to_top"),
            "active_layer_id": session.activeLayerID.map { JSONValue.string($0.uuidString) } ?? JSONValue.null,
            "selection": Self.selectionBounds(session.selection),
        ])
    }

    static func kind(of layer: ImageLayer) -> String {
        if layer.isGroup { return "folder" }
        if layer.adjustment != nil { return "adjustment" }
        if layer.text != nil { return "text" }
        if layer.shape != nil { return "shape" }
        if layer.gifAnimation != nil { return "gif" }
        return layer.asset == nil ? "empty" : "pixels"
    }

    static func selectionBounds(_ selection: DocumentSelection?) -> JSONValue {
        guard let selection else { return .null }
        if selection.isEmpty { return .object(["empty": .bool(true)]) }
        let box = selection.path.boundingBoxOfPath.integral
        return .object(["x": .int(Int(box.minX)), "y": .int(Int(box.minY)), "width": .int(Int(box.width)), "height": .int(Int(box.height))])
    }

    private func resize(_ arguments: ToolArguments) async throws -> (JSONValue, String) {
        try requireEditable()
        guard let document = session.document else { throw ToolError.noDocument }
        let size = try ResizePlan.size(from: PixelSize(width: document.width, height: document.height),
                                       width: arguments.int("width"), height: arguments.int("height"),
                                       longEdge: arguments.int("long_edge"), keepAspect: arguments.bool("keep_aspect") ?? true)
        let resolution = try arguments.double("resolution") ?? document.resolution
        guard (1...9600).contains(resolution) else { throw ToolError.invalidArgument("resolution", expected: "between 1 and 9600") }
        guard try await controller.resizeImage(to: ImageSizeOptions(width: size.width, height: size.height, resolution: resolution))
        else { throw ToolError.busy }
        return (.object(["width": .int(size.width), "height": .int(size.height), "resolution": .number(resolution),
                         "previous": .object(["width": .int(document.width), "height": .int(document.height)])]),
                "Resized to \(size.width) × \(size.height)")
    }

    private func exportPNG() async throws -> (JSONValue, String) {
        try requireEditable()
        switch try await controller.exportPNGFile(named: sourceName()) {
        case .saved(let url):
            return (.object(["saved_to": .string(url.path)]), "Exported “\(url.lastPathComponent)”")
        case .cancelled:
            return (.object(["cancelled": .bool(true), "message": .string("The user cancelled the save panel.")]), "Export cancelled")
        case .unavailable:
            throw ToolError.busy
        }
    }

    private func recognizeText(_ arguments: ToolArguments) async throws -> (JSONValue, String) {
        guard let document = session.document else { throw ToolError.noDocument }
        let withinSelection = try arguments.bool("within_selection") ?? false
        var outline: CGPath?
        if withinSelection {
            guard let selection = session.selection, !selection.isEmpty else {
                throw ToolError.failed("Nothing is selected. Ask the user to select the lines with the Marquee or Lasso, or call recognize_text without within_selection.")
            }
            outline = selection.path
        }
        guard session.canEditLayers, let snapshot = session.projectSnapshot() else { throw ToolError.busy }
        // On white, so text on transparent pixels reads as it looks.
        let raster = try await ImageExporter.shared.render(snapshot)
        let opaque = try await ImageExporter.shared.flattened(raster, over: CGColor(gray: 1, alpha: 1))
        let lines = try await TextLines.recognize(opaque)
        recognized = (document.id, document.size, lines)
        let found = outline.map { TextLines.lines(lines, inside: $0) } ?? lines
        // Enough for a few dense pages; the rest are dropped rather than flooding the conversation.
        let sent = found.prefix(600)
        let place = withinSelection ? " in the selection" : ""
        return (.object(["line_count": .int(found.count), "within_selection": .bool(withinSelection),
                         "truncated": .bool(sent.count < found.count), "lines": .array(sent.map(\.json))]),
                found.count == 1 ? "Found 1 line of text\(place)" : "Found \(found.count) lines of text\(place)")
    }

    private func highlightLines(_ arguments: ToolArguments) throws -> (JSONValue, String) {
        guard let requested = try arguments.ints("line_ids"), !requested.isEmpty else {
            throw ToolError.invalidArgument("line_ids", expected: "a list of line ids from recognize_text")
        }
        guard let text = try arguments.string("color"), let color = HighlightColor(text) else {
            throw ToolError.invalidArgument("color", expected: "a color name (pink, yellow, green, blue, orange, purple, red, cyan, gray) or a hex color like #FF7AC6")
        }
        try requireEditable()
        guard let document = session.document else { throw ToolError.noDocument }
        guard let recognized, recognized.documentID == document.id, recognized.size == document.size else {
            throw ToolError.failed("Call recognize_text first: no lines have been found in the document as it is now.")
        }
        var seen: Set<Int> = []
        let ids = requested.filter { seen.insert($0).inserted }
        let byID = Dictionary(recognized.lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lines = ids.compactMap { byID[$0] }
        let unknown = ids.filter { byID[$0] == nil }
        guard !lines.isEmpty else {
            throw ToolError.failed("None of these are ids of recognized lines: \(unknown.map(String.init).joined(separator: ", ")).")
        }
        let named = try arguments.string("layer_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let layerName = named.flatMap { $0.isEmpty ? nil : $0 } ?? "Highlight \(color.name)"
        let result = try session.highlight(lines.map(\.box), color: color, layerName: layerName)
        let colorName = color.name.hasPrefix("#") ? color.name : color.name.lowercased()
        return (.object(["highlighted": .int(lines.count), "layer_name": .string(result.layerName),
                         "layer_id": .string(result.layerID.uuidString), "created_layer": .bool(result.created),
                         "unknown_ids": .array(unknown.map(JSONValue.int))]),
                lines.count == 1 ? "Highlighted 1 line in \(colorName)" : "Highlighted \(lines.count) lines in \(colorName)")
    }

    private func undo() throws -> (JSONValue, String) {
        guard session.document != nil else { throw ToolError.noDocument }
        guard session.canUndo else { throw session.history.canUndo ? ToolError.busy : ToolError.failed("There is nothing to undo.") }
        let name = session.history.undoName
        session.undo()
        return (.object(["undone": .string(name)]), name.isEmpty ? "Undid the last change" : "Undid \(name)")
    }
}
