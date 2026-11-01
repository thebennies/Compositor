import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct AssistantEditingTests {
    private func runner(width: Int = 400, height: Int = 300, background: CGColor? = CGColor(gray: 1, alpha: 1))
        -> (EditorSession, AssistantToolRunner) {
        let session = EditorSession()
        session.createDocument(width: width, height: height, emptyLayer: true, background: background)
        return (session, AssistantToolRunner(session: session, controller: ProjectController(session: session)))
    }

    private func object(_ outcome: ToolOutcome) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(outcome.content.utf8))
        guard case .object(let object) = value else { Issue.record("Not an object: \(outcome.content)"); return [:] }
        return object
    }

    /// Path arithmetic leaves a little float error on the edges.
    private func near(_ rect: CGRect?, _ expected: CGRect) -> Bool {
        guard let rect else { return false }
        return [rect.minX - expected.minX, rect.minY - expected.minY, rect.width - expected.width, rect.height - expected.height]
            .allSatisfy { abs($0) < 0.01 }
    }

    // MARK: Arguments

    @Test func boxesAndPointsAreReadInEitherShape() throws {
        let arguments = try ToolArguments(json: #"{"a": {"x": 1, "y": 2, "width": 30, "height": "40"}, "b": [5, 6, 7, 8], "c": [10, 20], "d": [[1, 2], {"x": 3, "y": 4}]}"#)
        #expect(try arguments.rect("a") == CGRect(x: 1, y: 2, width: 30, height: 40))
        #expect(try arguments.rect("b") == CGRect(x: 5, y: 6, width: 7, height: 8))
        #expect(try arguments.points("c") == [CGPoint(x: 10, y: 20)])
        #expect(try arguments.points("d") == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
        #expect(throws: ToolError.self) { try ToolArguments(json: #"{"r": {"x": 1, "y": 2, "width": 0, "height": 4}}"#).rect("r") }
        #expect(throws: ToolError.self) { try ToolArguments(json: #"{"p": [[1, 2], [3]]}"#).points("p") }
    }

    // MARK: Pictures

    @Test func picturesGoOutAsContentParts() throws {
        let message = ChatMessage.user("Look", images: ["data:image/jpeg;base64,AAAA"])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        let parts = try #require(json["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "text" && parts[0]["text"] as? String == "Look")
        #expect(parts[1]["type"] as? String == "image_url")
        #expect((parts[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,AAAA")
        // Plain text stays a string; an answer in parts is read as its text.
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatMessage.user("Hi"))) as? [String: Any])
        #expect(plain["content"] as? String == "Hi")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role": "assistant", "content": [{"type": "text", "text": "Done"}]}"#.utf8))
        #expect(decoded.content == "Done")
    }

    @Test func onlyTheLatestPictureStaysAttached() {
        var messages: [ChatMessage] = [.system("S"), .user("Q")]
        AssistantSession.attach(["first"], to: &messages)
        AssistantSession.attach(["second", "third"], to: &messages)
        #expect(messages.count == 4)
        #expect(messages[2].images.isEmpty && messages[2].content?.contains("no longer attached") == true)
        #expect(messages[3].images == ["second", "third"])
    }

    @Test func lookingSendsAPictureWithRulersAndReportsTheRegion() async throws {
        let (session, runner) = runner(width: 2000, height: 1000)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 100, y: 100, width: 200, height: 200), transform: nil)), name: "Marquee")
        let whole = try object(await runner.run(ToolCall(id: "1", name: "look_at_canvas", arguments: "")))
        #expect(whole["shown_region"] == JSONValue.object(["x": .int(0), "y": .int(0), "width": .int(2000), "height": .int(1000)]))
        #expect(whole["selection_shown"] == JSONValue.bool(true))
        let pictures = runner.takePictures()
        #expect(pictures.count == 1 && pictures[0].hasPrefix("data:image/jpeg;base64,"))
        #expect(runner.takePictures().isEmpty, "taken once")
        let base64 = String(pictures[0].dropFirst("data:image/jpeg;base64,".count))
        let data = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1024 + CanvasLook.rulerWidth && image.height == 512 + CanvasLook.rulerWidth)

        let close = try object(await runner.run(ToolCall(id: "2", name: "look_at_canvas", arguments: #"{"region": {"x": 1900, "y": 900, "width": 400, "height": 400}}"#)))
        #expect(close["shown_region"] == JSONValue.object(["x": .int(1900), "y": .int(900), "width": .int(100), "height": .int(100)]), "clamped to the canvas")
        #expect(close["document_pixels_per_picture_pixel"] == JSONValue.number(0.25), "a small region is enlarged at most 4×")
        #expect(CanvasLook.rulerStep(zoom: 0.5) == 200 && CanvasLook.rulerStep(zoom: 4) == 25)
    }

    // MARK: Selecting

    @Test func shapesSelectAndCombine() async throws {
        let (session, runner) = runner()
        _ = await runner.run(ToolCall(id: "1", name: "select", arguments: #"{"method": "rectangle", "box": {"x": 0, "y": 0, "width": 200, "height": 300}}"#))
        #expect(near(session.selection?.path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 200, height: 300)))
        #expect(session.history.undoName == "Select Rectangle")
        let cut = try object(await runner.run(ToolCall(id: "2", name: "select", arguments: #"{"method": "rectangle", "box": [100, 0, 300, 300], "mode": "intersect", "feather": 2}"#)))
        #expect(near(session.selection?.path.boundingBoxOfPath, CGRect(x: 100, y: 0, width: 100, height: 300)))
        #expect(session.selection?.feather == 2)
        if case .number(let fraction)? = cut["fraction_of_canvas"] { #expect(abs(fraction - 0.25) < 0.02) } else { Issue.record("No fraction") }
        _ = await runner.run(ToolCall(id: "3", name: "select", arguments: #"{"method": "ellipse", "box": [0, 0, 400, 300], "mode": "add"}"#))
        #expect(near(session.selection?.path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = await runner.run(ToolCall(id: "4", name: "select", arguments: #"{"method": "none"}"#))
        #expect(session.selection == nil)
        let subtract = await runner.run(ToolCall(id: "5", name: "select", arguments: #"{"method": "rectangle", "box": [0, 0, 10, 10], "mode": "subtract"}"#))
        #expect(subtract.failed && subtract.content.contains("no selection"))
        let off = await runner.run(ToolCall(id: "6", name: "select", arguments: #"{"method": "object", "points": [[900, 10]]}"#))
        #expect(off.failed && off.content.contains("on the canvas"))
    }

    // MARK: Recoloring

    @Test func recolorTargetsReadNamesAndHex() throws {
        let red = try #require(RecolorTarget("red"))
        #expect(red.name == "red")
        let hsl = red.hsl
        #expect(abs(hsl.hue - 0) < 1 && hsl.saturation > 0.6 && abs(hsl.lightness - 0.498) < 0.01)
        #expect(RecolorTarget("#00f")?.name == "#0000FF")
        #expect(abs((RecolorTarget("#00FF00")?.hsl.hue ?? 0) - 120) < 0.5)
        #expect(RecolorTarget("ultraviolet") == nil)
    }

    @Test func colorizingMatchesTheTargetsLightness() throws {
        let red = try #require(RecolorTarget("#FF0000"))
        // White shoes made red are pulled down to red's lightness, dark ones lifted to it, mid-tones left.
        let white = RecolorPlan.settings(to: red, averageLightness: 0.95)
        #expect(white.colorize && white.hue == 0 && white.saturation == 100)
        #expect(white.lightness == -47)
        #expect(RecolorPlan.settings(to: red, averageLightness: 0.1).lightness == 44)
        #expect(RecolorPlan.settings(to: red, averageLightness: 0.5).lightness == 0)
        let shift = RecolorPlan.settings(hueShift: 400, saturation: -20, lightness: 0)
        #expect(!shift.colorize && shift.hue == 180 && shift.saturation == -20)
    }

    @Test func recolorMakesOneMaskedLayerAndCanBeChangedLater() async throws {
        let (session, runner) = runner(width: 200, height: 100)
        let refused = await runner.run(ToolCall(id: "1", name: "recolor", arguments: #"{"color": "red"}"#))
        #expect(refused.failed && refused.content.contains("Nothing is selected"))
        let before = try #require(session.document?.layers.count)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)), name: "Marquee")
        let made = try object(await runner.run(ToolCall(id: "2", name: "recolor", arguments: #"{"color": "red"}"#)))
        let layer = try #require(session.document?.layers.last)
        #expect(session.document?.layers.count == before + 1)
        #expect(layer.name == "Recolor Red" && layer.adjustment?.kind == .hsv && layer.mask != nil)
        #expect(layer.adjustment?.hsvSettings?.colorize == true)
        guard case .number(let lightness)? = made["lightness"] else { Issue.record("No lightness"); return }
        #expect((-55 ... -45).contains(lightness), "the white background is pulled down to red's lightness, about half")
        #expect(session.selection == nil, "the selection is used up, as Add Mask uses it")
        #expect(session.history.undoName == "Recolor")
        let mask = try #require(layer.mask?.asset.image)
        #expect(mask.width == 200 && mask.height == 100)

        let changed = try object(await runner.run(ToolCall(id: "3", name: "recolor", arguments: #"{"layer_id": "\#(layer.id.uuidString)", "hue_shift": 30}"#)))
        #expect(changed["layer_id"] == JSONValue.string(layer.id.uuidString))
        #expect(session.document?.layers.count == before + 1, "changed in place, not stacked")
        #expect(session.document?.layers.last?.adjustment?.hsvSettings?.colorize == false)
        session.undo()
        #expect(session.document?.layers.last?.adjustment?.hsvSettings?.colorize == true)
        session.undo()
        #expect(session.document?.layers.count == before)
        #expect(session.selection != nil, "undo brings the selection back")
    }

    // MARK: Layers

    @Test func layerPropertiesChangeAsOneStep() async throws {
        let (session, runner) = runner()
        let layer = try #require(session.document?.layers.last)
        let result = try object(await runner.run(ToolCall(id: "1", name: "set_layer", arguments:
            #"{"layer_name": "\#(layer.name)", "opacity": 40, "blend_mode": "soft_light", "name": "Shoes", "visible": false}"#)))
        let changed = try #require(session.document?.layers.first { $0.id == layer.id })
        #expect(abs(Double(changed.opacity) - 0.4) < 0.001 && changed.blendMode == .softLight && changed.name == "Shoes" && !changed.isVisible)
        #expect(result["blend_mode"] == JSONValue.string("Soft Light"))
        #expect(session.history.undoName == "Layer Properties")
        session.undo()
        #expect(session.document?.layers.first { $0.id == layer.id }?.name == layer.name)
        let bad = await runner.run(ToolCall(id: "2", name: "set_layer", arguments: #"{"layer_id": "\#(layer.id.uuidString)", "blend_mode": "glitter"}"#))
        #expect(bad.failed && bad.content.contains("Multiply"))
        let linear = await runner.run(ToolCall(id: "3", name: "set_layer", arguments: #"{"layer_id": "\#(layer.id.uuidString)", "blend_mode": "linear dodge"}"#))
        #expect(!linear.failed && session.document?.layers.first { $0.id == layer.id }?.blendMode == .linearDodge)
    }

    // MARK: Exporting and closing

    @Test func exportsGoStraightIntoTheFolderWithoutReplacing() async throws {
        let (_, runner) = runner(width: 40, height: 30)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        runner.exportFolder = { folder }
        runner.sourceName = { "Shoes" }
        let png = try object(await runner.run(ToolCall(id: "1", name: "export_image", arguments: "")))
        let jpeg = try object(await runner.run(ToolCall(id: "2", name: "export_image", arguments: #"{"format": "jpeg", "quality": 80}"#)))
        guard case .string(let pngPath)? = png["saved_to"], case .string(let jpegPath)? = jpeg["saved_to"] else {
            Issue.record("No paths: \(png) \(jpeg)"); return
        }
        #expect(pngPath.hasSuffix(".png") && (pngPath as NSString).lastPathComponent.hasPrefix("Shoes-"))
        #expect(jpegPath.hasSuffix(".jpg"))
        #expect(FileManager.default.fileExists(atPath: pngPath) && FileManager.default.fileExists(atPath: jpegPath))

        let taken = folder.appendingPathComponent("a.png")
        try Data().write(to: taken)
        #expect(ProjectController.freeURL(in: folder, named: "a.png").lastPathComponent == "a 2.png")
        #expect(ProjectController.freeURL(in: folder, named: "b.png").lastPathComponent == "b.png")
    }

    @Test func closingWaitsForTheReply() async throws {
        let (_, runner) = runner()
        #expect(!runner.closeRequested)
        let outcome = await runner.run(ToolCall(id: "1", name: "close_document", arguments: ""))
        #expect(!outcome.failed && runner.closeRequested)
        // No window here, so nothing to close; the request is still let go.
        await runner.closeIfRequested()
        #expect(!runner.closeRequested)
    }
}
