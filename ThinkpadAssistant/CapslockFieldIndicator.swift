//
//  CapslockFieldIndicator.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//
//  Indikator Caps Lock kecil berwarna biru yang mengambang di ujung kanan
//  textfield yang sedang fokus (di aplikasi apa pun), mirip bawaan macOS.
//

import AppKit
import ApplicationServices

final class CapslockFieldIndicator {

    static let shared = CapslockFieldIndicator()

    // MARK: - State

    private var isCapsLockOn = false
    private var isMonitoring = false
    private var pollTimer: Timer?
    private var permissionChecked = false

    // MARK: - Overlay window

    /// Jendela transparan yang tidak menangani klik mouse, supaya tidak
    /// mengganggu textfield asli di aplikasi lain.
    private lazy var overlayWindow: NSWindow = {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = BadgeView()
        return window
    }()

    private var badgeView: BadgeView? {
        overlayWindow.contentView as? BadgeView
    }

    // MARK: - Public API

    /// Dipanggil saat status monitoring diubah lewat menu.
    func setMonitoringEnabled(_ enabled: Bool) {
        isMonitoring = enabled

        if enabled {
            requestAccessibilityPermissionIfNeeded()
            // Baca status terkini dari IOKit (Capslock.m) supaya indikator
            // langsung benar walaupun tombol ditekan sebelum monitoring aktif.
            isCapsLockOn = getCapslockState()
        } else {
            isCapsLockOn = false
        }

        refresh()
        updateTimer()
    }

    /// Dipanggil dari CapslockMonitor setiap kali tombol Caps Lock ditekan.
    func capsLockStateChanged(_ isOn: Bool) {
        isCapsLockOn = isOn
        refresh()
        updateTimer()
    }

    private init() {}

    // MARK: - Timer

    private func updateTimer() {
        if isMonitoring && isCapsLockOn {
            guard pollTimer == nil else { return }
            // Ikuti pergerakan fokus/kursor textfield selama Caps Lock nyala.
            pollTimer = Timer.scheduledTimer(
                timeInterval: 0.20,
                target: self,
                selector: #selector(poll),
                userInfo: nil,
                repeats: true
            )
            pollTimer?.tolerance = 0.05
            RunLoop.main.add(pollTimer!, forMode: .common)
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    @objc private func poll() {
        // Jaga-jaga kalau event flagsChanged terlewat (misalnya aplikasi
        // tidak menerima event saat di background).
        let current = getCapslockState()
        if current != isCapsLockOn {
            isCapsLockOn = current
            updateTimer()
        }
        refresh()
    }

    // MARK: - Tampil / sembunyi

    private func refresh() {
        guard isMonitoring, isCapsLockOn, accessibilityTrusted,
              let frame = focusedTextFieldFrame() else {
            hide()
            return
        }

        show(at: frame)
    }

    private func show(at textFieldFrame: CGRect) {
        // Ukuran badge mengikuti tinggi textfield, dibatasi agar tetap kecil.
        let size: CGFloat = min(max(textFieldFrame.height - 6, 14), 22)
        let inset: CGFloat = 4
        let x = textFieldFrame.maxX - size - inset
        let y = textFieldFrame.minY + (textFieldFrame.height - size) / 2
        let frame = CGRect(x: x, y: y, width: size, height: size)

        badgeView?.needsDisplay = true
        if overlayWindow.isVisible {
            overlayWindow.setFrame(frame, display: true)
        } else {
            overlayWindow.setFrame(frame, display: true)
            overlayWindow.orderFrontRegardless()
        }
    }

    private func hide() {
        if overlayWindow.isVisible {
            overlayWindow.orderOut(nil)
        }
    }

    // MARK: - Accessibility

    private var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !permissionChecked, !AXIsProcessTrusted() else { return }
        permissionChecked = true

        // Memunculkan prompt sistem sekali saat fitur diaktifkan.
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Mencari frame (koordinat AppKit, origin kiri-bawah) dari textfield
    /// yang sedang fokus di aplikasi terdepan.
    private func focusedTextFieldFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success else { return nil }

        // AXUIElement adalah CFType; pastikan tipenya benar sebelum dipakai.
        guard let element = focusedValue else { return nil }
        let axElement: AXUIElement = Unmanaged<AXUIElement>
            .fromOpaque(element as! UnsafeRawPointer)
            .takeUnretainedValue()

        // Hanya tampilkan pada elemen teks yang bisa menerima input.
        // Field password (secure) juga memakai role AXTextField di macOS.
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String,
              [kAXTextFieldRole as String, kAXTextAreaRole as String].contains(role) else { return nil }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let position = positionValue,
              let size = sizeValue else { return nil }

        var axPoint = CGPoint.zero
        var axSize = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &axPoint),
              AXValueGetValue(size as! AXValue, .cgSize, &axSize) else { return nil }

        // Koordinat Accessibility memakai origin kiri-atas seluruh screen;
        // AppKit memakai kiri-bawah. Hitung dari union semua frame screen agar
        // benar juga saat memakai lebih dari satu monitor.
        let screensUnion = NSScreen.screens.reduce(CGRect.zero) { union, screen in
            union.union(screen.frame)
        }
        let converted = CGRect(
            x: axPoint.x - screensUnion.minX,
            y: screensUnion.maxY - axPoint.y - axSize.height,
            width: axSize.width,
            height: axSize.height
        )

        // Pastikan field berada di screen yang sedang dipakai dan memiliki
        // ukuran wajar (abaikan elemen AX "dummy" dengan frame 0).
        guard converted.width >= 20, converted.height >= 12,
              NSScreen.screens.contains(where: { $0.frame.intersects(converted) }) else { return nil }

        return converted
    }
}

// MARK: - Badge view

private final class BadgeView: NSView {

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let glyph = "⇪" // U+21EA: UPWARDS WHITE ARROW FROM BAR
        let fontSize = min(bounds.height, 20)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.9),
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }()
        ]

        let text = NSAttributedString(string: glyph, attributes: attributes)
        let textSize = text.size()
        let origin = NSPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        text.draw(at: origin)
    }
}
