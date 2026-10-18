import Foundation

/// A conventional audio taper. Decibels already describe logarithmic gain, so
/// this allocates slider travel to listening levels instead of taking log(dB).
/// The finite -150 dB floor remains reachable, while -10...0 dB occupies half
/// of the normal -150...0 dB slider. Positive configured gains extend the taper.
/// Presentation endpoints remain stable independently of linked movement bounds.
public struct AuxFaderScale: Sendable {
    public let minimumDB: Double
    public let maximumDB: Double
    private let midpointDB: Double?
    private static let decibels: [Double] = [-150, -60, -40, -20, -10, 0, 50]
    private static let travel: [Double] = [0, 0.04, 0.12, 0.30, 0.50, 1, 3.5]

    public init(minimumDB: Double = -150, maximumDB: Double = 0, midpointDB: Double? = nil) {
        // DSP limits are independently enforced by AuxController. Keep this
        // presentation mapping finite and inside the supported DSP envelope.
        let lower = minimumDB.isFinite ? min(50, max(-150, minimumDB)) : -150
        let upper = maximumDB.isFinite ? min(50, max(-150, maximumDB)) : lower
        self.minimumDB = lower
        self.maximumDB = max(lower, upper)
        self.midpointDB = midpointDB.flatMap { $0.isFinite && lower < $0 && $0 < upper ? $0 : nil }
    }
    public func decibels(at position: Double) -> Double {
        guard minimumDB < maximumDB else { return minimumDB }
        let unit = position.isFinite ? min(1, max(0, position)) : 0
        if unit == 0 { return minimumDB }
        if unit == 1 { return maximumDB }
        let lower = Self.interpolate(minimumDB, from: Self.decibels, to: Self.travel)
        let upper = Self.interpolate(maximumDB, from: Self.decibels, to: Self.travel)
        let tapered: Double
        if let midpointDB {
            let middle = Self.interpolate(midpointDB, from: Self.decibels, to: Self.travel)
            tapered = unit <= 0.5 ? lower + unit * 2 * (middle - lower) : middle + (unit - 0.5) * 2 * (upper - middle)
        } else { tapered = lower + unit * (upper - lower) }
        let result = Self.interpolate(tapered, from: Self.travel, to: Self.decibels)
        return min(maximumDB, max(minimumDB, result))
    }
    public func position(for decibels: Double) -> Double {
        guard minimumDB < maximumDB else { return 0 }
        let db = decibels.isFinite ? min(maximumDB, max(minimumDB, decibels)) : minimumDB
        let lower = Self.interpolate(minimumDB, from: Self.decibels, to: Self.travel)
        let upper = Self.interpolate(maximumDB, from: Self.decibels, to: Self.travel)
        let tapered = Self.interpolate(db, from: Self.decibels, to: Self.travel)
        if let midpointDB {
            let middle = Self.interpolate(midpointDB, from: Self.decibels, to: Self.travel)
            return min(1, max(0, tapered <= middle ? 0.5 * (tapered - lower) / (middle - lower) : 0.5 + 0.5 * (tapered - middle) / (upper - middle)))
        }
        return min(1, max(0, (tapered - lower) / (upper - lower)))
    }
    private static func interpolate(_ value: Double, from source: [Double], to destination: [Double]) -> Double {
        if value <= source[0] { return destination[0] }
        for index in 1..<source.count where value <= source[index] {
            let fraction = (value - source[index - 1]) / (source[index] - source[index - 1])
            return destination[index - 1] + fraction * (destination[index] - destination[index - 1])
        }
        return destination[destination.count - 1]
    }
}
