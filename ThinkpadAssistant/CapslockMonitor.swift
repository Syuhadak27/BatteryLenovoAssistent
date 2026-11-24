//
//  CapslockMonitor.swift
//  ThinkpadAssistant
//
//  Created by Igor Kulman on 22/06/2020.
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//

import Cocoa
import Foundation

final class CapslockMonitor {
    private static  var lastState: Bool? = nil
    private(set) static var isActive: Bool {
        get {
            UserDefaults.standard.bool(forKey: "CapslockMonitoringEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "CapslockMonitoringEnabled")
        }
    }

    static func register() {
        // get initial capslock state
        lastState = getCapslockState()

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsChanged)
    }

    static func start() {
        isActive = true
        CapslockFieldIndicator.shared.setMonitoringEnabled(true)
    }

    static func stop() {
        isActive = false
        CapslockFieldIndicator.shared.setMonitoringEnabled(false)
    }

    private static func flagsChanged(with event: NSEvent) {
        let isEnabled = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.capsLock)
        guard isActive else {
            lastState = isEnabled
            return
        }

        if isEnabled != lastState {
            CapslockFieldIndicator.shared.capsLockStateChanged(isEnabled)
        }
        lastState = isEnabled
    }
}
