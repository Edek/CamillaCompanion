import Foundation
import AutoAudioCore
import AutoAudioPlatform

@MainActor func runPresetFileDuplicationChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("preset-copy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Original.yml")
    let bytes = Data("""
    title: Original
    devices:
      capture: {type: CoreAudio, device: input, channels: 2}
      playback: {type: CoreAudio, device: output, channels: 2}
    filters:
      correction:
        type: Conv
        parameters: {filename: coefficients.wav}
    """.utf8)
    try bytes.write(to: source)
    let coefficient = root.appendingPathComponent("coefficients.wav")
    let coefficientBytes = Data([1, 2, 3, 4]); try coefficientBytes.write(to: coefficient)
    let destination = root.appendingPathComponent("My Copy.yaml")
    _ = try PresetFileDuplication.copy(source: source, to: destination)
    let sourceAfter = try Data(contentsOf: source), copiedBytes = try Data(contentsOf: destination)
    let coefficientAfter = try Data(contentsOf: coefficient)
    try check(sourceAfter == bytes && copiedBytes == bytes,
              "Preset duplication preserves original and copied DSP settings exactly")
    try check(coefficientAfter == coefficientBytes,
              "Relative coefficient resources remain in the same context without edits")
    do {
        _ = try PresetFileDuplication.copy(source: source, to: destination)
        throw SwitcherError.message("CHECK FAILED: Preset duplication overwrote an existing file")
    } catch let error as SwitcherError {
        try check(!error.localizedDescription.contains("CHECK FAILED"), "Existing preset copy is refused")
    }
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let relocated = elsewhere.appendingPathComponent("Copy.yml")
    do {
        _ = try PresetFileDuplication.copy(source: source, to: relocated)
        throw SwitcherError.message("CHECK FAILED: Preset duplication changed resource directory")
    } catch let error as SwitcherError {
        try check(!error.localizedDescription.contains("CHECK FAILED"), "Moving relative resources is refused")
    }
    try check(!FileManager.default.fileExists(atPath: relocated.path), "Rejected copy creates no destination")

    var saves = 0
    let draft = InterfaceProfileDraft(name: "Copy profile", configurationPath: source.path,
        triggerUID: "output", captureUID: "input", playbackUID: "output")
    let editor = InterfaceProfileEditor(draft: draft, devices: [], savedProfiles: [], refresh: { [] }, onSave: { _ in saves += 1 })
    let selectedCopy = root.appendingPathComponent("Selected copy.yml")
    try editor.duplicateForVerification(to: selectedCopy)
    let edited = editor.draftForVerification
    try check(edited.configurationPath == selectedCopy.path && edited.captureUID == "input"
              && edited.playbackUID == "output" && edited.triggerUID == "output" && saves == 0,
              "Duplicating selects the copy only in the unsaved draft and preserves device choices")
    editor.close()
}
