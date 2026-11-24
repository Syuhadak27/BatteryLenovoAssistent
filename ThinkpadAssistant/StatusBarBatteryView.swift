//
//  StatusBarBatteryView.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//
//  Header status baterai di dropdown menu bar: ikon + persen + status + bar.
//

import AppKit

final class StatusBarBatteryView: NSView {

    private let iconImageView = NSImageView()
    private let percentLabel = NSTextField(labelWithString: "…")
    private let stateLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()

    var percent: Int = 0 {
        didSet {
            percentLabel.textColor = percent <= 20
                ? .systemRed
                : (percent <= 40 ? .systemOrange : .labelColor)
        }
    }

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

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        percentLabel.textColor = .labelColor
        percentLabel.lineBreakMode = .byTruncatingTail

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
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
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 22),
            iconImageView.heightAnchor.constraint(equalToConstant: 22),

            percentLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            percentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            stateLabel.leadingAnchor.constraint(equalTo: percentLabel.leadingAnchor),
            stateLabel.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 0),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            progressBar.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    func update(percent: Int, state: String) {
        self.percent = percent
        percentLabel.stringValue = "\(percent)%"
        stateLabel.stringValue = state
        progressBar.doubleValue = Double(percent)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 42)
    }
}
