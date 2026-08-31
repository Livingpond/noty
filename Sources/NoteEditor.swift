import SwiftUI
import AppKit

// MARK: - Bridge to the underlying NSTextView (used for ⌘F)

final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    @Published var matchCount = 0

    func recount(_ q: String) {
        guard let tv = textView, !q.isEmpty else { matchCount = 0; return }
        let ns = tv.string as NSString
        var count = 0, loc = 0
        while loc < ns.length {
            let r = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            count += 1
            loc = r.location + max(1, r.length)
        }
        matchCount = count
    }

    func findNext(_ q: String, forward: Bool = true) {
        guard let tv = textView, !q.isEmpty else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var found: NSRange

        if forward {
            let start = min(ns.length, NSMaxRange(sel))
            found = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: start, length: ns.length - start))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive])   // wrap
            }
        } else {
            found = ns.range(of: q, options: [.caseInsensitive, .backwards],
                             range: NSRange(location: 0, length: sel.location))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive, .backwards])
            }
        }
        guard found.location != NSNotFound else { return }
        tv.setSelectedRange(found)
        tv.scrollRangeToVisible(found)
        tv.showFindIndicator(for: found)
    }

    /// Turn the caret's line into a task, or strip the checkbox back off it.
    func toggleTaskLine() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let caret = min(tv.selectedRange().location, ns.length)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let text = ns.substring(with: line)

        if Tasks.isTask(text) {
            var length = 1
            if line.length > 1, ns.character(at: line.location + 1) == 32 { length = 2 }
            let range = NSRange(location: line.location, length: length)
            guard tv.shouldChangeText(in: range, replacementString: "") else { return }
            storage.replaceCharacters(in: range, with: "")
        } else {
            let range = NSRange(location: line.location, length: 0)
            guard tv.shouldChangeText(in: range, replacementString: Tasks.openPrefix) else { return }
            storage.replaceCharacters(in: range, with: Tasks.openPrefix)
        }
        tv.didChangeText()
    }

    func focusText() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

extension NSAttributedString.Key {
    /// Marks Markdown punctuation that should take up no space on screen while
    /// staying in the text storage, so what is saved is what was typed.
    static let notyHidden = NSAttributedString.Key("notyHidden")
}

/// Collapses glyphs carrying `.notyHidden` to nothing. This is the only way to
/// hide characters without deleting them: colouring them clear still leaves
/// their width behind, and the caret still walks through them.
final class HidingLayoutManager: NSLayoutManager {
    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes charIndexes: UnsafePointer<Int>,
                            font aFont: NSFont,
                            forGlyphRange glyphRange: NSRange) {
        guard let storage = textStorage else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
            return
        }
        var edited = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard ci < storage.length else { continue }
            if storage.attribute(.notyHidden, at: ci, effectiveRange: nil) != nil {
                edited[i] = .null
                changed = true
            }
        }
        guard changed else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
            return
        }
        edited.withUnsafeBufferPointer { buf in
            super.setGlyphs(glyphs, properties: buf.baseAddress!, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
        }
    }
}

// MARK: - NSTextView wrapper

/// Text view that treats a leading ☐ / ☑ as a real checkbox: clicking the box
/// toggles it, Return carries the list on, and finished lines get struck through.
final class TaskTextView: NSTextView {

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleBox(at: point) { return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let origin = textContainerOrigin
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byLines) { sub, range, _, _ in
            guard let sub, Tasks.isTask(sub) else { return }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                       actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            r.origin.x += origin.x
            r.origin.y += origin.y
            self.addCursorRect(r.insetBy(dx: -3, dy: -2), cursor: .pointingHand)
        }
    }

    /// Returns true when the click landed on a checkbox and was consumed.
    private func toggleBox(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let index = min(characterIndexForInsertion(at: point), max(0, ns.length - 1))
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        guard line.length > 0 else { return false }
        let first = ns.character(at: line.location)
        guard first == Tasks.open.unicodeScalars.first!.value ||
              first == Tasks.done.unicodeScalars.first!.value else { return false }

        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1),
                                   actualCharacterRange: nil)
        var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        guard box.insetBy(dx: -4, dy: -3).contains(point) else { return false }

        let target = NSRange(location: line.location, length: 1)
        let flipped = String(first == Tasks.open.unicodeScalars.first!.value ? Tasks.done : Tasks.open)
        guard shouldChangeText(in: target, replacementString: flipped) else { return true }
        storage.replaceCharacters(in: target, with: flipped)
        didChangeText()
        return true
    }
}

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let ink: NSColor
    let bridge: EditorBridge
    var autofocus: Bool
    var fontSize: CGFloat = 13.5

    static func bodyFont(_ size: CGFloat) -> NSFont { Ink.body(size) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // An explicit TextKit 1 stack: a plain NSTextView would get TextKit 2,
        // where NSLayoutManager — and so the glyph hiding — is never consulted.
        let storage = NSTextStorage()
        let layout = HidingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let tv = TaskTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Self.bodyFont(fontSize)
        tv.textColor = ink
        tv.insertionPointColor = ink
        tv.textContainerInset = NSSize(width: 15, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.string = text

        scroll.documentView = tv
        bridge.textView = tv
        Self.styleTasks(tv, ink: ink, size: fontSize)
        if autofocus {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Never replace the string while an IME owns a marked-text range.
        // SwiftUI can update this view from the autosave publisher while a
        // Chinese/Japanese composition is still active; assigning `string`
        // then discards the composition and makes typed text appear to vanish.
        if !tv.hasMarkedText(), tv.string != text {
            tv.string = text
            Self.styleTasks(tv, ink: ink, size: fontSize)
        }
        let want = Self.bodyFont(fontSize)
        if tv.textColor != ink || tv.font != want {
            tv.textColor = ink
            tv.insertionPointColor = ink
            tv.font = want
            Self.styleTasks(tv, ink: ink, size: fontSize)
        }
        if bridge.textView !== tv { bridge.textView = tv }
    }

    /// Dim and strike through anything already ticked off.
    /// Restyling touches the whole document, which happens on every keystroke.
    /// Two things make that safe: the caret has to be put back afterwards, and
    /// `typingAttributes` has to be refreshed — otherwise the next character is
    /// inserted in the *previous* font and immediately rewritten, which reads as
    /// the text jumping under the cursor after a font or size change.
    static func styleTasks(_ tv: NSTextView, ink: NSColor, size: CGFloat = 13.5) {
        // TextKit mutations and selection restoration are not safe while the
        // input method is composing marked text. The next textDidChange after
        // the composition is committed will style the complete document.
        guard !tv.hasMarkedText() else { return }

        let font = bodyFont(size)
        tv.typingAttributes = [.font: font, .foregroundColor: ink]

        guard let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let caret = tv.selectedRange()
        storage.beginEditing()
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.removeAttribute(.obliqueness, range: full)
        storage.removeAttribute(.backgroundColor, range: full)
        storage.removeAttribute(.notyHidden, range: full)
        storage.addAttribute(.foregroundColor, value: ink, range: full)
        storage.addAttribute(.font, value: font, range: full)

        let ns = storage.string as NSString
        if Settings.markdownStyling {
            let line = ns.lineRange(for: NSRange(location: min(caret.location, ns.length), length: 0))
            markdown(storage, ns, full, ink: ink, size: size, revealing: line)
        }

        // Tasks are styled after Markdown so a completed task still reads as done
        // even when its line also carries emphasis.
        ns.enumerateSubstrings(in: full, options: .byLines) { sub, range, _, _ in
            guard let sub, Tasks.marker(of: sub) == Tasks.done else { return }
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.foregroundColor,
                                 value: ink.withAlphaComponent(0.45), range: range)
        }
        storage.endEditing()
        // Hidden glyphs only disappear once the glyph cache is rebuilt.
        tv.layoutManager?.invalidateGlyphs(forCharacterRange: full, changeInLength: 0,
                                           actualCharacterRange: nil)
        tv.layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        let end = (storage.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(caret.location, end),
                                    length: min(caret.length, end - min(caret.location, end))))
        tv.window?.invalidateCursorRects(for: tv)
    }

    /// Inline Markdown. The source stays plain text — markers are dimmed rather
    /// than hidden, so what you typed is always what is stored.
    private static func markdown(_ storage: NSTextStorage, _ ns: NSString,
                                 _ full: NSRange, ink: NSColor, size: CGFloat,
                                 revealing caretLine: NSRange) {
        let faint = ink.withAlphaComponent(0.32)

        func each(_ pattern: String, _ opts: NSRegularExpression.Options = [],
                  _ body: (NSTextCheckingResult) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            re.enumerateMatches(in: ns as String, range: full) { m, _, _ in
                if let m { body(m) }
            }
        }
        /// Punctuation is hidden — unless the caret is on that line, where it is
        /// only dimmed, so the markers can still be seen and edited.
        func dim(_ r: NSRange) {
            if NSIntersectionRange(r, caretLine).length > 0 || caretLine.location == r.location {
                storage.addAttribute(.foregroundColor, value: faint, range: r)
            } else {
                storage.addAttribute(.notyHidden, value: true, range: r)
                storage.addAttribute(.foregroundColor, value: faint, range: r)
            }
        }

        // # heading — bigger and bolder, hashes dimmed
        each("^(#{1,6})[ \\t]+(.+)$", [.anchorsMatchLines]) { m in
            let level = m.range(at: 1).length
            let bump = max(1.5, 7 - CGFloat(level) * 1.1)
            storage.addAttribute(.font, value: heavier(size + bump), range: m.range)
            dim(m.range(at: 1))
        }
        // **bold** and __bold__
        each("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1") { m in
            storage.addAttribute(.font, value: heavier(size), range: m.range(at: 2))
            dim(NSRange(location: m.range.location, length: 2))
            dim(NSRange(location: m.range.upperBound - 2, length: 2))
        }
        // *italic* and _italic_
        each("(?<![\\*_])([\\*_])(?=[^\\*_\\s])(.+?)(?<=[^\\*_\\s])\\1(?![\\*_])") { m in
            storage.addAttribute(.obliqueness, value: 0.2, range: m.range(at: 2))
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: m.range.upperBound - 1, length: 1))
        }
        // `code`
        each("`([^`\\n]+)`") { m in
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 0.5,
                                                                          weight: .regular),
                                 range: m.range(at: 1))
            storage.addAttribute(.backgroundColor, value: ink.withAlphaComponent(0.07),
                                 range: m.range(at: 1))
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: m.range.upperBound - 1, length: 1))
        }
        // ~~struck~~
        each("~~(?=\\S)(.+?)(?<=\\S)~~") { m in
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dim(NSRange(location: m.range.location, length: 2))
            dim(NSRange(location: m.range.upperBound - 2, length: 2))
        }
        // > quote
        each("^>[ \\t]?(.*)$", [.anchorsMatchLines]) { m in
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.62),
                                 range: m.range)
            storage.addAttribute(.obliqueness, value: 0.15, range: m.range(at: 1))
            dim(NSRange(location: m.range.location, length: 1))
        }
        // - bullet
        each("^[ \\t]*([-*+])[ \\t]+", [.anchorsMatchLines]) { m in
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.5),
                                 range: m.range(at: 1))
        }
    }

    /// A bolder cut of whatever face the note is set in.
    private static func heavier(_ size: CGFloat) -> NSFont {
        let base = bodyFont(size)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        return bold != base ? bold : NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NoteTextView
        init(_ p: NoteTextView) { parent = p }

        private var lastLine = NSRange(location: NSNotFound, length: 0)

        /// Moving the caret to another line changes which markers are revealed.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard Settings.markdownStyling,
                  let tv = notification.object as? NSTextView else { return }
            let ns = tv.string as NSString
            let caret = min(tv.selectedRange().location, ns.length)
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            guard line.location != lastLine.location || line.length != lastLine.length else { return }
            lastLine = line
            NoteTextView.styleTasks(tv, ink: parent.ink, size: parent.fontSize)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            NoteTextView.styleTasks(tv, ink: parent.ink, size: parent.fontSize)
            parent.text = tv.string
        }

        /// Return on a task line starts the next task; on an empty one, ends the list.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = tv.string as NSString
            guard range.location <= ns.length else { return true }
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let text = ns.substring(with: line)
            guard Tasks.isTask(text) else { return true }

            if Tasks.stripped(text.trimmingCharacters(in: .newlines)).isEmpty {
                let clear = NSRange(location: line.location,
                                    length: min(line.length, ns.length - line.location))
                if tv.shouldChangeText(in: clear, replacementString: "") {
                    tv.textStorage?.replaceCharacters(in: clear, with: "")
                    tv.didChangeText()
                }
                return false
            }
            tv.insertText("\n" + Tasks.openPrefix, replacementRange: range)
            return false
        }
    }
}

// MARK: - Editor

struct NoteEditorView: View {
    let note: Note
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    var onRight: Bool = true

    @State private var text = ""
    @State private var saveWork: DispatchWorkItem?
    @State private var savedAt: Date?
    @FocusState private var findFocused: Bool

    private var pal: NoteColor { note.palette }

    var body: some View {
        HStack(spacing: 0) {
            if onRight { gutter; sheet } else { sheet; gutter }
        }
        .background(
            noteShape
                .fill(LinearGradient(colors: [pal.paper, pal.paper.opacity(0.88)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.34), radius: 28, x: onRight ? -12 : 12, y: 12)
        )
        .clipShape(noteShape)
        .overlay(noteShape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .onAppear {
            text = note.body
            savedAt = note.modified
        }
        .onChange(of: text) { _, v in scheduleSave(v) }
        .onChange(of: deck.findQuery) { _, q in
            if q != nil { findFocused = true } else { deck.bridge.focusText() }
        }
        .onDisappear { flush() }
    }

    /// Rounded where it leaves the deck, square where it meets the screen edge.
    private var noteShape: UnevenRoundedRectangle { edgeTabShape(onRight: onRight, radius: 14) }

    // MARK: The note itself

    private var sheet: some View {
        VStack(spacing: 0) {
            header
            if deck.findQuery != nil { findBar }
            NoteTextView(text: $text, ink: NSColor(pal.ink),
                         bridge: deck.bridge, autofocus: true,
                         fontSize: deck.fontSize)
            footer
        }
    }

    /// The note's own tab, carried along so it reads as growing out of the deck.
    ///
    /// `rotationEffect` is a render transform, not a layout one: a rotated label
    /// still *measures* at its unrotated width, so the tint has to be sized on its
    /// own and the label clipped into it, or the background bleeds across the note.
    private var gutter: some View {
        Rectangle()
            .fill(pal.dash.opacity(0.20))
            .frame(width: DeckGeom.gutterWidth)
            .overlay {
                Text(note.displayTitle.uppercased())
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pal.ink.opacity(0.7))
                    .frame(width: DeckGeom.editorHeight - 44)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
            }
            .clipped()
            .overlay(alignment: onRight ? .trailing : .leading) {
                EdgeLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(pal.ink.opacity(0.22))
                    .frame(width: 1)
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(note.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(pal.ink.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(savedAt.map { "Saved · \(Fmt.ago($0))" } ?? "Not saved")
                .font(.system(size: 10))
                .foregroundStyle(pal.ink.opacity(0.42))
            Button { NoteStore.shared.togglePin(id: note.id) } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(note.pinned ? 0 : 32))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(note.pinned ? 0.85 : 0.4))
            .help(note.pinned ? "Unpin — ⌘P" : "Pin so it stays open  ⌘P")

            Button { deck.bridge.toggleTaskLine() } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help("Task  ⌘T")
            Button { deck.findQuery = deck.findQuery == nil ? "" : nil } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help("Find  ⌘F")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(pal.ink.opacity(0.45))
            TextField("Find in note", text: Binding(
                get: { deck.findQuery ?? "" },
                set: { deck.findQuery = $0; deck.bridge.recount($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(pal.ink)
                .focused($findFocused)
                .onSubmit { deck.bridge.findNext(deck.findQuery ?? "") }
            Text(deck.bridge.matchCount == 0 ? "—" : "\(deck.bridge.matchCount)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(pal.ink.opacity(0.45))
            Button { deck.bridge.findNext(deck.findQuery ?? "", forward: false) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
            Button { deck.bridge.findNext(deck.findQuery ?? "") } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(pal.dash.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { idx, c in
                Button { NoteStore.shared.setColor(id: note.id, color: idx) } label: {
                    Circle()
                        .fill(c.dash)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle().strokeBorder(pal.ink.opacity(0.55),
                                                  lineWidth: idx == note.color ? 1.5 : 0)
                                .padding(-2.5)
                        )
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(c.name)
            }
            Spacer(minLength: 8)
            footerButton("Archive") {
                NoteStore.shared.setArchived(id: note.id, true)
                controller.collapse()
            }
            footerButton("Delete") {
                NoteStore.shared.delete(id: note.id)
                controller.collapse()
            }
            footerButton("Close") { controller.collapse() }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(pal.ink.opacity(0.72))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pal.ink.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Autosave — 250 ms after typing stops

    private func scheduleSave(_ value: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem {
            NoteStore.shared.updateBody(id: note.id, body: value)
            savedAt = Date()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flush() {
        saveWork?.cancel()
        NoteStore.shared.updateBody(id: note.id, body: text)
    }
}
