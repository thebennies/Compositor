import Foundation
import CoreGraphics

/// A color the assistant recolors to: a name of a plain color or a hex string. Unlike `HighlightColor`'s highlighter
/// tints, "red" here is a red.
nonisolated struct RecolorTarget: Equatable, Sendable {
    let name: String
    let red: Double
    let green: Double
    let blue: Double

    static let named: [String: String] = [
        "red": "D62828", "orange": "F07A1A", "yellow": "F2C200", "green": "2E9E44", "teal": "138A8A",
        "cyan": "1FB5D6", "blue": "1F5FD6", "navy": "1B2A5A", "purple": "7B3FC4", "pink": "E8559A",
        "magenta": "D13AB0", "brown": "6B4423", "beige": "D9C7A3", "black": "151515", "white": "F5F5F5",
        "gray": "808080", "grey": "808080",
    ]

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = Self.named[value] ?? (value.hasPrefix("#") ? String(value.dropFirst()) : value)
        var digits = hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
        name = Self.named[value] != nil ? value : "#" + digits.uppercased()
        red = Double((number >> 16) & 0xFF) / 255
        green = Double((number >> 8) & 0xFF) / 255
        blue = Double(number & 0xFF) / 255
    }

    /// Hue in degrees, saturation and lightness 0…1, as Hue/Saturation's Colorize reads them.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high > low else { return (0, 0, lightness) }
        let range = high - low
        let saturation = lightness > 0.5 ? range / (2 - high - low) : range / (high + low)
        var hue: Double
        if high == red { hue = (green - blue) / range + (green < blue ? 6 : 0) }
        else if high == green { hue = (blue - red) / range + 2 }
        else { hue = (red - green) / range + 4 }
        return (hue * 60, saturation, lightness)
    }
}

nonisolated enum RecolorPlan {
    /// Colorize to `target`, its Lightness set so pixels of the area's average lightness land on the target's: white
    /// shoes made red come out red, not pink, and keep their shading around it.
    static func settings(to target: RecolorTarget, averageLightness: Double?) -> HueSaturationSettings {
        let (hue, saturation, lightness) = target.hsl
        var amount = 0.0
        if let average = averageLightness.map({ min(0.99, max(0.01, $0)) }) {
            amount = lightness >= average ? (lightness - average) / (1 - average) : lightness / average - 1
        }
        return HueSaturationSettings(hue: hue.rounded(), saturation: (saturation * 100).rounded(),
                                     lightness: (min(1, max(-1, amount)) * 100).rounded(), colorize: true)
    }

    /// Hue/Saturation's own sliders, clamped to their ranges: hue −180…180, the others −100…100.
    static func settings(hueShift: Double, saturation: Double, lightness: Double) -> HueSaturationSettings {
        HueSaturationSettings(hue: min(180, max(-180, hueShift)), saturation: min(100, max(-100, saturation)),
                              lightness: min(100, max(-100, lightness)))
    }
}

/// What `recolor(_:in:name:)` and `updateRecolor` did, for the assistant to report back.
nonisolated struct RecolorResult: Equatable, Sendable {
    let layerID: UUID
    let layerName: String
    let settings: HueSaturationSettings
}

nonisolated enum RecolorError: LocalizedError, Equatable {
    case busy, nothingSelected, notRecolorLayer, tooLarge

    var errorDescription: String? {
        switch self {
        case .busy: "The editor is busy (a dialog, transform, crop or gesture is in progress)."
        case .nothingSelected: "Nothing is selected. Select the area first with `select`, or pass whole_image: true."
        case .notRecolorLayer: "That layer isn’t a Hue/Saturation adjustment layer."
        case .tooLarge: "The canvas is too large for a mask."
        }
    }
}

extension EditorSession {
    /// The average HSL lightness, 0…1, of the canvas as shown where `weight` (document pixels, white counts) covers
    /// it; `hiding` leaves that layer out, so a recolor layer measures what's under it. Nil with nothing covered.
    func averageLightness(weight draw: (CGContext) -> Void, hiding hidden: UUID? = nil) -> Double? {
        guard var document else { return nil }
        if let hidden, let index = document.layers.firstIndex(where: { $0.id == hidden }) { document.layers[index].isVisible = false }
        // Small: an average needs few pixels, and a full-size pass over a large photo would stall the window.
        let scale = min(1, 512 / CGFloat(max(document.width, document.height)))
        let width = max(1, Int((CGFloat(document.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(document.height) * scale).rounded()))
        guard let full = selectionSample(document, sampleAllLayers: true),
              let picture = try? BrushRaster.context(width: width, height: height, mask: false),
              let mask = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        picture.interpolationQuality = .medium
        BrushRaster.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: picture)
        mask.scaleBy(x: scale, y: scale)
        draw(mask)
        guard let colors = picture.data?.assumingMemoryBound(to: UInt8.self),
              let weights = mask.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var total = 0.0, covered = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let weight = Double(weights[y * mask.bytesPerRow + x]) / 255
                let pixel = y * picture.bytesPerRow + x * 4
                let alpha = Double(colors[pixel + 3]) / 255
                guard weight > 0, alpha > 0 else { continue }
                // Premultiplied: divided back out for the color's own lightness.
                let r = Double(colors[pixel]) / 255 / alpha, g = Double(colors[pixel + 1]) / 255 / alpha
                let b = Double(colors[pixel + 2]) / 255 / alpha
                total += weight * alpha * (max(r, g, b) + min(r, g, b)) / 2
                covered += weight * alpha
            }
        }
        return covered > 0 ? total / covered : nil
    }

    /// A Hue/Saturation adjustment layer at the top of the stack, masked to `selection` (nil: the whole image), as
    /// one "Recolor" undo step. The selection is used up, as Add Mask uses it.
    func recolor(_ settings: HueSaturationSettings, in selection: DocumentSelection?, name: String) throws -> RecolorResult {
        guard canEditLayers, var document = self.document else { throw RecolorError.busy }
        var layer = ImageLayer(name: name, blankSize: document.size)
        var adjustment = LayerAdjustment(kind: .hsv)
        adjustment.hsvSettings = settings
        layer.adjustment = adjustment
        if let selection {
            guard !selection.isEmpty else { throw RecolorError.nothingSelected }
            guard document.width * document.height <= DocumentLimits.maxSurfacePixels else { throw RecolorError.tooLarge }
            let context = try BrushRaster.context(width: document.width, height: document.height, mask: true)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: document.width, height: document.height))
            let clip = try selection.clip(canvas: document.size)
            clip.apply(to: context)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(clip.rect)
            guard let image = context.makeImage() else { throw ExportError.render }
            layer.mask = LayerMask(asset: try LayerMask.asset(from: image))
        }
        document.layers.append(layer)
        if selection != nil { document.selection = nil }
        finishOpacityEdit()
        beginEdit("Recolor")
        self.document = document
        activeLayerID = layer.id
        endEdit()
        brushRevision += 1
        return RecolorResult(layerID: layer.id, layerName: name, settings: settings)
    }

    /// Changes an existing Hue/Saturation layer's settings, as one "Recolor" undo step.
    func updateRecolor(_ id: UUID, settings: HueSaturationSettings) throws -> RecolorResult {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index] else { throw RecolorError.busy }
        guard var adjustment = layer.adjustment, adjustment.kind == .hsv else { throw RecolorError.notRecolorLayer }
        adjustment.hsvSettings = settings
        beginEdit("Recolor")
        document?.layers[index].adjustment = adjustment
        endEdit()
        brushRevision += 1
        return RecolorResult(layerID: id, layerName: layer.name, settings: settings)
    }
}
