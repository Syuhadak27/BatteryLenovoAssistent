//
//  SettingsViewController.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//
//  Panel pengaturan dengan 3 tab: Baterai, Umum, Tentang.
//

import AppKit

protocol SettingsDelegate: AnyObject {
    var chargeStart: Int { get }
    var chargeStop: Int { get }
    var thresholdEnabled: Bool { get }
    var ecDirectEnabled: Bool { get }
    var ecStartOffset: UInt8? { get }
    var ecStopOffset: UInt8? { get }
    var ecInhibitOffset: UInt8? { get }
    var capsLockMonitoring: Bool { get }
    var launchAtLogin: Bool { get }
    @MainActor var automaticUpdates: Bool { get }

    func settingsSetChargeStart(_ value: Int)
    func settingsSetChargeStop(_ value: Int)
    func settingsSetThresholdEnabled(_ enabled: Bool)
    func settingsSetECDirectEnabled(_ enabled: Bool)
    func settingsSetECOffsets(start: UInt8?, stop: UInt8?, inhibit: UInt8?)
    func settingsSetCapsLockMonitoring(_ enabled: Bool)
    func settingsSetLaunchAtLogin(_ enabled: Bool)
    @MainActor func settingsSetAutomaticUpdates(_ enabled: Bool)
    func settingsCheckForUpdates()
    func settingsRefreshBattery()
}

final class SettingsViewController: NSViewController {

    weak var delegate: SettingsDelegate?

    private let tabs = NSSegmentedControl(labels: [
        NSLocalizedString("Baterai", comment: ""),
        NSLocalizedString("Umum", comment: ""),
        NSLocalizedString("Tentang", comment: ""),
    ], trackingMode: .selectOne, target: nil, action: #selector(tabChanged(_:)))

    private let container = NSView()
    private let batteryTab = BatterySettingsView()
    private let generalTab = GeneralSettingsView()
    private let aboutTab = AboutSettingsView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.segmentStyle = .texturedRounded
        view.addSubview(tabs)

        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])

        for tab in [batteryTab, generalTab, aboutTab] {
            tab.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tab)
            NSLayoutConstraint.activate([
                tab.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tab.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                tab.topAnchor.constraint(equalTo: container.topAnchor),
                tab.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        batteryTab.delegate = delegate
        generalTab.delegate = delegate
        aboutTab.delegate = delegate
        selectTab(0)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
    }

    private func selectTab(_ index: Int) {
        batteryTab.isHidden = index != 0
        generalTab.isHidden = index != 1
        aboutTab.isHidden = index != 2
    }

    @MainActor func reload() {
        batteryTab.reload()
        generalTab.reload()
        aboutTab.reload()
    }
}

// MARK: - Base tab view

class SettingsTabView: NSView {
    weak var delegate: SettingsDelegate?

    @MainActor func reload() {}
}

// MARK: - Battery tab

final class BatterySettingsView: SettingsTabView {

    private let startPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stopPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let enabledCheck = NSButton(checkboxWithTitle: NSLocalizedString("Nyalain batas ngecas", comment: ""), target: nil, action: #selector(toggleEnabled(_:)))
    private let ecDirectCheck = NSButton(checkboxWithTitle: NSLocalizedString("EC langsung (ACPI WE1B)", comment: ""), target: nil, action: #selector(toggleECDirect(_:)))
    private let startField = NSTextField()
    private let stopField = NSTextField()
    private let inhibitField = NSTextField()
    private let applyECOffsetsButton = NSButton(title: NSLocalizedString("Simpan Offset EC", comment: ""), target: nil, action: #selector(applyECOffsets(_:)))
    private let refreshButton = NSButton(title: NSLocalizedString("Refresh Status", comment: ""), target: nil, action: #selector(refresh(_:)))
    private let hintLabel = NSTextField(labelWithString: NSLocalizedString("Offset dalam hex 0x01–0x99. Kosongkan atau isi 0 untuk menghapus.", comment: ""))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    private func buildUI() {
        for value in stride(from: 0, through: 100, by: 5) {
            startPopup.addItem(withTitle: "\(value)%")
            stopPopup.addItem(withTitle: "\(value)%")
        }
        startPopup.target = self
        startPopup.action = #selector(changeStart(_:))
        stopPopup.target = self
        stopPopup.action = #selector(changeStop(_:))
        enabledCheck.target = self
        ecDirectCheck.target = self

        for field in [startField, stopField, inhibitField] {
            field.placeholderString = "0x00"
            field.font = NSFont.systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
        }

        applyECOffsetsButton.bezelStyle = .rounded
        refreshButton.bezelStyle = .rounded

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping

        let startRow = labeledRow(label: NSLocalizedString("Mulai ngecas", comment: ""), control: startPopup)
        let stopRow = labeledRow(label: NSLocalizedString("Stop ngecas", comment: ""), control: stopPopup)
        let ecRow1 = labeledRow(label: "Start:", control: startField)
        let ecRow2 = labeledRow(label: "Stop:", control: stopField)
        let ecRow3 = labeledRow(label: "Inhibit:", control: inhibitField)

        let stack = NSStackView(views: [
            startRow, stopRow, enabledCheck, ecDirectCheck,
            ecRow1, ecRow2, ecRow3, hintLabel, applyECOffsetsButton, refreshButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
        for row in [startRow, stopRow, ecRow1, ecRow2, ecRow3] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func labeledRow(label: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: label)
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.widthAnchor.constraint(equalToConstant: 130),
            control.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @MainActor override func reload() {
        guard let d = delegate else { return }
        startPopup.selectItem(withTitle: "\(d.chargeStart)%")
        stopPopup.selectItem(withTitle: "\(d.chargeStop)%")
        enabledCheck.state = d.thresholdEnabled ? .on : .off
        ecDirectCheck.state = d.ecDirectEnabled ? .on : .off
        startField.stringValue = d.ecStartOffset.map { String(format: "0x%02X", $0) } ?? ""
        stopField.stringValue = d.ecStopOffset.map { String(format: "0x%02X", $0) } ?? ""
        inhibitField.stringValue = d.ecInhibitOffset.map { String(format: "0x%02X", $0) } ?? ""
    }

    @objc private func changeStart(_ sender: NSPopUpButton) {
        delegate?.settingsSetChargeStart(indexToPercent(sender.indexOfSelectedItem))
    }

    @objc private func changeStop(_ sender: NSPopUpButton) {
        delegate?.settingsSetChargeStop(indexToPercent(sender.indexOfSelectedItem))
    }

    private func indexToPercent(_ index: Int) -> Int { index * 5 }

    @objc private func toggleEnabled(_ sender: NSButton) {
        delegate?.settingsSetThresholdEnabled(sender.state == .on)
    }

    @objc private func toggleECDirect(_ sender: NSButton) {
        delegate?.settingsSetECDirectEnabled(sender.state == .on)
    }

    @objc private func applyECOffsets(_ sender: Any) {
        delegate?.settingsSetECOffsets(start: parse(startField), stop: parse(stopField), inhibit: parse(inhibitField))
        reload()
    }

    @objc private func refresh(_ sender: Any) {
        delegate?.settingsRefreshBattery()
        reload()
    }

    private func parse(_ field: NSTextField) -> UInt8? {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
        guard !hex.isEmpty, let value = Int(hex, radix: 16), (1...0x99).contains(value) else { return nil }
        return UInt8(value)
    }
}

// MARK: - General tab

final class GeneralSettingsView: SettingsTabView {

    private let capsCheck = NSButton(checkboxWithTitle: NSLocalizedString("Pantau Caps Lock", comment: ""), target: nil, action: #selector(toggleCaps(_:)))
    private let loginCheck = NSButton(checkboxWithTitle: NSLocalizedString("Nyala pas login", comment: ""), target: nil, action: #selector(toggleLogin(_:)))
    private let updatesCheck = NSButton(checkboxWithTitle: NSLocalizedString("Cek update otomatis", comment: ""), target: nil, action: #selector(toggleUpdates(_:)))
    private let checkNowButton = NSButton(title: NSLocalizedString("Cek Update Sekarang…", comment: ""), target: nil, action: #selector(checkNow(_:)))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    private func buildUI() {
        capsCheck.target = self
        loginCheck.target = self
        updatesCheck.target = self
        checkNowButton.bezelStyle = .rounded
        checkNowButton.target = self

        let note = NSTextField(labelWithString: NSLocalizedString("Pantau Caps Lock menampilkan pemberitahuan saat tombol Caps Lock ditekan. Izin Accessibility tidak diperlukan untuk popup.", comment: ""))
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [capsCheck, loginCheck, updatesCheck, checkNowButton, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @MainActor override func reload() {
        guard let d = delegate else { return }
        capsCheck.state = d.capsLockMonitoring ? .on : .off
        loginCheck.state = d.launchAtLogin ? .on : .off
        updatesCheck.state = d.automaticUpdates ? .on : .off
    }

    @objc private func toggleCaps(_ sender: NSButton) {
        delegate?.settingsSetCapsLockMonitoring(sender.state == .on)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        delegate?.settingsSetLaunchAtLogin(sender.state == .on)
    }

    @objc private func toggleUpdates(_ sender: NSButton) {
        delegate?.settingsSetAutomaticUpdates(sender.state == .on)
    }

    @objc private func checkNow(_ sender: Any) {
        delegate?.settingsCheckForUpdates()
    }
}

// MARK: - About tab

final class AboutSettingsView: SettingsTabView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "Battery Lenovo Assistant")
    private let versionLabel = NSTextField(labelWithString: "")
    private let buildLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: NSLocalizedString("Utilitas menu bar untuk baterai Thinkpad/Lenovo: sinkronisasi batas ngecas, daya langsung, dan pintasan keyboard.", comment: ""))
    private let githubButton = NSButton(title: "github.com/Syuhadak27/BatteryLenovoAssistent", target: nil, action: #selector(openGitHub(_:)))
    private let copyrightLabel = NSTextField(labelWithString: NSLocalizedString("Hak cipta © 2026 Syuhadak27. Seluruh hak dilindungi.", comment: ""))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    private func buildUI() {
        iconView.image = NSImage(named: "menuIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
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

        let stack = NSStackView(views: [iconView, nameLabel, versionLabel, buildLabel, descriptionLabel, githubButton, copyrightLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.9),
        ])
    }

    @MainActor override func reload() {
        let info = Bundle.main.infoDictionary
        versionLabel.stringValue = String(
            format: NSLocalizedString("Versi %@", comment: ""),
            info?["CFBundleShortVersionString"] as? String ?? "—"
        )
        buildLabel.stringValue = String(
            format: NSLocalizedString("Build %@", comment: ""),
            info?["CFBundleVersion"] as? String ?? "—"
        )
    }

    @objc private func openGitHub(_ sender: Any) {
        guard let url = URL(string: "https://github.com/Syuhadak27/BatteryLenovoAssistent") else { return }
        NSWorkspace.shared.open(url)
    }
}
