import SwiftUI
import AppKit

struct AircraftMapDrawResult {
    struct Icon {
        let id: String
        let symbol: String
        let anchor: CGPoint
        let width: CGFloat
        let height: CGFloat
        let angle: Double
    }

    struct Label {
        let text: String
        let origin: CGPoint
    }

    let visibleIDs: Set<String>
    let shanghaiIDs: Set<String>
    let labelPositions: [String: Int]
    let icons: [Icon]
    let labels: [Label]
}

enum AircraftMapLayer {
    static let fontSize: CGFloat = 8.5
    // Fixed medium gray remains visible on a white map background.
    static let aircraftColor = Color(
        .sRGB, red: 0.42, green: 0.42, blue: 0.42, opacity: 1
    )
    // Set false to restore collision avoidance.
    static let allowOverlap = true

    static func layout(
        context: GraphicsContext,
        frozen: Bool = false,
        canvas: CGRect,
        aircraft: [TrackedAircraft],
        metadata: [String: AircraftMetadata],
        reserved: [CGRect],
        previousLabelPositions: [String: Int] = [:],
        preferredIDs: Set<String> = [],
        preferredShanghaiIDs: Set<String> = [],
        now: Date,
        bounds: AircraftBounds,
        project: @escaping (Double, Double) -> CGPoint
    ) -> AircraftMapDrawResult {
        var occupied = reserved
        var visibleIDs = Set<String>()
        var positions: [String: Int] = [:]
        var icons: [AircraftMapDrawResult.Icon] = []
        var labels: [AircraftMapDrawResult.Label] = []
        var drawnIcons: [(AircraftState, CGRect)] = []
        let safeCanvas = canvas.insetBy(dx: 2, dy: 2)
        // Measure once; use exactly the same rectangle for selection and drawing.
        func iconGeometry(_ item: TrackedAircraft) -> (
            anchor: CGPoint, width: CGFloat, height: CGFloat,
            angle: Double, rect: CGRect
        )? {
            let state = item.state
            let anchor = project(state.longitude, state.latitude)
            guard anchor.x.isFinite, anchor.y.isFinite else { return nil }
            let helicopter = item.kind == .helicopter
            let symbol = helicopter ? "helicopter" : "airplane"
            guard let native = NSImage(
                systemSymbolName: symbol, accessibilityDescription: nil
            ) else { return nil }
            let natural = context.resolve(Image(nsImage: native)).size
            guard natural.width > 0, natural.height > 0 else { return nil }
            let scale = fontSize / max(natural.width, natural.height)
            let width = natural.width * scale
            let height = natural.height * scale
            let angle = helicopter ? 0 : (state.track.map { $0 - 90 } ?? 0)
            let radians = angle * .pi / 180
            let rotatedWidth = abs(cos(radians)) * width + abs(sin(radians)) * height
            let rotatedHeight = abs(sin(radians)) * width + abs(cos(radians)) * height
            return (anchor, width, height, angle, CGRect(
                x: anchor.x - rotatedWidth / 2,
                y: anchor.y - rotatedHeight / 2,
                width: rotatedWidth, height: rotatedHeight))
        }

        // Count eligible targets inside the actual drawing viewport.
        // Labels never move an aircraft away from its projected coordinate.
        let viewportIDs = Set(aircraft.compactMap { item -> String? in
            guard item.state.isVisible(at: now, bounds: bounds),
                  let geometry = iconGeometry(item),
                  safeCanvas.contains(geometry.rect) else { return nil }
            return item.state.icao24
        })
        let displayTarget = min(10, viewportIDs.count)
        var iconRects: [String: CGRect] = [:]
        let candidates = aircraft.filter { item in
            guard item.state.isVisible(at: now, bounds: bounds),
                  let geometry = iconGeometry(item),
                  safeCanvas.contains(geometry.rect),
                  (allowOverlap || !reserved.contains(where: {
                      $0.intersects(geometry.rect.insetBy(dx: -2, dy: -2))
                  })) else { return false }
            iconRects[item.state.icao24] = geometry.rect
            return true
        }
        // Use explicit provider selection and hysteresis group membership.
        // Candidate array order is not a reliable selection record.
        let selection = frozen
            ? AircraftSelectionResult(
                aircraft: candidates.filter {
                    preferredIDs.contains($0.state.icao24)
                },
                shanghaiIDs: preferredShanghaiIDs)
            : AircraftSelector.select(
            candidates, bounds: bounds,
            previousIDs: preferredIDs,
            previousShanghaiIDs: preferredShanghaiIDs,
            now: now,
            targetCount: displayTarget,
            normalizedPosition: { item in
                let point = project(
                    item.state.longitude, item.state.latitude)
                return (
                    Double((point.x - safeCanvas.minX) / safeCanvas.width),
                    Double((point.y - safeCanvas.minY) / safeCanvas.height)
                )
            },
            canSelect: { candidate, selected in
                if allowOverlap { return true }
                guard let rect = iconRects[candidate.state.icao24] else {
                    return false
                }
                return !selected.contains { other in
                    guard let otherRect = iconRects[other.state.icao24] else {
                        return false
                    }
                    return otherRect.intersects(rect.insetBy(dx: -2, dy: -2))
                }
            })
        let ordered = selection.aircraft

        func available(_ rect: CGRect) -> Bool {
            safeCanvas.contains(rect)
                && (allowOverlap || !occupied.contains {
                    $0.intersects(rect.insetBy(dx: -2, dy: -2))
                })
        }

        for item in ordered {
            guard visibleIDs.count < 10,
                  item.state.isVisible(at: now, bounds: bounds) else { continue }
            let state = item.state
            let anchor = project(state.longitude, state.latitude)
            guard anchor.x.isFinite, anchor.y.isFinite else { continue }
            let helicopter = item.kind == .helicopter
            // SF Symbols' airplane points right at its default orientation.
            let angle = helicopter ? 0 : (state.track.map { $0 - 90 } ?? 0)
            let symbol = helicopter ? "helicopter" : "airplane"
            // Never represent a helicopter using a misleading airplane fallback.
            guard let nativeImage = NSImage(
                systemSymbolName: symbol, accessibilityDescription: nil
            ) else { continue }
            // Explicit drawing dimensions below set the icon size.
            // GraphicsContext.resolve requires an Image, not a modified View.
            let image = context.resolve(Image(nsImage: nativeImage))
            let natural = image.size
            guard natural.width > 0, natural.height > 0 else { continue }
            let scale = fontSize / max(natural.width, natural.height)
            let width = natural.width * scale
            let height = natural.height * scale
            let radians = angle * .pi / 180
            let rotatedWidth = abs(cos(radians)) * width + abs(sin(radians)) * height
            let rotatedHeight = abs(sin(radians)) * width + abs(cos(radians)) * height
            let iconRect = CGRect(
                x: anchor.x - rotatedWidth / 2, y: anchor.y - rotatedHeight / 2,
                width: rotatedWidth, height: rotatedHeight)
            guard available(iconRect) else { continue }

            icons.append(AircraftMapDrawResult.Icon(
                id: state.icao24, symbol: symbol, anchor: anchor,
                width: width, height: height, angle: angle))
            occupied.append(iconRect)
            visibleIDs.insert(state.icao24)
            drawnIcons.append((state, iconRect))
        }

        // Reserve all accepted icons before placing any aircraft labels.
        // A long label must never suppress another aircraft's icon.
        for (state, iconRect) in drawnIcons {
            let anchor = CGPoint(x: iconRect.midX, y: iconRect.midY)
            guard let info = metadata[state.icao24] else { continue }
            let shortLabel = [info.airline, info.model].compactMap { $0 }
                .joined(separator: " · ")
            var variants: [String] = []
            for value in [info.label, shortLabel.isEmpty ? nil : shortLabel, info.model] {
                if let value, !value.isEmpty, !variants.contains(value) {
                    variants.append(value)
                }
            }
            var placed = false
            for value in variants {
                let text = context.resolve(Text(verbatim: value)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(aircraftColor))
                let measured = text.measure(in: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude))
                guard measured.width.isFinite, measured.height.isFinite else { continue }
                let w = ceil(measured.width), h = ceil(measured.height)
                let gap: CGFloat = 4
                let boxes = [
                    CGRect(
                        x: iconRect.maxX + gap, y: anchor.y - h / 2,
                        width: w, height: h),
                    CGRect(
                        x: iconRect.minX - gap - w, y: anchor.y - h / 2,
                        width: w, height: h)
                ]
                // Keep the icon and text on one horizontal line.
                let order = [0, 1]
                guard let index = order.first(where: { available(boxes[$0]) }) else {
                    continue
                }
                let rect = boxes[index]
                labels.append(AircraftMapDrawResult.Label(
                    text: value, origin: rect.origin))
                occupied.append(rect)
                positions[state.icao24] = index
                placed = true
                break
            }
            if !placed {
                // Keep the icon when there is no collision-free label position.
                continue
            }
        }
        return AircraftMapDrawResult(
            visibleIDs: visibleIDs,
            shanghaiIDs: selection.shanghaiIDs.intersection(visibleIDs),
            labelPositions: positions, icons: icons, labels: labels)
    }

    static func render(
        _ layout: AircraftMapDrawResult,
        context: inout GraphicsContext,
        color: Color = aircraftColor
    ) {
        for icon in layout.icons {
            guard let native = NSImage(
                systemSymbolName: icon.symbol,
                accessibilityDescription: nil
            ) else { continue }
            var image = context.resolve(
                Image(nsImage: native).renderingMode(.template))
            image.shading = .color(color)
            var layer = context
            layer.translateBy(x: icon.anchor.x, y: icon.anchor.y)
            layer.rotate(by: .degrees(icon.angle))
            layer.draw(image, in: CGRect(
                x: -icon.width / 2, y: -icon.height / 2,
                width: icon.width, height: icon.height))
        }
        for label in layout.labels {
            let text = context.resolve(Text(verbatim: label.text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(color))
            var layer = context
            layer.addFilter(.shadow(
                color: Color(nsColor: .windowBackgroundColor).opacity(0.9),
                radius: 1))
            layer.draw(text, at: label.origin, anchor: .topLeading)
        }
    }

    @discardableResult
    static func draw(
        context: inout GraphicsContext,
        canvas: CGRect,
        aircraft: [TrackedAircraft],
        metadata: [String: AircraftMetadata],
        reserved: [CGRect],
        previousLabelPositions: [String: Int] = [:],
        preferredIDs: Set<String> = [],
        preferredShanghaiIDs: Set<String> = [],
        now: Date,
        bounds: AircraftBounds,
        project: @escaping (Double, Double) -> CGPoint
    ) -> AircraftMapDrawResult {
        let result = layout(
            context: context, canvas: canvas,
            aircraft: aircraft, metadata: metadata,
            reserved: reserved,
            previousLabelPositions: previousLabelPositions,
            preferredIDs: preferredIDs,
            preferredShanghaiIDs: preferredShanghaiIDs,
            now: now, bounds: bounds, project: project)
        render(result, context: &context)
        return result
    }
}
