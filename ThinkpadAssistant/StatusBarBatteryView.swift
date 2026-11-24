//
//  StatusBarBatteryView.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//
//  Header menu bar: ikon baterai + persentase + status + progress bar (hijau).
//

import AppKit

final class StatusBarBatteryView: NSView {

    private let iconImageView = NSImageView()
    private let percentLabel = NSTextField(labelWithString: "…")
    private let stateLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    private func buildUI() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        if #available(macOS 11.0, *) {
            iconImageView.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil)
        } else {
            iconImageView.image = NSImage(named: NSImage.Name("NSBatteryTemplate"))
        }
        iconImageView.contentTintColor = .systemGreen

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        percentLabel.textColor = .systemGreen
        percentLabel.lineBreakMode = .byTruncatingTail

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = .systemGreen
        stateLabel.lineBreakMode = .byTruncatingTail

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isBezeled = false

        addSubview(iconImageView)
        addSubview(percentLabel)
        addSubview(stateLabel)
        addSubview(progressBar)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 22),
            iconImageView.heightAnchor.constraint(equalToConstant: 22),

            percentLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            percentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            stateLabel.leadingAnchor.constraint(equalTo: percentLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: percentLabel.bottomAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    func update(percent: Int, state: String) {
        percentLabel.stringValue = "\(percent)%"
        stateLabel.stringValue = state
        progressBar.doubleValue = Double(percent)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 42)
    }
}
