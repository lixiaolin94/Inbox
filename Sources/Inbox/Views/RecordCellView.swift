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
    private let priorityLabel = FlushLabel(labelWithString: "")
    private let contentField = WrappingContentField()
    private let timeLabel = FlushLabel(labelWithString: "")
    private var priorityLeadingConstraint: NSLayoutConstraint!
    private var priorityWidthConstraint: NSLayoutConstraint!
    private var timeWidthConstraint: NSLayoutConstraint!
    private var contentLeadingConstraint: NSLayoutConstraint!
    private var contentTopConstraint: NSLayoutConstraint!
    private var contentBottomLimit: NSLayoutConstraint!
    private var contentCenterY: NSLayoutConstraint!
    private var minHeightConstraint: NSLayoutConstraint!
    private var timeTrailingConstraint: NSLayoutConstraint!

    /// Fired once per Inline Edit session, when it ends. The owner (row's
    /// content, DB persistence) lives in MainViewController — this view only
    /// reports what happened to the text field.
    var onEditingEnded: ((InlineEditOutcome) -> Void)?
    /// Fired on every keystroke during Inline Edit once the wrapped text's
    /// height may have changed, so the owner can re-measure the row.
    var onEditingHeightChanged: (() -> Void)?

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

        priorityLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        priorityLabel.alignment = .left
        priorityLabel.translatesAutoresizingMaskIntoConstraints = false
        lockSingleLine(priorityLabel)

        let wrappingCell = WrappingTextFieldCell(textCell: "")
        wrappingCell.isEditable = false
        wrappingCell.isSelectable = false
        wrappingCell.isBordered = false
        wrappingCell.drawsBackground = false
        wrappingCell.focusRingType = .none
        wrappingCell.font = .systemFont(ofSize: fontSize)
        contentField.cell = wrappingCell
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
        contentField.setContentHuggingPriority(.required, for: .vertical)

        timeLabel.font = .systemFont(ofSize: fontSize)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        lockSingleLine(timeLabel)

        addSubview(priorityLabel)
        addSubview(contentField)
        addSubview(timeLabel)

        clipsToBounds = true

        priorityLeadingConstraint = priorityLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LayoutChrome.textRail)
        priorityWidthConstraint = priorityLabel.widthAnchor.constraint(equalToConstant: Self.priorityColumnWidth(fontSize: fontSize))
        contentLeadingConstraint = contentField.leadingAnchor.constraint(equalTo: priorityLabel.trailingAnchor, constant: 8)
        // Min pads keep the text off the selection edge; centerY splits any
        // leftover row height so focused blue highlight is even top/bottom.
        contentTopConstraint = contentField.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: pad)
        contentBottomLimit = contentField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad)
        contentCenterY = contentField.centerYAnchor.constraint(equalTo: centerYAnchor)
        minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Preferences.recordRowMinHeight)
        timeWidthConstraint = timeLabel.widthAnchor.constraint(equalToConstant: Self.timeColumnWidth(fontSize: fontSize))
        timeTrailingConstraint = timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -LayoutChrome.contentInset)

        NSLayoutConstraint.activate([
            minHeightConstraint,

            priorityLeadingConstraint,
            priorityLabel.firstBaselineAnchor.constraint(equalTo: contentField.firstBaselineAnchor),
            priorityWidthConstraint,

            contentLeadingConstraint,
            contentTopConstraint,
            contentBottomLimit,
            contentCenterY,
            contentField.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),

            timeTrailingConstraint,
            timeLabel.firstBaselineAnchor.constraint(equalTo: contentField.firstBaselineAnchor),
            timeWidthConstraint
        ])
    }

    override func layout() {
        super.layout()
        pinToWindowRail()
        // Wrapping NSTextField needs a max layout width to report a
        // multi-line intrinsic height for automatic row heights.
        let wrapWidth = contentField.bounds.width
        if wrapWidth > 0, contentField.preferredMaxLayoutWidth != wrapWidth {
            contentField.preferredMaxLayoutWidth = wrapWidth
            invalidateIntrinsicContentSize()
        }
    }

    /// Rebase Priority / time onto All's *text* rail. Skip tiny measurement
    /// passes so a narrow fitting-size doesn't crush the Priority column
    /// and wrap "P2" onto two lines.
    private func pinToWindowRail() {
        let minRow = LayoutChrome.textRail + Self.priorityColumnWidth(fontSize: Preferences.recordFontSize)
            + 8 + 80 + 10 + Self.timeColumnWidth(fontSize: Preferences.recordFontSize)
        guard bounds.width >= minRow else { return }
        let leading = LayoutChrome.leadingConstant(for: self)
        if abs(priorityLeadingConstraint.constant - leading) > 0.5 {
            priorityLeadingConstraint.constant = leading
        }
        let trailing = LayoutChrome.trailingConstant(for: self)
        if abs(timeTrailingConstraint.constant - trailing) > 0.5 {
            timeTrailingConstraint.constant = trailing
        }
    }

    private func lockSingleLine(_ field: NSTextField) {
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.isScrollable = false
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byClipping
        }
    }

    func configure(with record: Record, style: RecordCellStyle = .regular) {
        applyWrapping(for: style)
        applyMetrics(for: style)
        let fontSize = Preferences.recordFontSize
        let contentFont = NSFont.systemFont(ofSize: fontSize)
        let priority = record.priorityValue

        if style == .trash {
            priorityLabel.stringValue = ""
            priorityLabel.isHidden = true
            priorityWidthConstraint.constant = 0
            contentLeadingConstraint.constant = 0
            let timestamp = record.deletedAt ?? record.createdAt
            timeLabel.stringValue = Self.relativeTimeString(fromMillis: timestamp)
            timeLabel.textColor = .secondaryLabelColor
            contentField.attributedStringValue = NSAttributedString(
                string: record.content,
                attributes: [
                    .font: contentFont,
                    .foregroundColor: NSColor.labelColor
                ]
            )
            return
        }

        priorityLabel.isHidden = false
        priorityWidthConstraint.constant = Self.priorityColumnWidth(fontSize: fontSize)
        contentLeadingConstraint.constant = 8
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
        priorityLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        timeLabel.font = .systemFont(ofSize: fontSize)
        priorityWidthConstraint.constant = style == .trash ? 0 : Self.priorityColumnWidth(fontSize: fontSize)
        timeWidthConstraint.constant = Self.timeColumnWidth(fontSize: fontSize)
        contentTopConstraint.constant = pad
        contentBottomLimit.constant = -pad
        minHeightConstraint.constant = style == .trash ? 32 : Preferences.recordRowMinHeight
    }

    private static func priorityColumnWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        return ceil(("P0" as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    private static func timeColumnWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(("Sep 99, 9999" as NSString).size(withAttributes: [.font: font]).width)
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
                cell.usesSingleLineMode = true
                cell.lineBreakMode = .byTruncatingTail
            }
        } else {
            contentField.usesSingleLineMode = false
            contentField.maximumNumberOfLines = 0
            contentField.lineBreakMode = .byWordWrapping
            if let cell = contentField.cell as? NSTextFieldCell {
                cell.wraps = true
                cell.isScrollable = false
                cell.usesSingleLineMode = false
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
        applyWrapping(for: .regular)
        // Drop strikethrough / dimming so the field editor shows plain text.
        let text = contentField.stringValue
        let font = NSFont.systemFont(ofSize: Preferences.recordFontSize)
        contentField.font = font
        contentField.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
        contentField.isEditable = true
        contentField.isSelectable = true
        window?.makeFirstResponder(contentField)
        if let editor = contentField.currentEditor() as? NSTextView {
            configureFieldEditor(editor, font: font)
            let end = editor.string.utf16.count
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        let font = NSFont.systemFont(ofSize: Preferences.recordFontSize)
        if let editor = contentField.currentEditor() as? NSTextView {
            configureFieldEditor(editor, font: font)
        }
    }

    private func configureFieldEditor(_ editor: NSTextView, font: NSFont) {
        editor.font = font
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.textContainerInset = .zero
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineBreakMode = .byWordWrapping
        editor.textContainer?.lineFragmentPadding = 0
        let width = max(contentField.bounds.width, 1)
        editor.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Switches Content back to display-only. Does not by itself move first
    /// responder — the caller (MainViewController) decides whether Row Focus
    /// should reclaim it, per the difference between Esc/Enter (yes) and an
    /// externally-interrupted session (no, don't fight whatever now has
    /// focus).
    func endEditing() {
        contentField.isEditable = false
        contentField.isSelectable = false
        contentField.invalidateIntrinsicContentSize()
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

    /// Live text lives in the field editor; the cell measures it (see
    /// `WrappingTextFieldCell.cellSize`) so the field — and with it the
    /// automatic row height — grows and shrinks with the wrapped lines.
    func controlTextDidChange(_ obj: Notification) {
        contentField.invalidateIntrinsicContentSize()
        onEditingHeightChanged?()
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

    // Shared across every cell configure; DateFormatter is not thread-safe,
    // but these are only touched from the main thread.
    private static let calendar = Calendar.autoupdatingCurrent
    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d"
        return formatter
    }()
    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// Day-granularity created-at: `Today`, `Yesterday`, `MMM d`, or
    /// `MMM d, yyyy` when the year differs from `now`.
    static func relativeTimeString(fromMillis milliseconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? sameYearFormatter : otherYearFormatter).string(from: date)
    }

    // MARK: - UI smoke

    func smokePriorityMinX(in view: NSView?) -> CGFloat {
        priorityLabel.convert(priorityLabel.bounds, to: view).minX
    }

    func smokeTimeMaxX(in view: NSView?) -> CGFloat {
        timeLabel.convert(timeLabel.bounds, to: view).maxX
    }
}

/// Zero field insets so the glyph's left edge is the view's left edge.
final class FlushLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installFlushCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installFlushCell()
    }

    convenience init(labelWithString stringValue: String) {
        self.init(frame: .zero)
        self.stringValue = stringValue
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
    }

    private func installFlushCell() {
        let flush = FlushLabelCell()
        flush.isBezeled = false
        flush.isEditable = false
        flush.drawsBackground = false
        cell = flush
    }
}

private final class FlushLabelCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = rect
        r.origin.x = 0
        r.size.height = min(rect.height, cellSize.height)
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        titleRect(forBounds: rect)
    }
}

/// Wrapping Content field with zero alignment insets so the 10pt pad is
/// the true gap from the selection fill to the glyphs (FlushLabel's trick).
private final class WrappingContentField: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// While editing, stock NSTextField reports a single line height. Ask
    /// the field editor's layout for the wrapped height instead so the
    /// automatic row height follows the text as it is typed.
    override var intrinsicContentSize: NSSize {
        guard let editor = currentEditor() as? NSTextView,
              let container = editor.textContainer,
              let layout = editor.layoutManager else {
            return super.intrinsicContentSize
        }
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, super.intrinsicContentSize.height))
    }
}

/// Field editor for wrapping Content. Stock `NSTextFieldCell` installs a
/// single-line editor even when the display cell wraps, which collapsed
/// Inline Edit into a one-line field. Drawing/size are flush so a focused
/// row's blue highlight has equal top and bottom padding around the text.
private final class WrappingTextFieldCell: NSTextFieldCell {
    /// `titleRect` / `drawingRect` / intrinsic size each call `cellSize`, so
    /// one layout pass measures the same text 3–5 times — and the list
    /// reloads on every keystroke. One entry is enough: the key changes
    /// whenever the cell is recycled, the width changes, or the field
    /// editor's live text changes, and stale entries are simply replaced.
    private struct MeasureKey: Equatable {
        let width: CGFloat
        let text: NSAttributedString
        let pointSize: CGFloat
    }
    private var cachedKey: MeasureKey?
    private var cachedSize = NSSize.zero

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let size = cellSize(forBounds: rect)
        guard rect.height > size.height + 0.5 else { return rect }
        var r = rect
        r.size.height = size.height
        r.origin.y = rect.origin.y + ((rect.height - size.height) / 2).rounded(.toNearestOrAwayFromZero)
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        titleRect(forBounds: rect)
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let width = max(rect.width, 1)
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        guard !usesSingleLineMode else {
            return NSSize(width: width, height: lineHeight)
        }
        // While editing, measure the field editor's live text, not the
        // stale stringValue captured when editing began.
        var measured = attributedStringValue
        if let editor = (controlView as? NSTextField)?.currentEditor() {
            measured = NSAttributedString(string: editor.string, attributes: [.font: font])
        }
        let key = MeasureKey(width: width, text: measured, pointSize: font.pointSize)
        if key == cachedKey { return cachedSize }
        let bounds = measured.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let size = NSSize(width: width, height: max(ceil(bounds.height), lineHeight))
        cachedKey = key
        cachedSize = size
        return size
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        guard !usesSingleLineMode, let textView = editor as? NSTextView else { return editor }
        textView.font = font
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.lineFragmentPadding = 0
        return editor
    }
}
