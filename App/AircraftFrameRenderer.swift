import SwiftUI
import AppKit
import OSLog

@MainActor
enum AircraftFrameRenderer {
    static let size = CGSize(width: 380, height: 440)

    private final class Capture {
        var layout: AircraftMapDrawResult?
    }

    static func image(
        for frame: AircraftHistoryPresentation
    ) -> CGImage? {
        guard !frame.selectedIDs.isEmpty,
              let geometry = try? ThermalMapGeometry.bundled(),
              geometry.bounds.count == 4 else { return nil }

        let b = geometry.bounds
        guard b.allSatisfy(\.isFinite),
              b[0] < b[2], b[1] < b[3],
              b[1] > -85, b[3] < 85 else { return nil }

        let west = b[0] * Double.pi / 180
        let east = b[2] * Double.pi / 180
        func mercator(_ latitude: Double) -> Double {
            log(tan(.pi / 4 + latitude * .pi / 360))
        }
        let south = mercator(b[1])
        let north = mercator(b[3])
        let scale = min(
            Double(size.width) * 0.64 / (east - west),
            (Double(size.height) - 18) / (north - south))
        guard scale.isFinite, scale > 0 else { return nil }

        // Identical centered Mercator projection to ThermalMapView.
        let projectedWidth = (east - west) * scale
        let projectedHeight = (north - south) * scale
        let originX = (Double(size.width) - projectedWidth) / 2
        let originY = (Double(size.height) - projectedHeight) / 2
        let capture = Capture()

        let canvas = Canvas { context, canvasSize in
            let layout = AircraftMapLayer.layout(
                context: context,
                frozen: true,
                canvas: CGRect(origin: .zero, size: canvasSize),
                aircraft: frame.aircraft,
                metadata: frame.metadata,
                reserved: [],
                previousLabelPositions: frame.labelPositions,
                preferredIDs: frame.selectedIDs,
                preferredShanghaiIDs: frame.shanghaiIDs,
                now: frame.fetchedAt,
                bounds: frame.bounds,
                project: { longitude, latitude in
                    CGPoint(
                        x: originX
                            + (longitude * .pi / 180 - west) * scale,
                        y: originY + (north - mercator(latitude)) * scale)
                })
            capture.layout = layout
            var graphics = context
            AircraftMapLayer.render(
                layout, context: &graphics, color: .white)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(
            width: size.width, height: size.height)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.isOpaque = false

        guard let image = renderer.cgImage,
              let layout = capture.layout,
              !layout.visibleIDs.isEmpty else {
            Logger(
                subsystem: "com.songa.ShanghaiTemperature",
                category: "AircraftPlayback"
            ).error("Aircraft frame preparation failed; preserving previous picture")
            return nil
        }
        return image
    }
}
