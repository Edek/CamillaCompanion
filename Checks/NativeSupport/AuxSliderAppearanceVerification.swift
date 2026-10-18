import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor private final class SliderAppearanceVerificationWindow: NSWindow, AudioFocusVerificationWindow {
    var focusedForVerification = false
    override var isKeyWindow: Bool { focusedForVerification }
    override var isMainWindow: Bool { focusedForVerification }
}

@MainActor enum AuxSliderAppearanceVerification {
    static func checks() -> [String: Bool] {
        _ = NSApplication.shared
        let originalPreference = AudioControlStyle.keepActiveColors
        defer { AudioControlStyle.keepActiveColors = originalPreference }
        let window = SliderAppearanceVerificationWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let slider = CommitSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = NSRect(x: 12, y: 10, width: 216, height: 20)
        slider.installAppearanceCell()
        window.contentView?.addSubview(slider)
        guard let cell = slider.cell as? ActiveColorsSliderCell else { return ["slider active colors cell installed": false] }
        // Initialize native geometry once, then vary cell values without drawing
        // the knob again. A cached knob position must not determine the fill.
        if let bitmap = slider.bitmapImageRepForCachingDisplay(in: slider.bounds) {
            slider.cacheDisplay(in: slider.bounds, to: bitmap)
        }
        let bar = cell.barRect(flipped: slider.isFlipped)
        let frame = slider.frame
        let knobWidth = cell.knobRect(flipped: slider.isFlipped).width
        AudioControlStyle.keepActiveColors = false
        let normalInactive = !cell.preservesTrackColor
        AudioControlStyle.keepActiveColors = true
        let preservedInactive = cell.preservesTrackColor
        window.focusedForVerification = true
        let normalFocused = !cell.preservesTrackColor
        window.focusedForVerification = false
        slider.isEnabled = false
        let normalDisabled = !cell.preservesTrackColor
        slider.isEnabled = true
        let low = cell.preservedFillRect(in: bar, flipped: slider.isFlipped)
        slider.doubleValue = 0.75
        let high = cell.preservedFillRect(in: bar, flipped: slider.isFlipped)
        var result = [
            "slider active colors override only affects enabled inactive tracks": normalInactive && preservedInactive && normalFocused && normalDisabled,
            "slider track fill follows current cell value without changing control geometry or value": bar.width > knobWidth
                && abs((high.width - low.width) - 0.5 * (bar.width - knobWidth)) < 0.01
                && slider.frame == frame && slider.minValue == 0 && slider.maxValue == 1 && slider.doubleValue == 0.75
                && low.height == bar.height && high.height == bar.height
        ]
        result["slider preserved accent raster stays within native bar and follows value"] = rasterTracksMatch(slider: slider, cell: cell, window: window)
        return result
    }

    private static func rasterTracksMatch(slider: NSSlider, cell: ActiveColorsSliderCell,
                                          window: SliderAppearanceVerificationWindow) -> Bool {
        let directory = ProcessInfo.processInfo.environment["AUTOSWITCH_PANEL_RENDER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        func raster(_ appearance: NSAppearance, name: String) -> NSBitmapImageRep? {
            slider.needsDisplay = true
            guard let image = slider.bitmapImageRepForCachingDisplay(in: slider.bounds) else { return nil }
            appearance.performAsCurrentDrawingAppearance { slider.cacheDisplay(in: slider.bounds, to: image) }
            if let directory, let png = image.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? png.write(to: directory.appendingPathComponent("slider-\(name).png"))
            }
            return image
        }
        func differs(_ first: NSColor, _ second: NSColor) -> Bool {
            abs(first.alphaComponent - second.alphaComponent) > 0.1
                || abs(first.redComponent - second.redComponent) > 0.1
                || abs(first.greenComponent - second.greenComponent) > 0.1
                || abs(first.blueComponent - second.blueComponent) > 0.1
        }
        func rows(_ image: NSBitmapImageRep, x: Int, relativeTo reference: NSBitmapImageRep?) -> [Int] {
            guard let background = image.colorAt(x: x, y: 0)?.usingColorSpace(.deviceRGB) else { return [] }
            return (0..<image.pixelsHigh).filter { y in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                let other = reference?.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? background
                return differs(color, other)
            }
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { return false }
            window.appearance = appearance; slider.appearance = appearance
            window.focusedForVerification = false; slider.doubleValue = 0.75
            AudioControlStyle.keepActiveColors = false
            guard let native = raster(appearance, name: "\(appearanceName.rawValue)-inactive-native") else { return false }
            AudioControlStyle.keepActiveColors = true
            guard let preserved = raster(appearance, name: "\(appearanceName.rawValue)-inactive-preserved") else { return false }
            let bar = cell.barRect(flipped: slider.isFlipped)
            let scale = CGFloat(preserved.pixelsWide) / slider.bounds.width
            let probe = Int((bar.minX + bar.width * 0.4) * scale)
            let nativeRows = rows(native, x: probe, relativeTo: nil)
            let changedRows = rows(preserved, x: probe, relativeTo: native)
            guard let nativeMin = nativeRows.min(), let nativeMax = nativeRows.max(),
                  let changedMin = changedRows.min(), let changedMax = changedRows.max(),
                  changedMin >= nativeMin - 1, changedMax <= nativeMax + 1 else {
                print("Slider bar raster height mismatch for \(appearanceName.rawValue): native rows \(nativeRows), changed rows \(changedRows), native bar rect \(bar)")
                return false
            }
            slider.doubleValue = 0.25
            guard let lower = raster(appearance, name: "\(appearanceName.rawValue)-inactive-quarter") else { return false }
            guard !rows(lower, x: probe, relativeTo: preserved).isEmpty else { return false }
            window.focusedForVerification = true
            AudioControlStyle.keepActiveColors = false
            guard let focused = raster(appearance, name: "\(appearanceName.rawValue)-focused-native") else { return false }
            AudioControlStyle.keepActiveColors = true
            guard let focusedPreference = raster(appearance, name: "\(appearanceName.rawValue)-focused-preference") else { return false }
            for fraction in [CGFloat(0.1), 0.4, 0.9] {
                let x = Int((bar.minX + bar.width * fraction) * scale)
                guard rows(focusedPreference, x: x, relativeTo: focused).isEmpty else { return false }
            }
        }
        return true
    }
}

