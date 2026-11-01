import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What `look_at_canvas` sends a model that can see: the canvas, or part of it, made small, with rulers along the top
/// and left numbered in document pixels so the model reads positions off them rather than working them out, and the
/// selection tinted and outlined.
nonisolated enum CanvasLook {
    /// The longer side of the picture, rulers aside. Enough to point at a pair of shoes, small enough to send often.
    static let longEdge = 1024
    static let rulerWidth = 28
    static let selectionColor = CGColor(srgbRed: 1, green: 0, blue: 0.85, alpha: 1)

    struct Result: @unchecked Sendable {
        let image: CGImage
        /// The part of the document shown, in document pixels.
        let region: CGRect
        /// Document pixels to one pixel of the picture.
        let scale: CGFloat
    }

    /// `region` is clamped to the canvas; nil shows all of it. A region smaller than `longEdge` is enlarged, at most
    /// 4×, so a close look shows more.
    static func render(_ composite: CGImage, region: CGRect?, selection: CGPath?) throws -> Result {
        let canvas = CGRect(x: 0, y: 0, width: composite.width, height: composite.height)
        let shown = (region ?? canvas).integral.intersection(canvas)
        guard !shown.isNull, shown.width >= 1, shown.height >= 1 else { throw ToolError.failed("The region is outside the canvas.") }
        let fit = CGFloat(longEdge) / max(shown.width, shown.height)
        let zoom = min(4, fit)
        let width = max(1, Int((shown.width * zoom).rounded())), height = max(1, Int((shown.height * zoom).rounded()))
        let ruler = CGFloat(rulerWidth)
        let context = try BrushRaster.context(width: width + rulerWidth, height: height + rulerWidth, mask: false)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width + rulerWidth, height: height + rulerWidth))
        context.interpolationQuality = zoom > 1 ? .medium : .high

        // Document pixels to the picture's: the region's corner at the rulers' inside corner.
        let toPicture = CGAffineTransform(translationX: ruler, y: ruler).scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -shown.minX, y: -shown.minY)
        context.saveGState()
        context.clip(to: CGRect(x: ruler, y: ruler, width: CGFloat(width), height: CGFloat(height)))
        context.saveGState()
        context.concatenate(toPicture)
        // The context is flipped to a top-left origin; an image draws upright only in an unflipped space.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(composite, in: canvas)
        context.restoreGState()
        if let selection, !selection.isEmpty {
            var transform = toPicture
            if let outline = selection.copy(using: &transform) {
                context.addPath(outline)
                context.setFillColor(selectionColor.copy(alpha: 0.28)!)
                context.fillPath(using: .winding)
                context.addPath(outline)
                context.setStrokeColor(selectionColor)
                context.setLineWidth(2)
                context.strokePath()
            }
        }
        context.restoreGState()
        drawRulers(in: context, region: shown, zoom: zoom, width: width, height: height)
        guard let image = context.makeImage() else { throw ExportError.render }
        return Result(image: image, region: shown, scale: 1 / zoom)
    }

    private static func drawRulers(in context: CGContext, region: CGRect, zoom: CGFloat, width: Int, height: Int) {
        let ruler = CGFloat(rulerWidth)
        let step = rulerStep(zoom: zoom)
        context.setFillColor(gray: 0.93, alpha: 1)
        context.fill(CGRect(x: ruler, y: 0, width: CGFloat(width), height: ruler))
        context.fill(CGRect(x: 0, y: ruler, width: ruler, height: CGFloat(height)))
        context.setStrokeColor(gray: 0.3, alpha: 1)
        context.setLineWidth(1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                        .foregroundColor: NSColor.black]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        var value = (region.minX / step).rounded(.up) * step
        while value <= region.maxX {
            let x = ruler + (value - region.minX) * zoom
            context.move(to: CGPoint(x: x, y: ruler - 8)); context.addLine(to: CGPoint(x: x, y: ruler))
            label(value).draw(at: CGPoint(x: x + 2, y: 3), withAttributes: attributes)
            value += step
        }
        value = (region.minY / step).rounded(.up) * step
        while value <= region.maxY {
            let y = ruler + (value - region.minY) * zoom
            context.move(to: CGPoint(x: ruler - 8, y: y)); context.addLine(to: CGPoint(x: ruler, y: y))
            let text = label(value)
            // Turned to read up the left edge, as on the canvas's own ruler.
            context.saveGState()
            context.translateBy(x: 3, y: y - 2)
            context.rotate(by: -.pi / 2)
            text.draw(at: .zero, withAttributes: attributes)
            context.restoreGState()
            value += step
        }
        context.strokePath()
    }

    /// About 90 picture pixels between numbers, on the canvas rulers' 1-2-5 steps in document pixels.
    static func rulerStep(zoom: CGFloat) -> CGFloat {
        let target = 90 / max(zoom, 0.0001)
        let nice: [CGFloat] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1_000, 2_000, 2_500, 5_000, 10_000, 20_000, 25_000]
        return nice.first { $0 >= target } ?? 50_000
    }

    private static func label(_ value: CGFloat) -> NSString { String(Int(value.rounded())) as NSString }

    /// The picture as a JPEG data URL, for a chat message.
    static func dataURL(_ image: CGImage, quality: Double = 0.8) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}
