import Foundation

enum FanCurveMath {
    static let minimumTemperature = 30.0
    static let maximumTemperature = 110.0
    static let minimumTemperatureSpacing = 1.0
    static let maximumPointCount = 8

    static func normalized(_ points: [FanCurvePoint], minRPM: Int, maxRPM: Int) -> [FanCurvePoint] {
        guard minRPM < maxRPM else { return [] }

        var result = points
            .filter { $0.temperatureC.isFinite }
            .map { point in
                FanCurvePoint(
                    id: point.id,
                    temperatureC: clamp(point.temperatureC, minimumTemperature, maximumTemperature),
                    rpm: clamp(point.rpm, minRPM, maxRPM)
                )
            }
            .sorted {
                if $0.temperatureC == $1.temperatureC {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.temperatureC < $1.temperatureC
            }

        var collapsed: [FanCurvePoint] = []
        for point in result {
            if let last = collapsed.last,
               point.temperatureC - last.temperatureC < minimumTemperatureSpacing {
                collapsed[collapsed.count - 1].temperatureC = (last.temperatureC + point.temperatureC) / 2
                collapsed[collapsed.count - 1].rpm = Int((Double(last.rpm + point.rpm) / 2).rounded())
            } else {
                collapsed.append(point)
            }
        }
        result = collapsed

        while result.count > maximumPointCount, result.count > 2 {
            let removable = (1..<(result.count - 1)).min { lhs, rhs in
                interpolationError(at: lhs, in: result) < interpolationError(at: rhs, in: result)
            }
            guard let removable else { break }
            result.remove(at: removable)
        }

        guard !result.isEmpty else { return [] }
        for index in result.indices.dropFirst() {
            result[index].temperatureC = max(
                result[index].temperatureC,
                result[index - 1].temperatureC + minimumTemperatureSpacing
            )
        }
        if result[result.count - 1].temperatureC > maximumTemperature {
            result[result.count - 1].temperatureC = maximumTemperature
            if result.count > 1 {
                for index in stride(from: result.count - 2, through: 0, by: -1) {
                    result[index].temperatureC = min(
                        result[index].temperatureC,
                        result[index + 1].temperatureC - minimumTemperatureSpacing
                    )
                }
            }
        }

        let safeRPMs = isotonicRPMs(result.map(\.rpm), minRPM: minRPM, maxRPM: maxRPM)
        for index in result.indices {
            result[index].rpm = safeRPMs[index]
        }
        return result
    }

    static func updating(
        _ points: [FanCurvePoint],
        pointID: UUID,
        temperature: Double?,
        rpm: Int?,
        minRPM: Int,
        maxRPM: Int
    ) -> [FanCurvePoint] {
        var result = normalized(points, minRPM: minRPM, maxRPM: maxRPM)
        guard let index = result.firstIndex(where: { $0.id == pointID }) else { return result }

        if let temperature, temperature.isFinite {
            let lower = index > 0
                ? result[index - 1].temperatureC + minimumTemperatureSpacing
                : minimumTemperature
            let upper = index + 1 < result.count
                ? result[index + 1].temperatureC - minimumTemperatureSpacing
                : maximumTemperature
            result[index].temperatureC = clamp(temperature, lower, upper)
        }

        if let rpm {
            let lower = index > 0 ? result[index - 1].rpm : minRPM
            let upper = index + 1 < result.count ? result[index + 1].rpm : maxRPM
            result[index].rpm = clamp(rpm, lower, upper)
        }

        return result
    }

    static func addingPoint(to points: [FanCurvePoint], minRPM: Int, maxRPM: Int) -> [FanCurvePoint] {
        var result = normalized(points, minRPM: minRPM, maxRPM: maxRPM)
        guard result.count >= 2, result.count < maximumPointCount else { return result }

        guard let insertion = zip(result.indices, result.indices.dropFirst()).max(by: { lhs, rhs in
            let lhsGap = result[lhs.1].temperatureC - result[lhs.0].temperatureC
            let rhsGap = result[rhs.1].temperatureC - result[rhs.0].temperatureC
            return lhsGap < rhsGap
        }) else {
            return result
        }

        let lower = result[insertion.0]
        let upper = result[insertion.1]
        guard upper.temperatureC - lower.temperatureC >= minimumTemperatureSpacing * 2 else { return result }

        result.append(FanCurvePoint(
            temperatureC: (lower.temperatureC + upper.temperatureC) / 2,
            rpm: Int((Double(lower.rpm + upper.rpm) / 2).rounded())
        ))
        return normalized(result, minRPM: minRPM, maxRPM: maxRPM)
    }

    static func removingPoint(
        from points: [FanCurvePoint],
        pointID: UUID,
        minRPM: Int,
        maxRPM: Int
    ) -> [FanCurvePoint] {
        let normalizedPoints = normalized(points, minRPM: minRPM, maxRPM: maxRPM)
        guard normalizedPoints.count > 2 else { return normalizedPoints }
        return normalized(
            normalizedPoints.filter { $0.id != pointID },
            minRPM: minRPM,
            maxRPM: maxRPM
        )
    }

    static func interpolatedRPM(
        temperature: Double,
        points: [FanCurvePoint],
        minRPM: Int,
        maxRPM: Int,
        fallback: Int
    ) -> Int {
        let curve = normalized(points, minRPM: minRPM, maxRPM: maxRPM)
        guard let first = curve.first, let last = curve.last else {
            return clamp(fallback, minRPM, maxRPM)
        }
        if temperature <= first.temperatureC { return first.rpm }
        if temperature >= last.temperatureC { return last.rpm }

        for (lower, upper) in zip(curve, curve.dropFirst())
        where temperature >= lower.temperatureC && temperature <= upper.temperatureC {
            let span = upper.temperatureC - lower.temperatureC
            guard span > 0 else { return upper.rpm }
            let progress = (temperature - lower.temperatureC) / span
            let value = Double(lower.rpm) + Double(upper.rpm - lower.rpm) * progress
            return clamp(Int(value.rounded()), minRPM, maxRPM)
        }
        return clamp(fallback, minRPM, maxRPM)
    }

    private struct IsotonicBlock {
        var start: Int
        var end: Int
        var sum: Double
        var count: Int

        var average: Double { sum / Double(count) }
    }

    private static func isotonicRPMs(_ values: [Int], minRPM: Int, maxRPM: Int) -> [Int] {
        var blocks: [IsotonicBlock] = []
        for (index, value) in values.enumerated() {
            blocks.append(IsotonicBlock(start: index, end: index, sum: Double(value), count: 1))
            while blocks.count >= 2, blocks[blocks.count - 2].average > blocks[blocks.count - 1].average {
                let right = blocks.removeLast()
                let left = blocks.removeLast()
                blocks.append(IsotonicBlock(
                    start: left.start,
                    end: right.end,
                    sum: left.sum + right.sum,
                    count: left.count + right.count
                ))
            }
        }

        var result = Array(repeating: minRPM, count: values.count)
        for block in blocks {
            let value = clamp(Int(block.average.rounded()), minRPM, maxRPM)
            for index in block.start...block.end {
                result[index] = value
            }
        }
        return result
    }

    private static func interpolationError(at index: Int, in points: [FanCurvePoint]) -> Double {
        let lower = points[index - 1]
        let current = points[index]
        let upper = points[index + 1]
        let span = upper.temperatureC - lower.temperatureC
        guard span > 0 else { return 0 }
        let progress = (current.temperatureC - lower.temperatureC) / span
        let expected = Double(lower.rpm) + Double(upper.rpm - lower.rpm) * progress
        return abs(Double(current.rpm) - expected)
    }

    private static func clamp<T: Comparable>(_ value: T, _ minimum: T, _ maximum: T) -> T {
        max(minimum, min(maximum, value))
    }
}
