import Foundation
import CoreFoundation

/// Compares normalized preset JSON without treating floating-point text
/// round-trips as edits. Structure and all non-floating values remain exact.
public enum PresetConfigurationIdentity {
    private static let maximumFloatingPointULPDistance: UInt64 = 4
    private static let signBit = UInt64(1) << 63

    public static func matches(activeConfiguration: String, candidateConfiguration: String) -> Bool {
        guard let active = try? JSONSerialization.jsonObject(with: Data(activeConfiguration.utf8)),
              let candidate = try? JSONSerialization.jsonObject(with: Data(candidateConfiguration.utf8)) else {
            return false
        }
        return equal(active, candidate)
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }

        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            let leftBoolean = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightBoolean = CFGetTypeID(right) == CFBooleanGetTypeID()
            if leftBoolean || rightBoolean {
                return leftBoolean && rightBoolean && left.boolValue == right.boolValue
            }
            let leftInteger = isInteger(left)
            let rightInteger = isInteger(right)
            guard leftInteger == rightInteger else { return false }
            if leftInteger { return left.compare(right) == .orderedSame }
            return equalFloatingPoint(left.doubleValue, right.doubleValue)
        }

        if let left = lhs as? String, let right = rhs as? String { return left == right }

        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            guard left.count == right.count, Set(left.keys) == Set(right.keys) else { return false }
            return left.allSatisfy { element in
                guard let other = right[element.key] else { return false }
                return equal(element.value, other)
            }
        }

        if let left = lhs as? [Any], let right = rhs as? [Any] {
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { pair in equal(pair.0, pair.1) }
        }

        return false
    }

    private static func isInteger(_ number: NSNumber) -> Bool {
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q": return true
        default: return false
        }
    }

    private static func equalFloatingPoint(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        if lhs == rhs { return true }
        let left = orderedBits(lhs.bitPattern)
        let right = orderedBits(rhs.bitPattern)
        let distance = left >= right ? left - right : right - left
        return distance <= maximumFloatingPointULPDistance
    }

    /// Map IEEE-754 sign/magnitude bits to monotonically increasing integers.
    private static func orderedBits(_ bits: UInt64) -> UInt64 {
        bits & signBit == 0 ? bits | signBit : ~bits
    }
}
