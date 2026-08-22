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
/// that can switch into Inline Edit, and a weak date label. Compact, no
/// card, no buttons. Trash cells stay single-line. Row heights are not
/// automatic: the tables ask `displayHeight(for:style:tableWidth:)`, which
/// measures with the same cell class the row draws with.
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
        timeLabel.textColor = Theme.Ink.secondary
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        lockSingleLine(timeLabel)

        addSubview(priorityLabel)
        addSubview(contentField)
        addSubview(timeLabel)

        clipsToBounds = true

        priorityLeadingConstraint = priorityLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Size.textRail)
        priorityWidthConstraint = priorityLabel.widthAnchor.constraint(equalToConstant: Self.priorityColumnWidth(fontSize: fontSize))
        contentLeadingConstraint = contentField.leadingAnchor.constraint(equalTo: priorityLabel.trailingAnchor, constant: 8)
        // Min pads keep the text off the selection edge; centerY splits any
        // leftover row height so the selection block is even top/bottom.
        contentTopConstraint = contentField.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: pad)
        contentBottomLimit = contentField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad)
        contentCenterY = contentField.centerYAnchor.constraint(equalTo: centerYAnchor)
        minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: Preferences.recordRowMinHeight)
        timeWidthConstraint = timeLabel.widthAnchor.constraint(equalToConstant: Self.timeColumnWidth(fontSize: fontSize))
        timeTrailingConstraint = timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Size.timeRail)

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
        // multi-line intrinsic height (the cell's fitting height).
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
        let minRow = Theme.Size.textRail + Self.priorityColumnWidth(fontSize: Preferences.recordFontSize)
            + 8 + 80 + 10 + Self.timeColumnWidth(fontSize: Preferences.recordFontSize)
        guard bounds.width >= minRow else { return }
        let leading = Theme.Size.leadingConstant(for: self)
        if abs(priorityLeadingConstraint.constant - leading) > 0.5 {
            priorityLeadingConstraint.constant = leading
        }
        let trailing = Theme.Size.trailingConstant(for: self, inset: Theme.Size.timeRail)
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

    /// `isConflicted`: the row is one half of an unresolved conflict pair
    /// (PRD §15.3). The weak badge takes the time column's place so row
    /// height and the trailing rail are unchanged.
    func configure(with record: Record, style: RecordCellStyle = .regular, isConflicted: Bool = false) {
        applyWrapping(for: style)
        applyMetrics(for: style)
        let fontSize = Preferences.recordFontSize
        let contentFont = NSFont.systemFont(ofSize: fontSize)
        let priority = record.priorityValue
        // Cells are recycled across styles and conflict states, so every
        // accessibility override is reset here, not only set.
        setAccessibilityElement(style == .trash)
        setAccessibilityLabel(style == .trash ? "Trashed: \(record.content)" : nil)
        priorityLabel.setAccessibilityLabel("Priority \(priority.label)")
        timeLabel.setAccessibilityLabel(isConflicted ? "Unresolved sync conflict" : nil)

        if style == .trash {
            priorityLabel.stringValue = ""
            priorityLabel.isHidden = true
            priorityWidthConstraint.constant = 0
            contentLeadingConstraint.constant = 0
            let timestamp = record.deletedAt ?? record.createdAt
            timeLabel.stringValue = Self.relativeTimeString(fromMillis: timestamp)
            timeLabel.textColor = Theme.Ink.secondary
            // An attributed value carries its own paragraph style, which
            // overrides the cell's lineBreakMode — without this the Trash
            // row clipped mid-glyph instead of showing an ellipsis.
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingTail
            contentField.attributedStringValue = NSAttributedString(
                string: record.content,
                attributes: [
                    .font: contentFont,
                    .foregroundColor: Theme.Ink.primary,
                    .paragraphStyle: truncating
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
                    .foregroundColor: Theme.Ink.tertiary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ]
            )
            priorityLabel.textColor = Theme.Ink.tertiary
            timeLabel.textColor = Theme.Ink.tertiary
        } else {
            contentField.attributedStringValue = NSAttributedString(
                string: record.content,
                attributes: [
                    .font: contentFont,
                    .foregroundColor: Theme.Ink.primary
                ]
            )
            priorityLabel.textColor = Self.color(for: priority)
            timeLabel.textColor = Theme.Ink.secondary
        }
        if isConflicted {
            timeLabel.stringValue = Self.conflictBadgeText
            timeLabel.textColor = .systemOrange
        }
    }

    private static let conflictBadgeText = "Conflict"

    private func applyMetrics(for style: RecordCellStyle) {
        let fontSize = Preferences.recordFontSize
        let pad = Preferences.recordVerticalPadding
        priorityLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        timeLabel.font = .systemFont(ofSize: fontSize)
        priorityWidthConstraint.constant = style == .trash ? 0 : Self.priorityColumnWidth(fontSize: fontSize)
        timeWidthConstraint.constant = Self.timeColumnWidth(fontSize: fontSize)
        contentTopConstraint.constant = pad
        contentBottomLimit.constant = -pad
        minHeightConstraint.constant = Preferences.recordRowMinHeight
    }

    private static func priorityColumnWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        return ceil(("P0" as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    // MARK: - Row height (explicit; ARCHITECTURE invariant 5)

    /// Width the wrapping Content field gets in a cell `tableWidth` wide —
    /// the same arithmetic as the constraints in `setUpViews` (text rail,
    /// Priority column, 8pt gap | 10pt gap, time column, contentInset). The
    /// UI smoke asserts a live cell's field width against this.
    static func contentFieldWidth(tableWidth: CGFloat, style: RecordCellStyle = .regular) -> CGFloat {
        let fontSize = Preferences.recordFontSize
        let leading = Theme.Size.textRail + (style == .trash ? 0 : priorityColumnWidth(fontSize: fontSize) + 8)
        let trailing = 10 + timeColumnWidth(fontSize: fontSize) + Theme.Size.timeRail
        return max(1, tableWidth - leading - trailing)
    }

    /// Row height (without intercell spacing) for `record` at `tableWidth`:
    /// the wrapped Content height plus both vertical pads, never under
    /// `recordRowMinHeight`. Measured by the same `WrappingTextFieldCell`
    /// the row draws with, so the row is exactly the cell's fitting height
    /// and nothing clips. Cached per content at the current width; the
    /// cache is dropped on a width change (bounded by the row count).
    static func displayHeight(for record: Record, style: RecordCellStyle, tableWidth: CGFloat) -> CGFloat {
        let pad = Preferences.recordVerticalPadding
        let minHeight = Preferences.recordRowMinHeight
        if style == .trash {
            return max(minHeight, singleLineHeight + pad * 2)
        }
        let width = contentFieldWidth(tableWidth: tableWidth, style: style)
        if width != heightCacheWidth {
            heightCache.removeAll(keepingCapacity: true)
            heightCacheWidth = width
        }
        if let cached = heightCache[record.content] { return cached }
        let text: CGFloat
        // One-line text needs no layout pass: the cell's own single-line
        // height, as long as the glyphs clearly fit inside the field
        // (NSTextFieldCell keeps 2pt at each side).
        if !record.content.contains(where: \.isNewline),
           (record.content as NSString).size(withAttributes: [.font: measuringFont]).width <= width - 8 {
            text = singleLineHeight
        } else {
            text = measure(record.content, width: width)
        }
        let height = max(minHeight, text + pad * 2)
        heightCache[record.content] = height
        return height
    }

    private static var heightCache: [String: CGFloat] = [:]
    private static var heightCacheWidth: CGFloat = -1
    private static var measuringFont: NSFont { NSFont.systemFont(ofSize: Preferences.recordFontSize) }
    private static let measuringCell: WrappingTextFieldCell = {
        let cell = WrappingTextFieldCell(textCell: "")
        cell.isEditable = false
        cell.isBordered = false
        cell.wraps = true
        cell.isScrollable = false
        cell.usesSingleLineMode = false
        cell.lineBreakMode = .byWordWrapping
        return cell
    }()
    /// What the cell reports for one line — measured, not derived from
    /// font metrics, so the fast path and the layout path agree.
    private static var singleLineHeight: CGFloat {
        if let cached = singleLineHeightCache, cached.pointSize == Preferences.recordFontSize { return cached.height }
        let height = measure("Xg", width: 1000)
        singleLineHeightCache = (Preferences.recordFontSize, height)
        return height
    }
    private static var singleLineHeightCache: (pointSize: CGFloat, height: CGFloat)?

    private static func measure(_ content: String, width: CGFloat) -> CGFloat {
        let cell = measuringCell
        cell.font = measuringFont
        cell.attributedStringValue = NSAttributedString(string: content, attributes: [.font: measuringFont])
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// Fitting height while the field editor is up (the live text's wrapped
    /// height plus pads); the owner returns it from `heightOfRow`.
    var editingHeight: CGFloat { fittingSize.height }

    /// Widest plausible date in the current locale's own format — the
    /// template decides the pattern, so measure its output, not a literal.
    private static func timeColumnWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let sample = otherYearFormatter.string(from: Date(timeIntervalSince1970: 1_884_470_400)) // 2029-09-19
        return ceil((sample as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Trash keeps a fixed single-line row and truncates; wrapping there
    /// fights the pinned height. Main-list cells wrap so automatic row
    /// heights can grow.
    private func applyWrapping(for style: RecordCellStyle) {
        if style == .trash {
            contentField.usesSingleLineMode = true
            contentField.maximumNumberOfLines = 1
            contentField.lineBreakMode = .byTruncatingTail
            if let cell = contentField.cell as? NSTextFieldCell {
                cell.wraps = false
                // A scrollable cell clips instead of truncating; the Trash
                // snapshot showed a half glyph where the ellipsis belongs.
                cell.isScrollable = false
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

    /// Switches Content into an editable field and makes it first
    /// responder. The caret goes to the end, or — for a double-click — to
    /// the insertion point nearest `caretNear` (window coordinates). Caller
    /// is responsible for the row already being scrolled into view.
    func beginEditing(caretNear windowPoint: NSPoint? = nil) {
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
                .foregroundColor: Theme.Ink.primary
            ]
        )
        contentField.isEditable = true
        contentField.isSelectable = true
        window?.makeFirstResponder(contentField)
        if let editor = contentField.currentEditor() as? NSTextView {
            configureFieldEditor(editor, font: font)
            let end = editor.string.utf16.count
            var caret = end
            if let windowPoint {
                let local = editor.convert(windowPoint, from: nil)
                caret = min(max(0, editor.characterIndexForInsertion(at: local)), end)
            }
            editor.selectedRange = NSRange(location: caret, length: 0)
        }
    }

    /// Caret position (UTF-16 offset) while editing, for the UI smoke.
    var smokeCaretLocation: Int? {
        (contentField.currentEditor() as? NSTextView)?.selectedRange.location
    }

    /// Window-space origin of the Content text's first line (the field's
    /// leading edge plus NSTextFieldCell's 2pt inset, at mid line height).
    func smokeContentTextOrigin() -> NSPoint {
        let frame = contentField.convert(contentField.bounds, to: nil)
        let lineHeight = contentField.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        return NSPoint(x: frame.minX + 2, y: frame.maxY - lineHeight / 2)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        let font = NSFont.systemFont(ofSize: Preferences.recordFontSize)
        if let editor = contentField.currentEditor() as? NSTextView {
            configureFieldEditor(editor, font: font)
        }
    }

    private func configureFieldEditor(_ editor: NSTextView, font: NSFont) {
        editor.font = font
        editor.textColor = Theme.Ink.primary
        editor.drawsBackground = false
        editor.isRichText = false
        editor.textContainerInset = .zero
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineBreakMode = .byWordWrapping
        // NSTextFieldCell draws its text 2 pt in from the cell edge; the
        // editor must do the same or the text jumps on Enter (pixel snapshots).
        editor.textContainer?.lineFragmentPadding = 2
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
    /// editing row height — grows and shrinks with the wrapped lines.
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
        case .p2: return Theme.Ink.secondary
        case .p3: return Theme.Ink.tertiary
        }
    }

    // Shared across every cell configure; DateFormatter is not thread-safe,
    // but these are only touched from the main thread.
    private static let calendar = Calendar.autoupdatingCurrent
    // Dates follow the UI language, not the system region: the app ships
    // English only, and a Chinese-region user otherwise saw "8月 22" next
    // to English chrome (and the smoke measured a different glyph on the
    // right rail than the bundled app shows). Templates, not fixed
    // patterns, so a future localisation gets its own order/separators.
    private static let dateLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = dateLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = dateLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    /// Created-at as a plain date: `MMM d`, or `MMM d, yyyy` when the year
    /// differs from `now`. No Today/Yesterday — a date reads the same every
    /// day and does not go stale overnight.
    static func relativeTimeString(fromMillis milliseconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? sameYearFormatter : otherYearFormatter).string(from: date)
    }

    // MARK: - UI smoke

    /// Wrap diagnostics: field width vs. the width the text was measured at.
    var smokeFieldWidth: CGFloat { contentField.frame.width }

    var smokeWrapMetrics: String {
        let field = contentField.frame.width
        let measuredAtField = contentField.cell?.cellSize(forBounds: contentField.bounds).height ?? -1
        return String(
            format: "cell %.1fx%.1f field %.1f pref %.1f intrinsicH %.1f cellSizeH@field %.1f",
            frame.width, frame.height, field, contentField.preferredMaxLayoutWidth,
            contentField.intrinsicContentSize.height, measuredAtField
        )
    }

    func smokePriorityMinX(in view: NSView?) -> CGFloat {
        priorityLabel.convert(priorityLabel.bounds, to: view).minX
    }

    func smokeTimeMaxX(in view: NSView?) -> CGFloat {
        timeLabel.convert(timeLabel.bounds, to: view).maxX
    }

    func smokePriorityFrame(in view: NSView?) -> NSRect { priorityLabel.convert(priorityLabel.bounds, to: view) }
    func smokeTimeFrame(in view: NSView?) -> NSRect { timeLabel.convert(timeLabel.bounds, to: view) }

    var smokeShowsConflictBadge: Bool {
        timeLabel.stringValue == Self.conflictBadgeText && !timeLabel.isHidden
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
    /// editing row height follows the text as it is typed.
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
        let editorText = (controlView as? NSTextField)?.currentEditor()?.string
        let measured = editorText.map { NSAttributedString(string: $0, attributes: [.font: font]) } ?? attributedStringValue
        let key = MeasureKey(width: width, text: measured, pointSize: font.pointSize)
        if key == cachedKey { return cachedSize }
        let unbounded = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        let height: CGFloat
        if editorText == nil {
            // Display mode: let NSTextFieldCell measure with the exact
            // wrapping it draws with. `boundingRect` broke lines slightly
            // differently (304 pt: 8 lines measured, 9 drawn — the last
            // line was clipped in the pixel snapshots).
            height = super.cellSize(forBounds: unbounded).height
        } else {
            height = measured.boundingRect(
                with: unbounded.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        }
        let size = NSSize(width: width, height: max(ceil(height), lineHeight))
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
        textView.textContainer?.lineFragmentPadding = 2
        return editor
    }
}
