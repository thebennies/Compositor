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

    /// A box in document pixels: `{x, y, width, height}`, or `[x, y, width, height]`.
    func rect(_ key: String) throws -> CGRect? {
        guard let value = lookup(key) else { return nil }
        let expected = "a box {x, y, width, height} in document pixels"
        let numbers: [Double]
        switch value {
        case .object(let object):
            numbers = ["x", "y", "width", "height"].compactMap { object[$0].flatMap(Self.number) }
        case .array(let items):
            numbers = items.compactMap(Self.number)
            guard items.count == 4 else { throw ToolError.invalidArgument(key, expected: expected) }
        default: throw ToolError.invalidArgument(key, expected: expected)
        }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { throw ToolError.invalidArgument(key, expected: expected) }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Points in document pixels: `[[x, y], …]` or `[{x, y}, …]`; one point alone counts as a list of one.
    func points(_ key: String) throws -> [CGPoint]? {
        guard let value = lookup(key) else { return nil }
        func point(_ value: JSONValue) -> CGPoint? {
            switch value {
            case .array(let pair) where pair.count == 2:
                guard let x = Self.number(pair[0]), let y = Self.number(pair[1]) else { return nil }
                return CGPoint(x: x, y: y)
            case .object(let object):
                guard let x = object["x"].flatMap(Self.number), let y = object["y"].flatMap(Self.number) else { return nil }
                return CGPoint(x: x, y: y)
            default: return nil
            }
        }
        let expected = "a list of points [[x, y], …] in document pixels"
        if let single = point(value) { return [single] }
        guard case .array(let items) = value, !items.isEmpty else { throw ToolError.invalidArgument(key, expected: expected) }
        let points = items.compactMap(point)
        guard points.count == items.count else { throw ToolError.invalidArgument(key, expected: expected) }
        return points
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number) where number.isFinite: return number
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
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
    case lookAtCanvas = "look_at_canvas"
    case select
    case recolor
    case setLayer = "set_layer"
    case resizeImage = "resize_image"
    case exportImage = "export_image"
    case saveProject = "save_project"
    case closeDocument = "close_document"
    case recognizeText = "recognize_text"
    case highlightLines = "highlight_lines"
    case undo

    var summary: String {
        switch self {
        case .getDocumentInfo: "The canvas's size and resolution, its name, its layers (bottom to top), the active layer and the selection's bounds."
        case .lookAtCanvas: "Shows you the canvas as it looks now, in the next message: at most 1024 px on its longer side, with rulers along the top and left numbered in document pixels (read positions off them), and the selection tinted magenta and outlined. Give region to look closer at part of it. Look before selecting, and again to check a selection or an edit."
        case .select: "Changes the selection, one undo step. method: object (Vision outlines the object under each point; give points on it, and box to keep only the part inside it), subject (the main subject, limited to box if given), rectangle or ellipse (box), all, none or invert. mode combines it with the current selection."
        case .recolor: "Changes the color of the selected area with a Hue/Saturation adjustment layer masked to the selection, at the top of the stack, so the photo itself is untouched. Give color to make it that color (its shading kept), or hue_shift / saturation / lightness to shift it. Pass layer_id to change a recolor layer made before instead. One undo step."
        case .setLayer: "Changes a layer by layer_id or layer_name: opacity (percent), visible, name, blend_mode, or delete. One undo step."
        case .resizeImage: "Resizes the whole image (Image Size), resampling every layer. Give width, height or long_edge in pixels; the missing side follows the aspect ratio. One undo step."
        case .exportImage: "Exports the flattened canvas as PNG or JPEG straight to the user's Downloads folder, named after the document and the time; no dialog. Returns where it was saved."
        case .saveProject: "Saves the project (File › Save). A project never saved before asks the user where, in a save panel."
        case .closeDocument: "Closes this document after your reply, as ⌘W does: if it has unsaved changes, the app asks the user to save, not save, or cancel. Say what you did before calling it."
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
        func box(_ description: String) -> JSONValue {
            .object(["type": .string("object"), "description": .string(description), "properties": .object([
                "x": .object(["type": .string("number")]), "y": .object(["type": .string("number")]),
                "width": .object(["type": .string("number")]), "height": .object(["type": .string("number")]),
            ]), "required": .array(["x", "y", "width", "height"].map(JSONValue.string))])
        }
        switch self {
        case .getDocumentInfo, .saveProject, .closeDocument, .undo:
            return schema([:])
        case .lookAtCanvas:
            return schema([
                "region": box("Part of the canvas to look at closely, in document pixels. Default: all of it."),
                "show_selection": property("boolean", "Tint and outline the selection. Default true."),
            ])
        case .select:
            return schema([
                "method": .object(["type": .string("string"), "enum": .array(["object", "subject", "rectangle", "ellipse", "all", "none", "invert"].map(JSONValue.string)),
                                   "description": .string("How to select.")]),
                "points": .object(["type": .string("array"), "items": .object(["type": .string("array"), "items": .object(["type": .string("number")])]),
                                   "description": .string("For object: [[x, y], …] in document pixels, each on the object; one per object to select several (both shoes).")]),
                "box": box("For rectangle and ellipse, the shape; for object and subject, keeps only the part inside it."),
                "mode": .object(["type": .string("string"), "enum": .array(["replace", "add", "subtract", "intersect"].map(JSONValue.string)),
                                 "description": .string("Combine with the current selection. Default replace.")]),
                "feather": property("number", "Soften the edge by this many document pixels, 0–250. Default 0."),
            ], required: ["method"])
        case .recolor:
            return schema([
                "color": property("string", "Target color: a hex like #D62828, or red, orange, yellow, green, teal, cyan, blue, navy, purple, pink, magenta, brown, beige, black, white, gray."),
                "hue_shift": property("number", "Instead of color: turn hues by this many degrees, −180…180."),
                "saturation": property("number", "Instead of color, or with hue_shift: −100 (gray) … 100."),
                "lightness": property("number", "Instead of color, or with hue_shift: −100 (black) … 100 (white)."),
                "layer_id": property("string", "A Hue/Saturation layer made before, to change rather than make a new one."),
                "name": property("string", "The new layer's name. Default “Recolor <color>”."),
                "whole_image": property("boolean", "With nothing selected, recolor everything. Default false."),
            ])
        case .setLayer:
            return schema([
                "layer_id": property("string", "The layer's id from get_document_info."),
                "layer_name": property("string", "Or its name; the topmost of that name."),
                "opacity": property("number", "0–100 percent."),
                "visible": property("boolean", "Show or hide it."),
                "name": property("string", "Rename it."),
                "blend_mode": property("string", "One of: " + LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ") + "."),
                "delete": property("boolean", "Delete the layer."),
            ])
        case .exportImage:
            return schema([
                "format": .object(["type": .string("string"), "enum": .array(["png", "jpeg"].map(JSONValue.string)),
                                   "description": .string("Default png; jpeg for a smaller photo.")]),
                "quality": property("number", "JPEG quality 1–100. Default 90."),
            ])
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
    /// Where `export_image` writes: the user's Downloads folder, which the app may write without asking.
    var exportFolder: () -> URL = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    /// Pictures `look_at_canvas` made, for the conversation to send in a message after the tools' results.
    private var pictures: [String] = []
    /// Set by `close_document`: the document closes once the reply is done, so the chat isn't cut off mid-turn.
    private(set) var closeRequested = false

    init(session: EditorSession, controller: ProjectController) {
        self.session = session
        self.controller = controller
    }

    func forgetRecognizedText() { recognized = nil }

    /// The pictures made since last asked, emptied.
    func takePictures() -> [String] {
        defer { pictures = [] }
        return pictures
    }

    /// Closes the document if `close_document` asked to, as ⌘W does.
    func closeIfRequested() async {
        guard closeRequested else { return }
        closeRequested = false
        if let window = controller.window { await controller.close(window) }
    }

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
        case .lookAtCanvas: return try look(arguments)
        case .select: return try await select(arguments)
        case .recolor: return try recolor(arguments)
        case .setLayer: return try setLayer(arguments)
        case .resizeImage: return try await resize(arguments)
        case .exportImage: return try await exportImage(arguments)
        case .saveProject: return try await save()
        case .closeDocument:
            guard session.document != nil else { throw ToolError.noDocument }
            closeRequested = true
            return (.object(["closing": .bool(true), "note": .string("The document closes after your reply; with unsaved changes the app asks the user first.")]),
                    "Will close the document")
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

    private func look(_ arguments: ToolArguments) throws -> (JSONValue, String) {
        guard let document = session.document else { throw ToolError.noDocument }
        let region = try arguments.rect("region")
        let showSelection = try arguments.bool("show_selection") ?? true
        guard let composite = session.selectionSample(document, sampleAllLayers: true) else { throw ExportError.render }
        let selection = showSelection ? session.selection.flatMap { $0.isEmpty ? nil : $0.path } : nil
        let look = try CanvasLook.render(composite, region: region, selection: selection)
        pictures.append(try CanvasLook.dataURL(look.image))
        let shown = look.region
        return (.object([
            "shown_region": Self.json(shown),
            "document_pixels_per_picture_pixel": .number((look.scale * 1000).rounded() / 1000),
            "selection_shown": .bool(selection != nil),
            "note": .string("The picture follows in the next message. Read positions off its rulers, which are numbered in document pixels."),
        ]), region == nil ? "Looked at the canvas" : "Looked closely at \(Int(shown.width)) × \(Int(shown.height)) px")
    }

    private func select(_ arguments: ToolArguments) async throws -> (JSONValue, String) {
        guard let method = try arguments.string("method")?.lowercased() else {
            throw ToolError.invalidArgument("method", expected: "object, subject, rectangle, ellipse, all, none or invert")
        }
        let modeName = try arguments.string("mode")?.lowercased() ?? "replace"
        guard ["replace", "add", "subtract", "intersect"].contains(modeName) else {
            throw ToolError.invalidArgument("mode", expected: "replace, add, subtract or intersect")
        }
        let feather = try arguments.double("feather") ?? 0
        guard (0...250).contains(feather) else { throw ToolError.invalidArgument("feather", expected: "between 0 and 250") }
        let box = try arguments.rect("box")
        let points = try arguments.points("points")
        try requireEditable()
        guard let document = session.document else { throw ToolError.noDocument }
        let canvas = CGRect(origin: .zero, size: document.size)

        var shape: CGPath
        switch method {
        case "all", "none", "invert":
            switch method {
            case "all": session.selectAll()
            case "none": session.deselect()
            default: session.invertSelection()
            }
            return (selectionReport(), method == "none" ? "Deselected" : method == "all" ? "Selected all" : "Inverted the selection")
        case "rectangle", "ellipse":
            guard let box else { throw ToolError.invalidArgument("box", expected: "the \(method)'s box {x, y, width, height}") }
            shape = method == "rectangle" ? CGPath(rect: box, transform: nil) : CGPath(ellipseIn: box, transform: nil)
        case "object":
            guard let points, !points.isEmpty else { throw ToolError.invalidArgument("points", expected: "points [[x, y], …] on the object") }
            guard points.allSatisfy(canvas.contains) else { throw ToolError.failed("Every point must be on the canvas, 0…\(document.width) × 0…\(document.height).") }
            guard let sample = session.selectionSample(document, sampleAllLayers: true) else { throw ExportError.render }
            shape = try await traced("Object") {
                var found = CGMutablePath() as CGPath
                for point in points {
                    if let outline = try ObjectSelection.select(in: sample, at: point, edgeOffset: 0, smoothEdges: true) {
                        found = found.isEmpty ? outline : found.union(outline, using: .winding)
                    }
                }
                return found
            }
        case "subject":
            guard let sample = session.selectionSample(document, sampleAllLayers: true) else { throw ExportError.render }
            shape = try await traced("Subject") {
                // White where the subject is, so its outline is the selection, as Select › Subject makes it.
                let mask = try SubjectRemoval.subjectMask(sample, under: nil, settings: FilterSettings())
                guard let outline = MaskTracing.whitePixels(in: mask) else { return CGMutablePath() }
                var toDocument = BrushRaster.pixelToDocument(LayerTransform(origin: .zero, size: canvas.size), width: mask.width, height: mask.height)
                return outline.copy(using: &toDocument) ?? CGMutablePath()
            }
        default:
            throw ToolError.invalidArgument("method", expected: "object, subject, rectangle, ellipse, all, none or invert")
        }
        if let box, method == "object" || method == "subject" { shape = shape.intersection(CGPath(rect: box, transform: nil), using: .winding) }
        shape = shape.intersection(CGPath(rect: canvas, transform: nil), using: .winding)
        if shape.isEmpty || shape.boundingBoxOfPath.isEmpty {
            switch method {
            case "object": throw ToolError.failed("No object was found at those points. Look closer with look_at_canvas and put the points well inside it.")
            case "subject": throw ToolError.failed("No subject was found\(box == nil ? "" : " in the box").")
            default: throw ToolError.failed("The shape is outside the canvas.")
            }
        }
        let current = session.selection.flatMap { $0.isEmpty ? nil : $0.path }
        let result: CGPath
        switch (modeName, current) {
        case ("add", let current?): result = current.union(shape, using: .winding)
        case ("subtract", let current?): result = current.subtracting(shape, using: .winding)
        case ("subtract", nil): throw ToolError.failed("There's no selection to subtract from.")
        case ("intersect", let current?): result = current.intersection(shape, using: .winding)
        case ("intersect", nil): throw ToolError.failed("There's no selection to intersect with.")
        default: result = shape
        }
        // Unchanged, setSelection makes no undo step; the report still says what's selected.
        session.setSelection(DocumentSelection(path: result, antialiased: true, feather: CGFloat(feather)), name: "Select \(method.capitalized)")
        return (selectionReport(), "Selected \(method == "object" ? (points?.count ?? 1 > 1 ? "objects" : "the object") : method == "subject" ? "the subject" : "a \(method)")")
    }

    /// Runs Vision off the main actor, the editor held busy meanwhile as Select › Subject holds it.
    private func traced(_ what: String, _ work: @escaping @Sendable () throws -> CGPath) async throws -> CGPath {
        nonisolated struct Traced: @unchecked Sendable { let path: CGPath }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        let found = await Task.detached(priority: .userInitiated) { () -> Result<Traced, Error> in
            Result { Traced(path: try work()) }
        }.value
        return try found.get().path
    }

    private func selectionReport() -> JSONValue {
        guard let document = session.document, let selection = session.selection, !selection.isEmpty else {
            return .object(["selection": .null])
        }
        let fraction = Self.coverage(selection.path, canvas: document.size)
        return .object(["selection": Self.selectionBounds(selection),
                        "fraction_of_canvas": .number((fraction * 1000).rounded() / 1000),
                        "feather": .number(Double(selection.feather))])
    }

    /// About how much of the canvas `path` covers, 0…1, from a small rasterization.
    static func coverage(_ path: CGPath, canvas: CGSize) -> Double {
        let scale = min(1, 256 / max(canvas.width, canvas.height, 1))
        let width = max(1, Int(canvas.width * scale)), height = max(1, Int(canvas.height * scale))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: true) else { return 0 }
        context.scaleBy(x: scale, y: scale)
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath(using: .winding)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var total = 0
        for y in 0..<height { for x in 0..<width { total += Int(data[y * context.bytesPerRow + x]) } }
        return Double(total) / 255 / Double(width * height)
    }

    private func recolor(_ arguments: ToolArguments) throws -> (JSONValue, String) {
        let colorText = try arguments.string("color")
        let target = try colorText.map { text -> RecolorTarget in
            guard let target = RecolorTarget(text) else {
                throw ToolError.invalidArgument("color", expected: "a hex color like #D62828 or a color name")
            }
            return target
        }
        let shift = try (arguments.double("hue_shift"), arguments.double("saturation"), arguments.double("lightness"))
        guard target != nil || shift.0 != nil || shift.1 != nil || shift.2 != nil else {
            throw ToolError.failed("Give color, or hue_shift, saturation or lightness.")
        }
        let layerID = try arguments.string("layer_id").map { text -> UUID in
            guard let id = UUID(uuidString: text) else { throw ToolError.invalidArgument("layer_id", expected: "a layer id from get_document_info") }
            return id
        }
        try requireEditable()
        guard let document = session.document else { throw ToolError.noDocument }

        func settings(weight: (CGContext) -> Void, hiding: UUID?) -> HueSaturationSettings {
            if let target { return RecolorPlan.settings(to: target, averageLightness: session.averageLightness(weight: weight, hiding: hiding)) }
            return RecolorPlan.settings(hueShift: shift.0 ?? 0, saturation: shift.1 ?? 0, lightness: shift.2 ?? 0)
        }
        let result: RecolorResult
        if let layerID {
            guard let layer = document.layers.first(where: { $0.id == layerID }) else { throw ToolError.failed("There's no layer with that id.") }
            let mask = layer.mask?.asset.image
            let canvas = CGRect(origin: .zero, size: document.size)
            result = try session.updateRecolor(layerID, settings: settings(weight: { context in
                if let mask { BrushRaster.draw(mask, in: canvas, mask: true, context: context) }
                else { context.setFillColor(gray: 1, alpha: 1); context.fill(canvas) }
            }, hiding: layerID))
        } else {
            let selection = session.selection.flatMap { $0.isEmpty ? nil : $0 }
            let wholeImage = try arguments.bool("whole_image") ?? false
            guard selection != nil || wholeImage else { throw RecolorError.nothingSelected }
            let named = try arguments.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = named.flatMap { $0.isEmpty ? nil : $0 } ?? (target.map { "Recolor \($0.name.hasPrefix("#") ? $0.name : $0.name.capitalized)" } ?? "Hue/Saturation")
            let canvas = CGRect(origin: .zero, size: document.size)
            result = try session.recolor(settings(weight: { context in
                context.setFillColor(gray: 1, alpha: 1)
                if let selection { context.addPath(selection.path); context.fillPath(using: .winding) } else { context.fill(canvas) }
            }, hiding: nil), in: selection, name: name)
        }
        let values = result.settings
        return (.object([
            "layer_id": .string(result.layerID.uuidString), "layer_name": .string(result.layerName),
            "colorize": .bool(values.colorize), "hue": .number(values.hue), "saturation": .number(values.saturation),
            "lightness": .number(values.lightness),
        ]), layerID == nil ? "Recolored with “\(result.layerName)”" : "Changed “\(result.layerName)”")
    }

    private func setLayer(_ arguments: ToolArguments) throws -> (JSONValue, String) {
        guard let document = session.document else { throw ToolError.noDocument }
        let index: Int
        if let text = try arguments.string("layer_id") {
            guard let id = UUID(uuidString: text), let found = document.layers.firstIndex(where: { $0.id == id }) else {
                throw ToolError.failed("There's no layer with that id.")
            }
            index = found
        } else if let name = try arguments.string("layer_name") {
            guard let found = document.layers.lastIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ToolError.failed("There's no layer named “\(name)”.")
            }
            index = found
        } else {
            throw ToolError.failed("Give layer_id or layer_name.")
        }
        let opacity = try arguments.double("opacity")
        if let opacity, !(0...100).contains(opacity) { throw ToolError.invalidArgument("opacity", expected: "between 0 and 100") }
        let blend = try arguments.string("blend_mode").map { text -> LayerBlendMode in
            let wanted = text.replacingOccurrences(of: "_", with: " ").lowercased()
            guard let mode = LayerBlendMode.allCases.first(where: { $0.rawValue.lowercased() == wanted || $0.rawValue.lowercased().hasPrefix(wanted + " (") }) else {
                throw ToolError.invalidArgument("blend_mode", expected: "one of " + LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return mode
        }
        let visible = try arguments.bool("visible")
        let rename = try arguments.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireEditable()
        let layer = document.layers[index]
        if try arguments.bool("delete") == true {
            session.deleteLayer(layer.id)
            guard session.document?.layers.contains(where: { $0.id == layer.id }) == false else {
                throw ToolError.failed("“\(layer.name)” wasn't deleted: the app asked the user about it, or it can't be deleted now.")
            }
            return (.object(["deleted": .string(layer.name)]), "Deleted “\(layer.name)”")
        }
        guard opacity != nil || blend != nil || visible != nil || !(rename ?? "").isEmpty else {
            throw ToolError.failed("Give opacity, visible, name, blend_mode or delete.")
        }
        session.beginEdit("Layer Properties")
        if let opacity { session.document?.layers[index].opacity = opacity / 100 }
        if let blend { session.document?.layers[index].blendMode = blend }
        if let visible { session.document?.layers[index].isVisible = visible }
        if let rename, !rename.isEmpty { session.document?.layers[index].name = rename }
        session.endEdit()
        session.brushRevision += 1
        let changed = session.document!.layers[index]
        return (.object(["layer_id": .string(changed.id.uuidString), "name": .string(changed.name),
                         "opacity": .number((changed.opacity * 100).rounded()), "visible": .bool(changed.isVisible),
                         "blend_mode": .string(changed.blendMode.rawValue)]), "Changed “\(changed.name)”")
    }

    private func exportImage(_ arguments: ToolArguments) async throws -> (JSONValue, String) {
        let format = try arguments.string("format")?.lowercased() ?? "png"
        guard ["png", "jpeg", "jpg"].contains(format) else { throw ToolError.invalidArgument("format", expected: "png or jpeg") }
        let quality = try arguments.double("quality") ?? 90
        guard (1...100).contains(quality) else { throw ToolError.invalidArgument("quality", expected: "between 1 and 100") }
        try requireEditable()
        guard let url = try await controller.exportImageFile(jpegQuality: format == "png" ? nil : quality / 100,
                                                            named: sourceName(), in: exportFolder()) else { throw ToolError.busy }
        // The sandbox's Downloads is a link to the user's own; the real place is what they'd look for.
        let shown = url.resolvingSymlinksInPath()
        return (.object(["saved_to": .string(shown.path)]), "Exported “\(shown.lastPathComponent)” to Downloads")
    }

    private func save() async throws -> (JSONValue, String) {
        try requireEditable()
        let saved = await controller.save()
        guard saved, let url = session.projectURL else {
            return (.object(["saved": .bool(false), "message": .string("Not saved: the user cancelled, or saving failed (the app showed why).")]), "Not saved")
        }
        return (.object(["saved": .bool(true), "path": .string(url.path)]), "Saved “\(url.lastPathComponent)”")
    }

    static func json(_ rect: CGRect) -> JSONValue {
        .object(["x": .int(Int(rect.minX)), "y": .int(Int(rect.minY)), "width": .int(Int(rect.width)), "height": .int(Int(rect.height))])
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
