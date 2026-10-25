import AppKit
import AutoAudioCore
import AutoAudioPlatform

@MainActor enum InterfaceDeviceBrowserVerification {
    static func checks() -> [String: Bool] {
        _ = NSApplication.shared
        let inputOnly = AudioDevice(uid: "input-only", name: "Input Only", inputChannels: 2, outputChannels: 0)
        let outputOnly = AudioDevice(uid: "output-only", name: "Output Only", inputChannels: 0, outputChannels: 2)
        let firstNamedOutput = AudioDevice(uid: "usb-a", name: "USB Interface", inputChannels: 0, outputChannels: 2)
        let secondNamedOutput = AudioDevice(uid: "usb-b", name: "USB Interface", inputChannels: 0, outputChannels: 4)
        let duplex = AudioDevice(uid: "duplex", name: "Duplex Interface", inputChannels: 2, outputChannels: 2)
        let inventory = [inputOnly, outputOnly, firstNamedOutput, secondNamedOutput, duplex]

        var selectedUIDs: [String] = []
        let browser = InterfaceDeviceBrowser(devices: inventory, selectedUID: "offline-saved",
            role: .dspInput, savedUIDs: ["offline-saved"], refresh: { inventory },
            onSelect: { selectedUIDs.append($0) })

        let visibleAllDevices = Set(browser.visibleUIDsForVerification) == Set([
            "input-only", "output-only", "usb-a", "usb-b", "duplex", "offline-saved"
        ])
        let sameNameUIDsRemainDistinct = browser.visibleUIDsForVerification.filter { $0 == "usb-a" || $0 == "usb-b" }.count == 2
        let offlineInitiallyRetained = browser.selectedUIDForVerification == "offline-saved"
            && !browser.chooseEnabledForVerification
            && browser.displayedReasonForVerification.localizedCaseInsensitiveContains("offline")
        browser.refreshForVerification()
        let offlineSurvivesRefresh = browser.selectedUIDForVerification == "offline-saved"
            && browser.visibleUIDsForVerification.contains("offline-saved")
            && !browser.chooseEnabledForVerification
        let noImplicitSelectionCallback = selectedUIDs.isEmpty
        let expectedColumns = browser.columnTitlesForVerification == [
            "Device", "Input channels", "Output channels", "Availability"
        ]
        let columnsFit = browser.columnWidthsFitForVerification(680)

        browser.selectUIDForVerification("output-only")
        let wrongDirectionVisibleButDisabled = browser.selectedUIDForVerification == "output-only"
            && !browser.chooseEnabledForVerification
            && !browser.displayedReasonForVerification.isEmpty
        browser.chooseForVerification()
        let disabledChooseDoesNotCallBack = selectedUIDs.isEmpty

        browser.selectUIDForVerification("input-only")
        let compatibleCanBeChosen = browser.chooseEnabledForVerification
        let choosingOnlyCallsBack = selectedUIDs.isEmpty
        browser.chooseForVerification()
        let callbackWaitsForChoose = choosingOnlyCallsBack && selectedUIDs == ["input-only"]

        return [
            "All current devices remain visible, including wrong-direction rows": visibleAllDevices && wrongDirectionVisibleButDisabled,
            "Same-name devices keep distinct UID rows": sameNameUIDsRemainDistinct,
            "Saved offline selection remains selected after refresh and cannot be chosen": offlineInitiallyRetained && offlineSurvivesRefresh,
            "Choose is disabled for incompatible devices and enabled for a compatible device": disabledChooseDoesNotCallBack && compatibleCanBeChosen,
            "Selection and refresh do not invoke the selection callback": noImplicitSelectionCallback && disabledChooseDoesNotCallBack,
            "Only explicit Choose invokes the selection callback": callbackWaitsForChoose,
            "Browser has the four requested columns": expectedColumns,
            "Four browser columns fit within a 680 point window": columnsFit
        ]
    }
}
