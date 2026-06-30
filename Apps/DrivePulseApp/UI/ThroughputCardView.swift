import SwiftUI

import DrivePulseCore

struct ThroughputChartModel {
    static let visibleSampleCount = 300

    let readSamples: [Double?]
    let writeSamples: [Double?]
    let chartPeakBytesPerSecond: Double

    init(metrics: DeviceSessionMetrics) {
        self.readSamples = Self.rightAlignedSamples(
            values: metrics.readHistory.map(\.bytesPerSecond),
            visibleSampleCount: Self.visibleSampleCount
        )
        self.writeSamples = Self.rightAlignedSamples(
            values: metrics.writeHistory.map(\.bytesPerSecond),
            visibleSampleCount: Self.visibleSampleCount
        )
        self.chartPeakBytesPerSecond = Self.peakBytesPerSecond(
            for: readSamples + writeSamples
        )
    }

    var hasVisibleReadSeries: Bool {
        readSamples.contains(where: { $0 != nil })
    }

    var hasVisibleWriteSeries: Bool {
        writeSamples.contains(where: { $0 != nil })
    }

    private static func peakBytesPerSecond(for samples: [Double?]) -> Double {
        let peak = samples.compactMap { $0 }.max() ?? 0
        return peak > 0 ? peak : 1
    }

    private static func rightAlignedSamples(
        values: [Double],
        visibleSampleCount: Int
    ) -> [Double?] {
        let count = max(visibleSampleCount, 1)
        let trimmedValues = Array(values.suffix(count))
        let leadingGapCount = max(count - trimmedValues.count, 0)
        let leadingGap = Array<Double?>(repeating: nil, count: leadingGapCount)
        return leadingGap + trimmedValues.map(Optional.some)
    }
}

struct ThroughputCardView: View {
    let device: ExternalDevice?

    var body: some View {
        Group {
            if let metrics = device?.sessionMetrics {
                VStack(alignment: .leading, spacing: 8) {
                    ThroughputChartCanvas(metrics: metrics)
                    ThroughputTotalsView(metrics: metrics)
                }
            } else {
                Text("No throughput data")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ThroughputChartCanvas: View {
    let metrics: DeviceSessionMetrics
    private let labelColumnWidth: CGFloat = 76

    var body: some View {
        let model = ThroughputChartModel(metrics: metrics)
        let readSpeed = rateString(metrics.currentReadBytesPerSecond)
        let writeSpeed = rateString(metrics.currentWriteBytesPerSecond)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                rateLabel(readSpeed, color: .blue)
                Spacer(minLength: 0)
                rateLabel(writeSpeed, color: .red)
            }
            .frame(width: labelColumnWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .leading)
            .padding(.vertical, 6)

            VStack(spacing: 0) {
                ThroughputHalfSeriesLayer(
                    samples: model.readSamples,
                    maxValue: model.chartPeakBytesPerSecond,
                    color: .blue,
                    alignment: .top
                )
                .clipped()

                ThroughputHalfSeriesLayer(
                    samples: model.writeSamples,
                    maxValue: model.chartPeakBytesPerSecond,
                    color: .red,
                    alignment: .bottom
                )
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }

    private func rateLabel(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rateString(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(bytesPerSecond.rounded())
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))/s"
    }
}

private struct ThroughputHalfSeriesLayer: View {
    let samples: [Double?]
    let maxValue: Double
    let color: Color
    let alignment: VerticalAlignment

    var body: some View {
        Canvas { context, size in
            let lineSegments = makeLineSegments(size: size)
            guard lineSegments.isEmpty == false else {
                return
            }

            for lineSegment in lineSegments {
                if lineSegment.count == 1 {
                    let point = lineSegment[0]
                    let radius: CGFloat = 1
                    let dot = Path(ellipseIn: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    context.fill(dot, with: .color(color.opacity(0.82)))
                    continue
                }

                context.fill(
                    areaPath(for: lineSegment, size: size),
                    with: fillShading(size: size)
                )
                context.stroke(
                    linePath(for: lineSegment),
                    with: .color(color.opacity(0.82)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func makeLineSegments(size: CGSize) -> [[CGPoint]] {
        guard samples.isEmpty == false else {
            return []
        }

        var segments: [[CGPoint]] = []
        var currentSegment: [CGPoint] = []

        for (index, sample) in samples.enumerated() {
            guard let sample else {
                if currentSegment.isEmpty == false {
                    segments.append(currentSegment)
                    currentSegment = []
                }
                continue
            }

            currentSegment.append(
                CGPoint(
                    x: x(for: index, count: samples.count, width: size.width),
                    y: y(for: sample, maxValue: maxValue, size: size)
                )
            )
        }

        if currentSegment.isEmpty == false {
            segments.append(currentSegment)
        }

        return segments
    }

    private func areaPath(for lineSegment: [CGPoint], size: CGSize) -> Path {
        guard let firstPoint = lineSegment.first,
              let lastPoint = lineSegment.last else {
            return Path()
        }

        let baselineY = baseline(size: size)
        var path = Path()
        path.move(to: CGPoint(x: firstPoint.x, y: baselineY))
        path.addLines(lineSegment)
        path.addLine(to: CGPoint(x: lastPoint.x, y: baselineY))
        path.closeSubpath()
        return path
    }

    private func linePath(for lineSegment: [CGPoint]) -> Path {
        var path = Path()
        guard let firstPoint = lineSegment.first else {
            return path
        }

        path.move(to: firstPoint)
        for point in lineSegment.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func x(for index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else {
            return width
        }
        return CGFloat(index) * (width / CGFloat(count - 1))
    }

    private func y(for value: Double, maxValue: Double, size: CGSize) -> CGFloat {
        let normalized = CGFloat(max(0, min(value / maxValue, 1)))
        let drawableHeight = max(size.height - 1, 1)

        switch alignment {
        case .top:
            return size.height - normalized * drawableHeight
        case .bottom:
            return normalized * drawableHeight
        default:
            return size.height
        }
    }

    private func baseline(size: CGSize) -> CGFloat {
        switch alignment {
        case .top:
            return size.height
        case .bottom:
            return 0
        default:
            return size.height
        }
    }

    private func fillShading(size: CGSize) -> GraphicsContext.Shading {
        let baselineColor = color.opacity(0.03)
        let peakColor = color.opacity(0.24)

        switch alignment {
        case .top:
            return .linearGradient(
                Gradient(colors: [baselineColor, peakColor]),
                startPoint: CGPoint(x: size.width / 2, y: size.height),
                endPoint: CGPoint(x: size.width / 2, y: 0)
            )
        case .bottom:
            return .linearGradient(
                Gradient(colors: [baselineColor, peakColor]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        default:
            return .color(peakColor)
        }
    }
}

private struct ThroughputTotalsView: View {
    let metrics: DeviceSessionMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            totalRow(
                title: "Session Read",
                value: byteCountString(metrics.cumulativeReadBytes)
            )
            totalRow(
                title: "Session Write",
                value: byteCountString(metrics.cumulativeWriteBytes)
            )
        }
    }

    private func totalRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }

    private func byteCountString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
