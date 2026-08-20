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

/// View-based cell for a Record row: Priority label, single-line Content
/// that can switch into Inline Edit, and a weak relative-time label.
/// Compact, no card, no buttons.
final class RecordCellView: NSTableCellView, NSTextFieldDelegate {
    private let priorityLabel = NSTextField(labelWithString: "")
    private let contentField = NSTextField()
    private let timeLabel = NSTextField(labelWithString: "")
    private var priorityLeadingConstraint: NSLayoutConstraint!
    private var priorityWidthConstraint: NSLayoutConstraint!
    private var contentLeadingConstraint: NSLayoutConstraint!

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
        priorityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        priorityLabel.alignment = .center
        priorityLabel.translatesAutoresizingMaskIntoConstraints = false

        contentField.font = .systemFont(ofSize: 13)
        contentField.lineBreakMode = .byTruncatingTail
        contentField.isEditable = false
        contentField.isSelectable = false
        contentField.isBordered = false
        contentField.drawsBackground = false
        contentField.focusRingType = .none
        contentField.delegate = self
        contentField.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(priorityLabel)
        addSubview(contentField)
        addSubview(timeLabel)

        priorityLeadingConstraint = priorityLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        priorityWidthConstraint = priorityLabel.widthAnchor.constraint(equalToConstant: 26)
        contentLeadingConstraint = contentField.leadingAnchor.constraint(equalTo: priorityLabel.trailingAnchor, constant: 8)

        NSLayoutConstraint.activate([
            priorityLeadingConstraint,
            priorityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            priorityWidthConstraint,

            contentLeadingConstraint,
            contentField.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentField.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 64)
        ])
    }

    func configure(with record: Record, indented: Bool = false, style: RecordCellStyle = .regular) {
        let priority = record.priorityValue
        priorityLeadingConstraint.constant = indented ? 28 : 12

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
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
            return
        }

        priorityLabel.isHidden = false
        priorityWidthConstraint.constant = 26
        contentLeadingConstraint.constant = 8
        priorityLabel.stringValue = priority.label
        timeLabel.stringValue = Self.relativeTimeString(fromMillis: record.createdAt)

        let resolved = record.status == RecordStatus.resolved.rawValue
        let contentFont = NSFont.systemFont(ofSize: 13)
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
                .font: NSFont.systemFont(ofSize: 13),
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
