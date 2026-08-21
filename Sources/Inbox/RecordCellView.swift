import AppKit

/// Result of an Inline Edit session ending (PRD §8.5).
/// Visual treatment of a Record row. Trash rows drop Priority and dim
/// Content (PRD §12); they are not used on the main surface.
enum RecordCellStyle {
    case regular
    case trash
}

enum InlineEditOutcome {
    /// Enter: the field's text at the moment of commit.
    case commit(String)
    /// Esc: discard, return to Row Focus.
    case cancel
    /// Editing ended some other way (e.g. the user clicked a different
    /// control). Treated like Cancel, but the caller must not fight focus
    /// that's already moving elsewhere.
    case interrupted
}

/// View-based cell for a Record row: Priority label, wrapping Content
/// that can switch into Inline Edit, and a weak relative-time label.
/// Compact, no card, no buttons. Trash cells stay single-line (the Trash
/// table pins row height at 28pt and does not use automatic row heights).
final class RecordCellView: NSTableCellView, NSTextFieldDelegate {
    private let priorityLabel = NSTextField(labelWithString: "")
    private let contentField = NSTextField()
    private let timeLabel = NSTextField(labelWithString: "")
    private var priorityLeadingConstraint: NSLayoutConstraint!
    private var priorityWidthConstraint: NSLayoutConstraint!
    private var contentLeadingConstraint: NSLayoutConstraint!
    private var contentTopConstraint: NSLayoutConstraint!
    private var contentBottomLimit: NSLayoutConstraint!
    private var contentBottomEquality: NSLayoutConstraint!
    private var minHeightConstraint: NSLayoutConstraint!

    /// Fired once per Inline Edit session, when it ends. The owner (row's
    /// content, DB persistence) lives in MainViewController — this view only
    /// reports what happened to the text field.
    var onEditingEnded: ((InlineEditOutcome) -> Void)?

    /// Guards against `controlTextDidEndEditing` re-reporting `.interrupted`
    /// after Enter/Esc already reported `.commit`/`.cancel` for the same
    /// session (ending editing to move focus back to the row still fires
    /// that notification).
    private var didReportExplicitEditEnd = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpViews() {
        let pad = Preferences.recordVerticalPadding
        let fontSize = Preferences.recordFontSize
        let sideFont = max(11, fontSize - 3)

        priorityLabel.font = .monospacedDigitSystemFont(ofSize: sideFont, weight: .semibold)
        priorityLabel.alignment = .center
        priorityLabel.translatesAutoresizingMaskIntoConstraints = false

        contentField.font = .systemFont(ofSize: fontSize)
        contentField.isEditable = false
        contentField.isSelectable = false
        contentField.isBordered = false
        contentField.drawsBackground = false
        contentField.focusRingType = .none
        contentField.delegate = self
        contentField.translatesAutoresizingMaskIntoConstraints = false
        applyWrapping(for: .regular)
        // Low horizontal resistance so wrapping text cannot widen the
        // window (HISTORY: window collapse from fitting-size). Equal
        // trailing gives wrapping a defined width.
        contentField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .systemFont(ofSize: sideFont)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(priorityLabel)
        addSubview(contentField)
        addSubview(timeLabel)

        clipsToBounds = true

        priorityLeadingConstraint = priorityLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        priorityWidthConstraint = priorityLabel.widthAnchor.constraint(equalToConstant: 28)
        contentLeadingConstraint = contentField.leadingAnchor.constraint(equalTo: priorityLabel.trailingAnchor, constant: 10)
        contentTopConstraint = contentField.topAnchor.constraint(equalTo: topAnchor, constant: pad)
        contentBottomLimit = contentField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad)
        // Equality at 750 pulls automatic row height to the wrapped text;
        // it can yield in a pinned Trash row.
        contentBottomEquality = contentField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad)
        contentBottomEquality.priority = .defaultHigh
        minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Preferences.recordRowMinHeight)

        NSLayoutConstraint.activate([
            minHeightConstraint,

            priorityLeadingConstraint,
            priorityLabel.firstBaselineAnchor.constraint(equalTo: contentField.firstBaselineAnchor),
            priorityWidthConstraint,

            contentLeadingConstraint,
            contentTopConstraint,
            contentBottomLimit,
            contentBottomEquality,
            contentField.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            timeLabel.firstBaselineAnchor.constraint(equalTo: contentField.firstBaselineAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 68)
        ])
    }

    override func layout() {
        super.layout()
        // Wrapping NSTextField needs a max layout width to report a
        // multi-line intrinsic height for automatic row heights.
        let wrapWidth = contentField.bounds.width
        if wrapWidth > 0, contentField.preferredMaxLayoutWidth != wrapWidth {
            contentField.preferredMaxLayoutWidth = wrapWidth
            invalidateIntrinsicContentSize()
        }
    }

    func configure(with record: Record, indented: Bool = false, style: RecordCellStyle = .regular) {
        applyWrapping(for: style)
        applyMetrics(for: style)
        let fontSize = Preferences.recordFontSize
        let contentFont = NSFont.systemFont(ofSize: fontSize)
        let priority = record.priorityValue
        priorityLeadingConstraint.constant = indented ? 32 : 16

        if style == .trash {
            priorityLabel.stringValue = ""
            priorityLabel.isHidden = true
            priorityWidthConstraint.constant = 0
            contentLeadingConstraint.constant = 0
            let timestamp = record.deletedAt ?? record.createdAt
            timeLabel.stringValue = Self.relativeTimeString(fromMillis: timestamp)
            timeLabel.textColor = .quaternaryLabelColor
            contentField.attributedStringValue = NSAttributedString(
                string: record.content,
                attributes: [
                    .font: contentFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
            return
        }

        priorityLabel.isHidden = false
        priorityWidthConstraint.constant = 28
        contentLeadingConstraint.constant = 10
        priorityLabel.stringValue = priority.label
        timeLabel.stringValue = Self.relativeTimeString(fromMillis: record.createdAt)

        let resolved = record.status == RecordStatus.resolved.rawValue
        if resolved {
            contentField.attributedStringValue = NSAttributedString(
                string: record.content,
                attributes: [
                    .font: contentFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            priorityLabel.textColor = .tertiaryLabelColor
            timeLabel.textColor = .quaternaryLabelColor
        } else {
            contentField.attributedStringValue = NSAttributedString(
                string: record.content,
                attributes: [
                    .font: contentFont,
                    .foregroundColor: NSColor.labelColor
                ]
            )
            priorityLabel.textColor = Self.color(for: priority)
            timeLabel.textColor = .secondaryLabelColor
        }
    }

    private func applyMetrics(for style: RecordCellStyle) {
        let fontSize = Preferences.recordFontSize
        let pad = style == .trash ? 6 : Preferences.recordVerticalPadding
        let sideFont = max(11, fontSize - 3)
        priorityLabel.font = .monospacedDigitSystemFont(ofSize: sideFont, weight: .semibold)
        timeLabel.font = .systemFont(ofSize: sideFont)
        contentTopConstraint.constant = pad
        contentBottomLimit.constant = -pad
        contentBottomEquality.constant = -pad
        minHeightConstraint.constant = style == .trash ? 32 : Preferences.recordRowMinHeight
    }

    /// Trash keeps a 28pt row and clips; wrapping there fights the pinned
    /// height. Main-list cells wrap so automatic row heights can grow.
    private func applyWrapping(for style: RecordCellStyle) {
        if style == .trash {
            contentField.usesSingleLineMode = true
            contentField.maximumNumberOfLines = 1
            contentField.lineBreakMode = .byTruncatingTail
            if let cell = contentField.cell as? NSTextFieldCell {
                cell.wraps = false
                cell.isScrollable = true
                cell.lineBreakMode = .byTruncatingTail
            }
        } else {
            contentField.usesSingleLineMode = false
            contentField.maximumNumberOfLines = 0
            contentField.lineBreakMode = .byWordWrapping
            if let cell = contentField.cell as? NSTextFieldCell {
                cell.wraps = true
                cell.isScrollable = false
                cell.lineBreakMode = .byWordWrapping
            }
        }
    }

    // MARK: - Inline Edit (PRD §8.5)

    /// Switches Content into an editable field with the caret at the end,
    /// and makes it first responder. Caller is responsible for the row
    /// already being scrolled into view.
    func beginEditing() {
        didReportExplicitEditEnd = false
        // Drop strikethrough / dimming so the field editor shows plain text.
        let text = contentField.stringValue
        contentField.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: Preferences.recordFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        contentField.isEditable = true
        contentField.isSelectable = true
        window?.makeFirstResponder(contentField)
        if let editor = contentField.currentEditor() {
            let end = editor.string.utf16.count
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    /// Switches Content back to display-only. Does not by itself move first
    /// responder — the caller (MainViewController) decides whether Row Focus
    /// should reclaim it, per the difference between Esc/Enter (yes) and an
    /// externally-interrupted session (no, don't fight whatever now has
    /// focus).
    func endEditing() {
        contentField.isEditable = false
        contentField.isSelectable = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // While an IME composition is in progress, Enter/Esc belong to the
        // input method (confirm/cancel the candidate), not to Inline Edit
        // commit/cancel — this is the named risk in PRD §23.2. Let AppKit's
        // normal marked-text handling deal with them instead.
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            didReportExplicitEditEnd = true
            onEditingEnded?(.commit(contentField.stringValue))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            didReportExplicitEditEnd = true
            onEditingEnded?(.cancel)
            return true
        default:
            // Arrow keys, Space, Tab, and every other standard text-editing
            // command fall through to NSTextView's normal handling.
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !didReportExplicitEditEnd else { return }
        onEditingEnded?(.interrupted)
    }

    private static func color(for priority: Priority) -> NSColor {
        switch priority {
        case .p0: return .systemRed
        case .p1: return .systemOrange
        case .p2: return .secondaryLabelColor
        case .p3: return .tertiaryLabelColor
        }
    }

    /// Simple, deliberately coarse rules per PRD §8.1: `now`, `<N>m`, `<N>h`,
    /// `Yesterday`, then a short date.
    static func relativeTimeString(fromMillis milliseconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "\(seconds / 3600)h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
