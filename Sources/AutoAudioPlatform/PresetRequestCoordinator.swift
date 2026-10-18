import Foundation
import AutoAudioCore

/// Owns menu preset work; current rendering and command authority remain with MenuBar.
@MainActor final class PresetRequestCoordinator {
    struct Context {
        var profileID: String?
        var folderConfigured: Bool
        var commandAvailable: Bool
        var panelVisible: Bool
        var panelClosing: Bool
        var applicationHidden: Bool
        var targetReady: Bool
        var targetProfileID: String?
    }

    private let context: () -> Context
    private let beginFeedback: () -> Int?
    private let reportFeedback: (Int, String?) -> Void
    private let onChange: () -> Void
    // Deliver completion inside the command owner's lifetime, including reply handling.
    private let perform: (ControllerRequest, @escaping (ControllerReply) -> Void) async -> Void
    private(set) var snapshot: PresetSnapshot?
    private var generation = 0
    private(set) var inFlight = false
    private(set) var task: Task<Void, Never>?
    private(set) var refreshPending = false

    init(context: @escaping () -> Context, beginFeedback: @escaping () -> Int?,
         reportFeedback: @escaping (Int, String?) -> Void, onChange: @escaping () -> Void,
         perform: @escaping (ControllerRequest, @escaping (ControllerReply) -> Void) async -> Void) {
        self.context = context
        self.beginFeedback = beginFeedback
        self.reportFeedback = reportFeedback
        self.onChange = onChange
        self.perform = perform
    }

    func invalidate() {
        generation += 1
        inFlight = false
        snapshot = nil
        refreshPending = false
        // Invalidation rejects obsolete replies; it does not cancel dispatched work.
    }

    func discardQueuedRefresh() { refreshPending = false }

    func updateSnapshot(_ value: PresetSnapshot) {
        snapshot = value
        onChange()
        drainReadinessRefresh()
    }

    func requestRefresh() {
        let current = context()
        guard let id = current.profileID, current.folderConfigured, current.commandAvailable,
              !inFlight, snapshot?.busy != true else { return }
        refreshPending = false
        start(.init(command: .presets, profileID: id))
    }

    func requestChange(_ path: String) -> Bool {
        let current = context()
        guard let value = snapshot, value.profileID == current.profileID,
              value.ready, !value.busy, !inFlight, current.commandAvailable,
              let entry = value.entries.first(where: { $0.path == path && $0.available }) else { return false }
        start(.init(command: .preset, profileID: value.profileID, presetPath: path, presetImpact: entry.impact))
        return true
    }

    func readinessChanged(becameReady: Bool) {
        let current = context()
        if becameReady, current.panelVisible, !current.panelClosing, !current.applicationHidden {
            refreshPending = true
        }
        drainReadinessRefresh()
    }

    func prepareMenu() async -> Bool {
        let initial = context()
        guard !initial.panelClosing, !initial.applicationHidden, let id = initial.profileID,
              initial.commandAvailable, !inFlight, snapshot?.busy != true else { return false }
        requestRefresh()
        let openingGeneration = generation
        await task?.value
        let current = context()
        return openingGeneration == generation && !current.panelClosing && !current.applicationHidden
            && current.profileID == id && current.commandAvailable
            && snapshot?.ready == true && snapshot?.busy == false
            && snapshot?.entries.contains(where: \.available) == true
    }

    private func start(_ request: ControllerRequest) {
        guard let feedbackGeneration = beginFeedback() else { return }
        generation += 1
        let requestGeneration = generation
        inFlight = true
        onChange()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform(request) { reply in
                self.finish(request, reply: reply, generation: requestGeneration,
                            feedbackGeneration: feedbackGeneration)
            }
        }
    }

    private func finish(_ request: ControllerRequest, reply: ControllerReply,
                        generation requestGeneration: Int, feedbackGeneration: Int) {
        guard requestGeneration == generation else { return }
        inFlight = false
        guard context().profileID == request.profileID else { onChange(); return }
        if let value = reply.presets { snapshot = value }
        reportFeedback(feedbackGeneration, reply.error)
        onChange()
        drainReadinessRefresh()
    }

    private func drainReadinessRefresh() {
        let current = context()
        guard refreshPending, current.panelVisible, !current.panelClosing, !current.applicationHidden,
              current.targetReady, current.targetProfileID == current.profileID else { return }
        // Consume only when a read starts, so blocked recovery coalesces without idle retries.
        requestRefresh()
    }
}
