import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct AssistantTests {
    // MARK: Recognized text

    @Test func visionBoxesBecomeTopLeftDocumentPixels() {
        // Normalized with a bottom-left origin: the box's top edge is at 0.625 up the image.
        let box = TextLines.documentRect(fromNormalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.125), width: 800, height: 400)
        #expect(box == CGRect(x: 200, y: 150, width: 400, height: 50))
        let corner = TextLines.documentRect(fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 0.5), width: 640, height: 480)
        #expect(corner == CGRect(x: 0, y: 240, width: 640, height: 240), "the bottom half stays at the bottom")
    }

    @Test func selectionKeepsLinesWhoseCentersAreInside() {
        let lines = [
            TextLine(id: 1, text: "Payment due in 30 days", box: CGRect(x: 100, y: 100, width: 400, height: 20)),
            TextLine(id: 2, text: "Half in, center out", box: CGRect(x: 100, y: 190, width: 400, height: 40)),
            TextLine(id: 3, text: "Outside", box: CGRect(x: 100, y: 400, width: 400, height: 20)),
        ]
        let marquee = CGPath(rect: CGRect(x: 50, y: 80, width: 600, height: 120), transform: nil)
        #expect(TextLines.lines(lines, inside: marquee).map(\.id) == [1])
        // A lasso: a triangle whose slanted side runs between line 2's center (300, 210) and line 3's (300, 410).
        let lasso = CGMutablePath()
        lasso.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0), CGPoint(x: 0, y: 600)])
        lasso.closeSubpath()
        #expect(TextLines.lines(lines, inside: lasso).map(\.id) == [1, 2])
        #expect(TextLines.lines(lines, inside: CGPath(rect: CGRect(x: 0, y: 600, width: 10, height: 10), transform: nil)).isEmpty)
    }

    @Test func highlightMarksArePaddedAroundTheLine() {
        let mark = TextLines.highlightRect(for: CGRect(x: 100, y: 200, width: 300, height: 40))
        #expect(mark == CGRect(x: 96, y: 194, width: 308, height: 52), "15% of the height above and below, 4 px either side")
        #expect(TextLines.cornerRadius(for: mark) == 6)
        #expect(TextLines.cornerRadius(for: CGRect(x: 0, y: 0, width: 3, height: 20)) == 1.5, "never past half the width")
        #expect(TextLines.cornerRadius(for: CGRect(x: 0, y: 0, width: 100, height: 8)) == 2)
    }

    @Test func linesAreNumberedInReadingOrder() {
        let lines = TextLines.readingOrder([
            ("second row", CGRect(x: 10, y: 60, width: 100, height: 20)),
            ("right", CGRect(x: 300, y: 12, width: 100, height: 20)),
            ("left", CGRect(x: 10, y: 10, width: 100, height: 20)),
        ])
        #expect(lines.map(\.text) == ["left", "right", "second row"])
        #expect(lines.map(\.id) == [1, 2, 3])
    }

    @Test func highlightColorsByNameOrHex() throws {
        let pink = try #require(HighlightColor("Pink"))
        #expect(pink.name == "Pink")
        #expect(pink.red == 1 && pink.green == CGFloat(0x7A) / 255 && pink.blue == CGFloat(0xC6) / 255)
        let yellow = try #require(HighlightColor(" yellow "))
        #expect(yellow.green == CGFloat(0xE2) / 255)
        #expect(HighlightColor("#ffe24d")?.name == "#FFE24D")
        #expect(HighlightColor("0f0")?.green == 1)
        #expect(HighlightColor("chartreuse-ish") == nil)
        #expect(HighlightColor("#12345") == nil)
    }

    // MARK: Resizing

    @Test func resizeFromWidthOnlyKeepsTheAspectRatio() throws {
        let size = try ResizePlan.size(from: PixelSize(width: 3000, height: 2000), width: 1920, height: nil, longEdge: nil)
        #expect(size == PixelSize(width: 1920, height: 1280))
        let stretched = try ResizePlan.size(from: PixelSize(width: 3000, height: 2000), width: 1920, height: nil, longEdge: nil,
                                            keepAspect: false)
        #expect(stretched == PixelSize(width: 1920, height: 2000))
    }

    @Test func resizeFromHeightOnlyKeepsTheAspectRatio() throws {
        let size = try ResizePlan.size(from: PixelSize(width: 4000, height: 3000), width: nil, height: 1080, longEdge: nil)
        #expect(size == PixelSize(width: 1440, height: 1080))
        let both = try ResizePlan.size(from: PixelSize(width: 4000, height: 3000), width: 500, height: 500, longEdge: nil)
        #expect(both == PixelSize(width: 500, height: 500), "both sides are used as given")
    }

    @Test func resizeByLongEdgeScalesTheLongerSide() throws {
        #expect(try ResizePlan.size(from: PixelSize(width: 3000, height: 2000), width: nil, height: nil, longEdge: 1920)
                == PixelSize(width: 1920, height: 1280))
        #expect(try ResizePlan.size(from: PixelSize(width: 2000, height: 3000), width: nil, height: nil, longEdge: 1920)
                == PixelSize(width: 1280, height: 1920))
        #expect(try ResizePlan.size(from: PixelSize(width: 1000, height: 1000), width: 50, height: nil, longEdge: 400)
                == PixelSize(width: 400, height: 400), "the long edge wins over a side")
    }

    @Test func resizeRejectsMissingZeroAndOversizedSides() {
        let current = PixelSize(width: 1000, height: 800)
        #expect(throws: ToolError.self) { try ResizePlan.size(from: current, width: nil, height: nil, longEdge: nil) }
        #expect(throws: ToolError.invalidArgument("width", expected: "at least 1")) {
            try ResizePlan.size(from: current, width: 0, height: nil, longEdge: nil)
        }
        #expect(throws: ToolError.self) { try ResizePlan.size(from: current, width: nil, height: nil, longEdge: 40_000) }
        #expect(throws: ToolError.self) { try ResizePlan.size(from: current, width: 20_000, height: 20_000, longEdge: nil) }
    }

    // MARK: Tool arguments

    @Test func toolArgumentsAreReadLeniently() throws {
        let arguments = try ToolArguments(json: #"{"width": 1920, "height": "1080", "keep_aspect": "false", "resolution": 300.5, "line_ids": [1, "2", 3.0]}"#)
        #expect(try arguments.int("width") == 1920)
        #expect(try arguments.int("height") == 1080)
        #expect(try arguments.bool("keep_aspect") == false)
        #expect(try arguments.double("resolution") == 300.5)
        #expect(try arguments.ints("line_ids") == [1, 2, 3])
        #expect(try arguments.int("long_edge") == nil)
        #expect(try ToolArguments(json: #"{"line_ids": 7}"#).ints("line_ids") == [7])
        #expect(try ToolArguments(json: "").values.isEmpty, "a tool without parameters may get no arguments at all")
        #expect(try ToolArguments(json: "null").values.isEmpty)
    }

    @Test func malformedToolArgumentsThrowWhatTheModelCanFix() {
        #expect(throws: ToolError.malformedArguments) { try ToolArguments(json: #"{"width": 1920"#) }
        #expect(throws: ToolError.malformedArguments) { try ToolArguments(json: "[1, 2]") }
        #expect(throws: ToolError.malformedArguments) { try ToolArguments(json: "width=1920") }
        #expect(throws: ToolError.invalidArgument("width", expected: "a whole number")) {
            try ToolArguments(json: #"{"width": "wide"}"#).int("width")
        }
        #expect(throws: ToolError.invalidArgument("within_selection", expected: "true or false")) {
            try ToolArguments(json: #"{"within_selection": 1}"#).bool("within_selection")
        }
        #expect(throws: ToolError.self) { try ToolArguments(json: #"{"line_ids": [1, "x"]}"#).ints("line_ids") }
    }

    @Test func badArgumentsComeBackToTheModelAsAnError() async throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100, emptyLayer: true)
        let runner = AssistantToolRunner(session: session, controller: ProjectController(session: session))
        let outcome = await runner.run(ToolCall(id: "call_1", name: "resize_image", arguments: "{width: 10"))
        #expect(outcome.failed)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(outcome.content.utf8))
        guard case .object(let object) = result, case .string(let message)? = object["error"] else {
            Issue.record("Expected an error object, got \(outcome.content)"); return
        }
        #expect(message.contains("JSON"))
        #expect(session.document?.width == 200, "nothing changed")
        let unknown = await runner.run(ToolCall(id: "call_2", name: "make_coffee", arguments: "{}"))
        #expect(unknown.failed && unknown.content.contains("make_coffee"))
        let early = await runner.run(ToolCall(id: "call_3", name: "highlight_lines", arguments: #"{"line_ids": [1], "color": "pink"}"#))
        #expect(early.failed && early.content.contains("recognize_text"), "lines are looked up only after recognize_text")
    }

    @Test func documentInfoDescribesTheCanvasAndSelection() async throws {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480, emptyLayer: true, resolution: 300)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 10, y: 20, width: 100, height: 50), transform: nil)),
                             name: "Rectangular Marquee")
        let runner = AssistantToolRunner(session: session, controller: ProjectController(session: session))
        runner.sourceName = { "Invoice" }
        let outcome = await runner.run(ToolCall(id: "call_1", name: "get_document_info", arguments: ""))
        #expect(!outcome.failed)
        let info = try JSONDecoder().decode(JSONValue.self, from: Data(outcome.content.utf8))
        guard case .object(let object) = info else { Issue.record("Not an object"); return }
        #expect(object["width"] == JSONValue.int(640) && object["height"] == JSONValue.int(480) && object["resolution"] == JSONValue.number(300))
        #expect(object["sourceName"] == JSONValue.string("Invoice"))
        #expect(object["selection"] == JSONValue.object(["x": .int(10), "y": .int(20), "width": .int(100), "height": .int(50)]))
        guard case .array(let layers)? = object["layers"] else { Issue.record("No layers"); return }
        #expect(layers.count == 1)
    }

    // MARK: Highlighting

    @Test func highlightsGoOnOneMultipliedLayerPerColorAsOneUndoStep() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300, emptyLayer: true, background: CGColor(gray: 1, alpha: 1))
        let before = try #require(session.document?.layers.count)
        let pink = try #require(HighlightColor("pink"))
        let first = try session.highlight([CGRect(x: 20, y: 20, width: 200, height: 20)], color: pink, layerName: "Highlight Pink")
        #expect(first.created && first.marks == 1)
        let layer = try #require(session.document?.layers.last)
        #expect(layer.name == "Highlight Pink" && layer.blendMode == .multiply)
        #expect(layer.asset?.image.width == 400 && layer.asset?.image.height == 300)
        #expect(session.history.undoName == "Highlight Lines")

        let second = try session.highlight([CGRect(x: 20, y: 80, width: 200, height: 20)], color: pink, layerName: "Highlight Pink")
        #expect(!second.created && second.layerID == first.layerID, "the color's layer is reused")
        #expect(session.document?.layers.count == before + 1)

        session.undo()
        session.undo()
        #expect(session.document?.layers.count == before)
    }

    @Test func highlightsRefuseLayersThatArentPixels() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        session.groupSelectedLayers()
        let folder = try #require(session.document?.layers.first { $0.isGroup })
        #expect(throws: HighlightError.notPixelLayer(folder.name)) {
            try session.highlight([CGRect(x: 0, y: 0, width: 50, height: 10)], color: HighlightColor("yellow")!, layerName: folder.name)
        }
        #expect(throws: HighlightError.nothingToMark) {
            try session.highlight([CGRect(x: 500, y: 500, width: 50, height: 10)], color: HighlightColor("yellow")!, layerName: "Highlight Yellow")
        }
    }

    // MARK: OpenRouter

    @Test func requestsEncodeAsOpenRouterExpects() throws {
        let request = ChatRequest(model: "deepseek/deepseek-chat", messages: [
            .system("Be brief."), .user("Resize to 1920"),
            ChatMessage(role: "assistant", content: nil, toolCalls: [ToolCall(id: "call_1", name: "resize_image", arguments: #"{"long_edge":1920}"#)]),
            .tool("call_1", content: #"{"width":1920}"#),
        ], tools: AssistantTool.definitions)
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "deepseek/deepseek-chat")
        #expect(json["tool_choice"] as? String == "auto")
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == AssistantTool.allCases.count)
        #expect(tools.allSatisfy { $0["type"] as? String == "function" })
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_document_info")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages[2]["content"] is NSNull, "content is written as null beside tool calls")
        let call = try #require((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_1" && call["type"] as? String == "function")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"long_edge":1920}"#)
        #expect(messages[3]["tool_call_id"] as? String == "call_1")

        let urlRequest = try OpenRouterClient().urlRequest(for: request, apiKey: "sk-test")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.url == OpenRouterClient.endpoint)
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Title") == "Compositor")
    }

    @Test func responsesWithToolCallsDecode() throws {
        let body = #"""
        {"id": "gen-1", "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
          "role": "assistant", "content": "",
          "tool_calls": [
            {"id": "call_a", "type": "function", "function": {"name": "recognize_text", "arguments": "{\"within_selection\": true}"}},
            {"id": "call_b", "type": "function", "function": {"name": "get_document_info", "arguments": {}}}
          ]}}]}
        """#
        let message = try OpenRouterClient.message(from: Data(body.utf8))
        #expect(message.role == "assistant")
        let calls = try #require(message.toolCalls)
        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls[0].function.name == "recognize_text")
        #expect(try ToolArguments(json: calls[0].function.arguments).bool("within_selection") == true)
        #expect(calls[1].function.arguments == "{}", "an arguments object, not a string, is kept as its text")
    }

    @Test func errorBodiesAndEmptyAnswersThrow() {
        #expect(throws: OpenRouterError.api("No auth credentials found")) {
            try OpenRouterClient.message(from: Data(#"{"error": {"message": "No auth credentials found", "code": 401}}"#.utf8))
        }
        #expect(throws: OpenRouterError.empty) { try OpenRouterClient.message(from: Data(#"{"choices": []}"#.utf8)) }
        #expect(throws: OpenRouterError.malformed) { try OpenRouterClient.message(from: Data("<html>".utf8)) }
        #expect(OpenRouterError.http(status: 401, message: nil).localizedDescription.contains("Settings"))
    }

    @Test func exportNamesFallBackToUntitled() {
        var components = DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 5, second: 2)
        components.calendar = Calendar(identifier: .gregorian)
        let date = components.date!
        #expect(ProjectController.exportName("Invoice", extension: "png", at: date) == "Invoice-20260307-090502.png")
        #expect(ProjectController.exportName(nil, extension: "png", at: date) == "Untitled-20260307-090502.png")
        #expect(ProjectController.exportName("  ", extension: "jpg", at: date) == "Untitled-20260307-090502.jpg")
        #expect(ProjectController.exportName("Q3/Q4", extension: "png", at: date) == "Q3-Q4-20260307-090502.png")
    }

    @Test func contextNoteMentionsTheSelection() {
        let session = EditorSession()
        let assistant = AssistantSession(session: session, controller: ProjectController(session: session))
        #expect(assistant.contextNote().contains("no document"))
        session.createDocument(width: 1200, height: 900, emptyLayer: true)
        #expect(assistant.contextNote().contains("1200 × 900 px") && assistant.contextNote().contains("no selection"))
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 5, y: 6, width: 70, height: 80), transform: nil)), name: "Marquee")
        #expect(assistant.contextNote().contains("x 5, y 6, 70 × 80 px"))
    }
}
