import Foundation
import AutoAudioCore

func runAuxFaderScaleChecks() throws {
    let normal = AuxFaderScale()
    try check(normal.decibels(at: 0) == -150 && normal.decibels(at: 1) == 0, "Audio taper preserves finite floor and unity endpoints")
    try check(abs(normal.position(for: -10) - 0.5) < 1e-10, "Listening levels receive half of slider travel")
    let topStep = normal.decibels(at: 1) - normal.decibels(at: 0.99)
    try check(topStep < 0.25 && topStep < 150 * 0.01, "One percent of slider travel near unity gives a fine adjustment")
    for (minimum, maximum) in [(-150.0, 0.0), (-140, -8), (-35, -12), (-150, 12), (2, 50), (-60, -60), (-60, 0), (-80, 0)] {
        let scale = AuxFaderScale(minimumDB: minimum, maximumDB: maximum)
        try check(abs(scale.decibels(at: 0) - minimum) < 1e-9 && abs(scale.decibels(at: 1) - maximum) < 1e-9, "Effective linked range endpoints remain exact")
        var previous = minimum
        for step in 0...1000 {
            let unit = Double(step) / 1000
            let db = scale.decibels(at: unit)
            try check(db >= previous - 1e-9 && db >= minimum && db <= maximum, "Audio taper is monotone and cannot escape linked limits")
            if minimum < maximum {
                try check(abs(scale.position(for: db) - unit) < 1e-9, "Audio taper inverse round trips across all segments")
            }
            previous = db
        }
        try check(scale.decibels(at: -1) == minimum && scale.decibels(at: 2) == maximum, "Out of range input clamps to effective limits")
    }
    let main = AuxFaderScale(minimumDB: -50, maximumDB: 6, midpointDB: -10)
    try check(main.decibels(at: 0.5) == -10 && main.position(for: -10) == 0.5, "Main default travel places listening anchor at midpoint")
    for endpoints in [(-50.0, 6.0), (-80, 0), (-9, 6), (-50, -20)] {
        let scale = AuxFaderScale(minimumDB: endpoints.0, maximumDB: endpoints.1, midpointDB: -10)
        for step in 0...1000 {
            let unit = Double(step) / 1000
            try check(abs(scale.position(for: scale.decibels(at: unit)) - unit) < 1e-9, "Main anchored travel round trips, including ranges outside anchor")
        }
    }
    let custom = AuxFaderScale(minimumDB: -60, maximumDB: 0)
    try check(custom.position(for: -100) == 0 && custom.position(for: -10) != 0.5, "Custom floors pin lower values and normalize the original taper across their endpoints")
    try check(normal.decibels(at: .nan) == -150 && normal.position(for: .infinity) == 0, "Nonfinite presentation input has a finite floor fallback")
    print("Aux scale checks: audio taper, listening resolution, inverse and linked limits passed")
}
