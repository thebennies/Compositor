import Foundation
import CoreGraphics

/// What `highlight(_:color:layerName:)` did, for the assistant to report back.
nonisolated struct HighlightResult: Equatable, Sendable {
    let layerID: UUID
    let layerName: String
    let created: Bool
    let marks: Int
}

nonisolated enum HighlightError: LocalizedError, Equatable {
    case busy
    case nothingToMark
    case notPixelLayer(String)
    case masked(String)
    case deep(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .busy: "The editor is busy (a dialog, transform, crop or gesture is in progress)."
        case .nothingToMark: "None of the lines lie on the canvas."
        case .notPixelLayer(let name): "“\(name)” isn’t a pixel layer (it’s a folder, adjustment, text, shape or GIF). Use another layer_name."
        case .masked(let name): "“\(name)” has a mask and has been moved, so it can’t be redrawn at the canvas size. Use another layer_name."
        case .deep(let name): "“\(name)” is a 16-bit layer. Use another layer_name."
        case .tooLarge: "Another canvas-sized layer would go past this project’s \(DocumentLimits.documentBudgetMegapixels)-megapixel limit."
        }
    }
}

extension EditorSession {
    /// Highlighter marks over `boxes` (document pixels, top-left origin) on the pixel layer named `layerName`, as one
    /// "Highlight Lines" undo step. Without such a layer one is made at the top of the stack, multiplied over what's
    /// below so the text stays crisp; with one, the marks are drawn over its pixels, at the canvas size.
    func highlight(_ boxes: [CGRect], color: HighlightColor, layerName: String) throws -> HighlightResult {
        guard canEditLayers, let document else { throw HighlightError.busy }
        let canvas = CGRect(origin: .zero, size: document.size)
        let marks = boxes.map { TextLines.highlightRect(for: $0).intersection(canvas) }.filter { !$0.isNull && !$0.isEmpty }
        guard !marks.isEmpty else { throw HighlightError.nothingToMark }

        let index = document.layers.lastIndex { $0.name == layerName }
        let existing = index.map { document.layers[$0] }
        if let existing {
            guard !existing.isGroup, existing.adjustment == nil, existing.text == nil, existing.shape == nil,
                  existing.gifAnimation == nil else { throw HighlightError.notPixelLayer(layerName) }
            guard existing.asset?.deep == nil else { throw HighlightError.deep(layerName) }
        }
        func fillsCanvas(_ transform: LayerTransform) -> Bool {
            transform.origin == .zero && transform.size == document.size && transform.rotation == 0 && !transform.flipX && !transform.flipY
        }
        // A mask sits on the layer's own rectangle, so it would slide if the layer were redrawn over the canvas.
        if let existing, existing.mask != nil, !fillsCanvas(existing.transform) { throw HighlightError.masked(layerName) }
        let used = document.layers.reduce(0) { total, layer in
            layer.id == existing?.id ? total : total + (layer.asset.map { $0.image.width * $0.image.height } ?? 0)
        }
        guard used + document.width * document.height <= DocumentLimits.documentPixelBudget else { throw HighlightError.tooLarge }

        let context = try BrushRaster.context(width: document.width, height: document.height, mask: false)
        if let existing, let image = displayedAsset(for: existing)?.image {
            if fillsCanvas(existing.transform), image.width == document.width, image.height == document.height {
                BrushRaster.draw(image, in: canvas, mask: false, context: context)
            } else {
                // Moved or scaled: drawn where it shows. Pixels past the canvas edge are let go.
                LayerRenderer.draw(image, transform: existing.transform, center: existing.transform.center, in: context)
            }
        }
        context.setFillColor(color.cgColor)
        for mark in marks {
            let radius = TextLines.cornerRadius(for: mark)
            context.addPath(CGPath(roundedRect: mark, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath(using: .winding)
        guard let image = context.makeImage() else { throw ExportError.render }
        let asset = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: layerName)

        beginEdit("Highlight Lines")
        defer {
            endEdit()
            brushRevision += 1
        }
        if let index, let existing {
            // VERIFY(macOS): replacing `asset` directly (as `firstLayer` does for a new canvas) redraws the layer on the
            // GPU canvas without anything else to invalidate.
            self.document?.layers[index].asset = asset
            self.document?.layers[index].transform = LayerTransform(origin: .zero, size: document.size)
            return HighlightResult(layerID: existing.id, layerName: layerName, created: false, marks: marks.count)
        }
        var layer = ImageLayer(name: layerName, blankSize: document.size)
        layer.asset = asset
        layer.blendMode = .multiply
        self.document?.layers.append(layer)
        return HighlightResult(layerID: layer.id, layerName: layerName, created: true, marks: marks.count)
    }
}
