import Foundation
import AutoAudioCore

@MainActor func runDiagnosticsChecks() throws {
    var clock = 10.0
    let history = SessionTransitionTimings(capacity: 2, now: { clock })
    history.begin("dsp", label: "DSP startup")
    clock = 11
    history.begin("dsp", label: "DSP startup")
    clock = 12
    history.finish("dsp", outcome: "ready")
    try check(history.samples.first?.seconds == 2, "Repeated lifecycle events do not restart timing")
    history.finish("dsp", outcome: "duplicate")
    try check(history.samples.count == 1, "Duplicate settlement adds no timing sample")
    history.begin("gui", label: "GUI startup")
    clock = 13
    history.begin("gui", label: "GUI shutdown")
    try check(history.samples.last?.outcome == "superseded" && history.samples.last?.seconds == 1,
              "A replacement operation settles the old duration honestly")
    clock = 14
    try check(history.diagnosticText.contains("GUI shutdown: 1.000 s (in progress)"), "Ongoing timing is calculated on demand")
    history.finish("gui", outcome: "stopped")
    try check(history.samples.count == 2 && history.samples.first?.label == "GUI startup", "Timing history remains bounded")
    let count = history.samples.count
    clock = 500
    try check(history.samples.count == count && !history.diagnosticText.contains("in progress"), "Idle history has no pending monitoring work")
    try check(ApplicationMetadata.version != "5.9" && !ApplicationMetadata.copyright.isEmpty, "Application version and credit are explicit app metadata")
    try check(ApplicationMetadata.name == "CamillaCompanion"
        && ApplicationMetadata.description == "A macOS companion for CamillaDSP.",
        "App branding is explicit and identifies CamillaDSP")
    print("Diagnostics checks: event timing, supersession, bounded history and metadata passed")
}
