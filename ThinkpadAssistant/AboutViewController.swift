//
//  AboutViewController.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27.
//  https://github.com/Syuhadak27/ThinkpadAssistent
//

import Foundation
import Cocoa

/// Jendela "Tentang" modern, dibangun sepenuhnya dari kode (tanpa storyboard).
final class AboutViewController: NSViewController {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "Battery Lenovo Assistant")
    private let versionLabel = NSTextField(labelWithString: "")
    private let buildLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: NSLocalizedString("Utilitas menu bar untuk baterai Thinkpad/Lenovo: sinkronisasi batas ngecas, daya langsung, dan pintasan keyboard.", comment: ""))
    private let githubButton = NSButton(title: "github.com/Syuhadak27/BatteryLenovoAssistent", target: nil, action: #selector(openGitHub(_:)))
    private let updatesButton = NSButton(title: NSLocalizedString("Cek Update…", comment: ""), target: nil, action: #selector(checkUpdates(_:)))
    private let copyrightLabel = NSTextField(labelWithString: NSLocalizedString("Hak cipta © 2026 Syuhadak27. Seluruh hak dilindungi.", comment: ""))

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        root.wantsLayer = true
        root.layer?.cornerRadius = 12

        iconView.image = NSImage(named: "menuIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 19, weight: .bold)
        versionLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        buildLabel.font = NSFont.systemFont(ofSize: 11)
        buildLabel.textColor = .tertiaryLabelColor
        descriptionLabel.font = NSFont.systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 3
        copyrightLabel.font = NSFont.systemFont(ofSize: 10)
        copyrightLabel.textColor = .tertiaryLabelColor
        githubButton.bezelStyle = .rounded
        githubButton.target = self
        updatesButton.bezelStyle = .rounded
        updatesButton.target = self

        let stack = NSStackView(views: [
            iconView, nameLabel, versionLabel, buildLabel, descriptionLabel,
            updatesButton, githubButton, copyrightLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let info = Bundle.main.infoDictionary
        versionLabel.stringValue = String(
            format: NSLocalizedString("Versi %@", comment: ""),
            info?["CFBundleShortVersionString"] as? String ?? "—"
        )
        buildLabel.stringValue = String(
            format: NSLocalizedString("Build %@", comment: ""),
            info?["CFBundleVersion"] as? String ?? "—"
        )

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appMovedToBackground),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func appMovedToBackground() {
        view.window?.close()
    }

    @IBAction func openGitHub(_ sender: Any) {
        guard let url = URL(string: "https://github.com/Syuhadak27/BatteryLenovoAssistent") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkUpdates(_ sender: Any) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdatesFromAbout()
    }
}
