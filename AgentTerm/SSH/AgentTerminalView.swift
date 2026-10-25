import ObjectiveC
import SwiftTerm
import UIKit

/// SwiftTerm's view, with one fix: holding backspace on the soft keyboard repeats, including
/// over text the shell drew (history recall, tab completion) and inserted snippets.
///
/// Several things stopped the repeat. First, iOS only auto-repeats a held delete while the text
/// input reports `hasText == true`.
/// SwiftTerm 1.20 answers from its small IME buffer, which is almost always empty in a
/// terminal, so a held delete fired once. Its `hasText` isn't `open` until SwiftTerm 1.99, so
/// this subclass answers UIKit's Objective-C `hasText` query directly. SwiftTerm's own Swift
/// calls are unaffected, and deleteBackward with an empty buffer already sends a plain backspace.
final class AgentTerminalView: TerminalView {
    private static let alwaysHasText: Void = {
        let implementation: @convention(block) (AnyObject) -> Bool = { _ in true }
        class_addMethod(
            AgentTerminalView.self,
            #selector(getter: UIKeyInput.hasText),
            imp_implementationWithBlock(implementation),
            "B@:"
        )
    }()

    /// True while padding is being added; TerminalSession drops anything sent meanwhile.
    private(set) var isInsertingPadding = false

    override func deleteBackward() {
        // SwiftTerm reports its own buffer edits to inputDelegate (textWillChange/textDidChange),
        // which UIKit reserves for changes made outside the keyboard. Getting one during a
        // keyboard-initiated delete makes iOS resync and cancel the key repeat.
        let delegate = inputDelegate
        inputDelegate = nil
        super.deleteBackward()
        // The keyboard keeps repeating only while it can see text before the cursor, but text
        // the shell drew itself (history recall, tab completion) never passes through the
        // keyboard. Keep one invisible character there that is never sent: deleting it sends a
        // real backspace (as an empty buffer does) and it is put back straight away.
        // (`hasText` here is SwiftTerm's own answer, not the YES given to UIKit.)
        if !hasText { insertPadding() }
        inputDelegate = delegate
    }

    /// WORD JOINER: invisible, not whitespace (a space would trip iOS's double-space period).
    private static let padding = "\u{2060}"

    private func insertPadding() {
        isInsertingPadding = true
        insertText(Self.padding)
        isInsertingPadding = false
    }

    /// SwiftTerm leaves iOS 17 inline predictions on; accepting one (with space) would type it
    /// into the shell.
    @objc var inlinePredictionType: UITextInlinePredictionType = .no

    // MARK: Pasting images and files

    /// Gets the clipboard's items when a paste (⌘V, the keyboard's paste) has no text but does
    /// have images or files, e.g. a copied screenshot; TerminalScreen uploads them.
    var onPasteItems: (([NSItemProvider]) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if !pasteboard.hasStrings, let onPasteItems, pasteboard.numberOfItems > 0 {
            onPasteItems(pasteboard.itemProviders)
            return
        }
        super.paste(sender)
    }

    // MARK: Two fingers: pinch to zoom, drag to scroll

    /// Called with pinch updates once a two-finger gesture is a zoom; TerminalScreen turns them
    /// into a text size.
    var onPinch: ((UIPinchGestureRecognizer) -> Void)?

    /// A two-finger gesture is whichever it clearly does first, then stays that until lifted.
    private enum TwoFingerMode { case undecided, zoom, scroll }
    private var twoFingerMode = TwoFingerMode.undecided
    private var scrollRemainder: CGFloat = 0
    private let twoFingerScroll = UIPanGestureRecognizer()
    private let simultaneous = SimultaneousGestures()

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            if twoFingerMode == .undecided, abs(gesture.scale - 1) > 0.08 { twoFingerMode = .zoom }
            if twoFingerMode == .zoom { onPinch?(gesture) }
        case .ended, .cancelled, .failed:
            if twoFingerMode == .zoom { onPinch?(gesture) }
            twoFingerMode = .undecided
        default:
            break
        }
    }

    @objc private func handleTwoFingerScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: self)
            if twoFingerMode == .undecided, hypot(translation.x, translation.y) > 12 {
                twoFingerMode = .scroll
                scrollRemainder = 0
            }
            guard twoFingerMode == .scroll else { return }
            gesture.setTranslation(.zero, in: self)
            scroll(by: translation.y, at: gesture.location(in: self))
        case .ended, .cancelled, .failed:
            twoFingerMode = .undecided
        default:
            break
        }
    }

    /// Fingers moving down show older text. With mouse reporting on (tmux), that's scroll-wheel
    /// events: tmux enters copy mode and moves 5 lines per wheel step, so one step is sent per
    /// 5 rows of finger travel. Otherwise SwiftTerm's own scrollback scrolls.
    private func scroll(by dy: CGFloat, at point: CGPoint) {
        let terminal = getTerminal()
        let rowHeight = bounds.height / CGFloat(max(terminal.rows, 1))
        guard terminal.mouseMode != .off else {
            let maxOffset = max(contentSize.height - bounds.height, 0)
            setContentOffset(CGPoint(x: contentOffset.x, y: min(max(contentOffset.y - dy, 0), maxOffset)), animated: false)
            return
        }
        let col = min(max(Int(point.x / (bounds.width / CGFloat(max(terminal.cols, 1)))), 0), terminal.cols - 1)
        let row = min(max(Int((point.y - contentOffset.y) / rowHeight), 0), terminal.rows - 1)
        let step = rowHeight * 5
        scrollRemainder += dy
        while abs(scrollRemainder) >= step {
            let up = scrollRemainder > 0
            let flags = terminal.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            scrollRemainder += up ? -step : step
        }
    }

    /// SwiftTerm adds its pans (scrolling, selection, tmux mouse drags) as mouse mode changes;
    /// keep them one-finger so two fingers always mean zoom or scroll.
    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan !== twoFingerScroll {
            pan.maximumNumberOfTouches = 1
        }
        super.addGestureRecognizer(gestureRecognizer)
    }

    static func make(frame: CGRect) -> AgentTerminalView {
        _ = alwaysHasText
        let view = AgentTerminalView(frame: frame)
        view.panGestureRecognizer.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(handlePinch))
        pinch.delegate = view.simultaneous
        view.addGestureRecognizer(pinch)
        view.twoFingerScroll.addTarget(view, action: #selector(handleTwoFingerScroll))
        view.twoFingerScroll.minimumNumberOfTouches = 2
        view.twoFingerScroll.maximumNumberOfTouches = 2
        view.twoFingerScroll.delegate = view.simultaneous
        view.addGestureRecognizer(view.twoFingerScroll)
        return view
    }

    #if DEBUG
    /// Logs the view's gesture recognizers before and after a program turns mouse mode on.
    static func selfTestGestures() {
        let view = make(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        func describe(_ label: String) {
            let all = view.gestureRecognizers ?? []
            let pans = all.compactMap { $0 as? UIPanGestureRecognizer }
            EventLog.record("selftest gestures \(label): pinch=\(all.contains { $0 is UIPinchGestureRecognizer }) pans=\(pans.count) maxTouches=\(pans.map(\.maximumNumberOfTouches))")
        }
        describe("initial")
        view.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        DispatchQueue.main.async { describe("after mouse mode on") }
    }

    /// Logs what reaches the session for a scripted sequence of keyboard deletes and typing.
    static func selfTestDelete() {
        final class Capture: NSObject, TerminalViewDelegate {
            var sent: [UInt8] = []
            func send(source: TerminalView, data: ArraySlice<UInt8>) {
                if (source as? AgentTerminalView)?.isInsertingPadding == true { return }
                sent += data
            }
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func scrolled(source: TerminalView, position: Double) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
            func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
            func clipboardCopy(source: TerminalView, content: Data) {}
        }
        let view = make(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let capture = Capture()
        view.terminalDelegate = capture
        func step(_ label: String, _ action: () -> Void) {
            capture.sent = []
            action()
            EventLog.record("selftest \(label): sent=\(capture.sent) swiftHasText=\(view.hasText) uikitHasText=\((view as UIKeyInput).hasText)")
        }
        step("delete on empty buffer") { view.deleteBackward() }
        step("delete again (padding)") { view.deleteBackward() }
        step("type ab") { view.insertText("ab") }
        step("delete x3") { view.deleteBackward(); view.deleteBackward(); view.deleteBackward() }
        step("return") { view.insertText("\n") }
        step("delete after return") { view.deleteBackward() }
    }
    #endif
}

/// Lets recognizers track a gesture together: the terminal's pinch and two-finger scroll,
/// the editor's symbol tap alongside the text view's own.
final class SimultaneousGestures: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
