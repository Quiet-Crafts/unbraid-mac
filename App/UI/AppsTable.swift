import AppKit
import SwiftUI

/// The apps list: an AppKit table with hand-drawn cells. SwiftUI's Table measured every row and rebuilt itself on each
/// page and search (120 ms a page, 25 ms a key, with 135 apps); this draws only the rows on screen, at a fixed height,
/// and a menu exists only while it is open. The same table serves every page, so a page change is a reload.
struct AppsTable: NSViewRepresentable {
    let rows: [Row]
    /// What a row shows beyond `rows`. Passed in so that a new week redraws the rows on screen.
    let week: [String: Int64]
    let peak: Int64
    let page: String
    @Binding var selection: Set<String>
    @Binding var sort: AppsSort

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Host {
        let table = NSTableView()
        table.style = .inset
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 17, height: 0)
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        func column(_ id: AppsSort.Key, _ title: String, min: CGFloat, ideal: CGFloat, max: CGFloat, fills: Bool = false) {
            let c = NSTableColumn(identifier: .init(id.rawValue))
            c.title = title
            c.minWidth = min
            c.width = ideal
            c.maxWidth = max
            // App and Route share the room, so the table fills any window width.
            c.resizingMask = fills ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.headerCell.font = .systemFont(ofSize: 13)
            c.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
            table.addTableColumn(c)
        }
        column(.name, "App", min: 200, ideal: 350, max: 440, fills: true)
        column(.route, "Route", min: 120, ideal: 234, max: 10_000, fills: true)
        column(.week, "This Week", min: 136, ideal: 160, max: 190)
        let c = context.coordinator
        c.table = table
        table.dataSource = c
        table.delegate = c
        let menu = NSMenu()
        menu.delegate = c
        table.menu = menu
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // The header sits above the scrolling area rather than floating over it, so rows never show through it and the
        // page's colour still does.
        let header = ClearHeader()
        table.headerView = nil
        header.tableView = table
        c.header = header
        return Host(header: header, scroll: scroll)
    }

    func updateNSView(_ host: Host, context: Context) {
        let c = context.coordinator
        c.selection = $selection
        c.sort = $sort
        c.undo = context.environment.undoManager
        c.week = week
        c.peak = peak
        c.apply(rows, page: page)
    }

    static let rowHeight: CGFloat = 40

    /// The header, with the scrolling rows below it.
    final class Host: NSView {
        private static let headerHeight: CGFloat = 28
        private let header: NSTableHeaderView
        private let scroll: NSScrollView

        init(header: NSTableHeaderView, scroll: NSScrollView) {
            self.header = header
            self.scroll = scroll
            super.init(frame: .zero)
            addSubview(header)
            addSubview(scroll)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

        /// `nonisolated`: AppKit asks this from background threads when a drag of several rows starts.
        nonisolated override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
            scroll.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: max(0, bounds.height - Self.headerHeight))
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: NSTableView?
        weak var header: NSTableHeaderView?
        var selection: Binding<Set<String>>?
        var sort: Binding<AppsSort>?
        var undo: UndoManager?
        var week: [String: Int64] = [:]
        var peak: Int64 = 0
        private var rows: [Row] = []
        private var page: String?
        /// The table is being brought in line with the view: what it reports back meanwhile isn't the user's doing.
        private var applying = false
        private let model = AppModel.shared

        func apply(_ new: [Row], page: String) {
            guard let table else { return }
            applying = true
            defer { applying = false }
            let same = new.count == rows.count && zip(new, rows).allSatisfy { $0.id == $1.id }
            rows = new
            if let sort {
                let wanted = sort.wrappedValue.terms.map { NSSortDescriptor(key: $0.key.rawValue, ascending: $0.ascending) }
                if table.sortDescriptors != wanted { table.sortDescriptors = wanted }
            }
            header?.needsDisplay = true
            if same { refreshVisible() } else { table.reloadData() }
            if page != self.page {
                self.page = page
                if !rows.isEmpty { table.scrollRowToVisible(0) }
            }
            syncSelection()
        }

        private func syncSelection() {
            guard let table, let selection else { return }
            let wanted = IndexSet(rows.indices.filter { selection.wrappedValue.contains(rows[$0].id) })
            if table.selectedRowIndexes != wanted { table.selectRowIndexes(wanted, byExtendingSelection: false) }
        }

        private func refreshVisible() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for row in visible.lowerBound..<visible.upperBound where row < rows.count {
                for column in table.tableColumns.indices {
                    guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) else { continue }
                    fill(cell, with: rows[row])
                }
            }
        }

        private func fill(_ cell: NSView, with row: Row) {
            switch cell {
            case let c as AppCell: c.show(row)
            case let c as RouteCell: c.show(row.id) { [weak self, weak c] in if let c { self?.openMenu(row.id, from: c) } }
            case let c as WeekRowCell: c.show(row.id, bytes: week[row.id], peak: peak)
            default: break
            }
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let id = column?.identifier, row < rows.count else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) ?? {
                let made: NSView = switch AppsSort.Key(rawValue: id.rawValue) {
                case .name: AppCell()
                case .route: RouteCell()
                default: WeekRowCell()
                }
                made.identifier = id
                return made
            }()
            fill(cell, with: rows[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(withIdentifier: AppRowView.id, owner: nil) as? AppRowView ?? {
                let view = AppRowView()
                view.identifier = AppRowView.id
                return view
            }()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table, let selection else { return }
            let chosen = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            if chosen != selection.wrappedValue { selection.wrappedValue = chosen }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let sort else { return }
            let terms = tableView.sortDescriptors.compactMap { d in
                d.key.flatMap(AppsSort.Key.init(rawValue:)).map { AppsSort.Term(key: $0, ascending: d.ascending) }
            }
            if !terms.isEmpty { sort.wrappedValue = AppsSort(terms: terms) }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
            row < rows.count ? rows[row].name : nil
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < rows.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(rows[row].id, forType: .string)
            return item
        }

        // MARK: Menus, built when they open

        private func openMenu(_ app: String, from cell: NSView) {
            let s = model.setup
            let current = s.apps[app]
            let menu = NSMenu()
            menu.autoenablesItems = false
            func choice(_ title: String, _ value: String) {
                let item = menuAction(title) { [weak self] in
                    guard let self, value != (current ?? "") else { return }
                    model.move([app], to: value.isEmpty ? nil : value, undo: undo)
                }
                item.state = value == (current ?? "") ? .on : .off
                menu.addItem(item)
            }
            choice(s.defaultLabel, "")
            menu.addItem(.separator())
            for id in s.sidebarRoutes where id != s.defaultRoute { choice(s.label(id), id) }
            if current == DIRECT, s.prefs.effectiveFilter.server != nil {
                menu.addItem(.separator())
                menu.addItem(filterItem(app))
            }
            menu.addItem(.separator())
            menu.addItem(menuAction("New Route…") { Presentation.shared.picker = PickerTarget(id: "app:\(app)") })
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: cell.bounds.height / 2 + 14), in: cell)
        }

        private func filterItem(_ app: String) -> NSMenuItem {
            let on = model.setup.prefs.effectiveFilter.through(app)
            let item = menuAction("Filter Its Lookups") { [model] in
                model.setPrefs { $0.filter.apps[app] = !on; $0.customDns = [] }
            }
            item.state = on ? .on : .off
            return item
        }

        /// The clicked row's menu: for the selection if the row is in it, as elsewhere on the Mac.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let clicked = rows[table.clickedRow].id
            let chosen = selection?.wrappedValue ?? []
            let ids = chosen.contains(clicked) ? Array(chosen) : [clicked]
            let move: (String?) -> Void = { [weak self] to in
                guard let self else { return }
                model.move(ids, to: to, undo: undo)
            }
            let routes = NSMenu()
            for (i, id) in model.setup.sidebarRoutes.enumerated() {
                let item = menuAction(model.setup.label(id)) { move(id) }
                if i < 9 { item.keyEquivalent = "\(i + 1)"; item.keyEquivalentModifierMask = [.command, .option] }
                routes.addItem(item)
            }
            routes.addItem(.separator())
            let follow = menuAction("Follow Default") { move(nil) }
            follow.keyEquivalent = "0"
            follow.keyEquivalentModifierMask = [.command, .option]
            routes.addItem(follow)
            let to = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
            to.submenu = routes
            menu.addItem(to)
            guard ids.count == 1 else { return }
            if model.setup.apps[clicked] == DIRECT, model.setup.prefs.effectiveFilter.server != nil { menu.addItem(filterItem(clicked)) }
            menu.addItem(menuAction("New Route for This App…") { Presentation.shared.picker = PickerTarget(id: "app:\(clicked)") })
            if let a = model.apps.app(clicked), !a.missing {
                menu.addItem(menuAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) })
            }
        }
    }
}

/// What a menu item does. The item keeps it, as its represented object.
private final class MenuRun: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// A menu item that carries what it does.
private func menuAction(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let does = MenuRun(run)
    let item = NSMenuItem(title: title, action: #selector(MenuRun.fire), keyEquivalent: "")
    item.target = does
    item.representedObject = does
    return item
}

/// The column titles, the sort arrow and a hairline, on nothing: AppKit's own header and its cells paint a background,
/// which on a see-through page reads as a black or white band. Clicks and column resizing stay AppKit's.
private final class ClearHeader: NSTableHeaderView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView else { return }
        let primary = table.sortDescriptors.first
        for (i, column) in table.tableColumns.enumerated() {
            let frame = headerRect(ofColumn: i)
            guard frame.intersects(dirtyRect) else { continue }
            let sorted = primary?.key == column.identifier.rawValue
            let font: NSFont = sorted ? .systemFont(ofSize: 13, weight: .semibold) : CellFont.name
            drawLine(attributed(column.title, font, Palette.nsText), x: frame.minX + 8, y: frame.midY, width: frame.width - 28, cut: .end)
            if i > 0 {
                Palette.nsSeparator.setFill()
                NSRect(x: frame.minX - 1, y: frame.midY - 7, width: 1, height: 14).fill()
            }
            if sorted, let arrow = Self.arrow(up: primary?.ascending == true) {
                arrow.draw(in: NSRect(x: frame.maxX - 8 - arrow.size.width, y: frame.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        Palette.nsSeparator.setFill()
        let scale = window?.backingScaleFactor ?? 2
        NSRect(x: 0, y: bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale).fill()
    }

    private static func arrow(up: Bool) -> NSImage? {
        NSImage(systemSymbolName: up ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [Palette.nsDim])))
    }
}

/// A row with its hairline, which starts where the names do, as lists do on the Mac.
private final class AppRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("row")

    /// Its cells draw into the row's one layer, which leaves the window a layer per row to compose, not four.
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    // AppKit tells only its own cell classes that their row is selected, never these drawn ones, so the row does it.
    override var isSelected: Bool { didSet { passStyle() } }
    override var isEmphasized: Bool { didSet { passStyle() } }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        passStyle()
    }

    private func passStyle() {
        let style = interiorBackgroundStyle
        for case let cell as DrawnCell in subviews { cell.backgroundStyle = style }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard !isSelected, !isNextRowSelected else { return }
        Palette.nsSeparator.setFill()
        let scale = window?.backingScaleFactor ?? 2
        let leading = 16 + Measure.tableIcon + 10
        NSRect(x: leading, y: bounds.maxY - 1 / scale, width: bounds.width - leading - 16, height: 1 / scale).fill()
    }
}

/// A hand-drawn cell. The row's selection reaches it as `backgroundStyle`, and it redraws only for a real change.
private class DrawnCell: NSView {
    /// `nonisolated`: see `AppsTable.Host`.
    nonisolated override var isFlipped: Bool { true }
    /// Set by the row. On a selected row in front, text turns to the colour that reads on the selection.
    @objc var backgroundStyle: NSView.BackgroundStyle = .normal { didSet { if oldValue != backgroundStyle { needsDisplay = true } } }
    var onSelection: Bool { backgroundStyle == .emphasized }

    func line(_ text: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat, cut: CTLineTruncationType = .end) {
        drawLine(text, x: x, y: y, width: width, cut: cut)
    }
}

/// One line, centred on `y`, cut to fit `width` where `cut` says. Drawn with Core Text directly: AppKit's string drawing
/// stops the app now and then when measuring the monospaced system font, and this costs less.
private func drawLine(_ text: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat, cut: CTLineTruncationType) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    var drawn = CTLineCreateWithAttributedString(text)
    if textWidth(text) > width, width > 0, text.length > 0 {
        let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
        drawn = CTLineCreateTruncatedLine(drawn, Double(width), cut, dots) ?? drawn
    }
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    _ = CTLineGetTypographicBounds(drawn, &ascent, &descent, &leading)
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: (y + (ascent - descent) / 2).rounded())
    CTLineDraw(drawn, context)
    context.restoreGState()
}

/// What is drawn on a selected row in front: white or near black, whichever reads better on the colour macOS really paints
/// there. That is not the accent itself (it comes out much darker in light mode), so a fixed choice fails in one mode.
nonisolated(unsafe) private let selectionInk = NSColor(name: nil) { appearance in
    var ink = NSColor.white
    appearance.performAsCurrentDrawingAppearance {
        guard let ground = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB) else { return }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let light = 0.2126 * linear(ground.redComponent) + 0.7152 * linear(ground.greenComponent) + 0.0722 * linear(ground.blueComponent)
        if 1.05 / (light + 0.05) < (light + 0.05) / 0.056 { ink = Palette.nsOnAccent }
    }
    return ink
}

/// Fonts for what is drawn by hand, made once.
private enum CellFont {
    static let name = NSFont.systemFont(ofSize: 13)
    static let route = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let number = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

private func attributed(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
}

private func textWidth(_ text: NSAttributedString) -> CGFloat {
    ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)))
}

/// The icon, the name, and for a tool where it lives (its file name alone says little) or for an app no longer here.
private final class AppCell: DrawnCell {
    private struct Shows: Equatable {
        var name = ""
        var icon: NSImage?
        var aside: String?
        var conflict: String?
        var asideIsPath = false
    }

    private var shows = Shows()
    private static let terminal = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: Measure.tableIcon * 0.5, weight: .regular).applying(.init(paletteColors: [.labelColor])))
    private static let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [Palette.nsWarning])))

    func show(_ row: Row) {
        let model = AppModel.shared
        let app = model.apps.app(row.id)
        var new = Shows(name: row.name)
        if let app, app.path.hasSuffix(".app") { new.icon = model.apps.icon(app) }
        if row.id.hasPrefix("/") {
            new.aside = row.id
            new.asideIsPath = true
            new.conflict = conflict(row.id, model)
        } else if app?.missing == true {
            new.aside = "Not found"
        }
        guard new != shows else { return }
        shows = new
        toolTip = new.conflict ?? (new.asideIsPath ? Self.toolHelp : new.aside == nil ? nil : Self.missingHelp)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([new.name, new.conflict, new.asideIsPath ? new.aside : new.aside].compactMap { $0 }.joined(separator: ", "))
        needsDisplay = true
    }

    /// A routed tool that leads to the same program as another on a different route (python3 and python3.14, both links
    /// to one Python): the engine goes by the program, so only one route can apply.
    private func conflict(_ id: String, _ model: AppModel) -> String? {
        let s = model.setup
        let others = model.apps.sharing(id, s)
        guard !others.isEmpty else { return nil }
        let list = others.map { "\($0) on \(s.label(s.routeOf($0)))" }.joined(separator: ", ")
        let blocked = ([id] + others).contains { s.routeOf($0) == BLOCK }
        return "Route conflict: \(list) \(others.count == 1 ? "runs" : "run") the same program. " + (blocked ? "Block takes precedence." : others.count == 1 ? "Assign both to the same route." : "Assign these tools to the same route.")
    }

    private static let toolHelp = "For an interpreter such as python3, its route covers every script it runs; programs those scripts start follow their own routes. A script such as pip3 runs as its interpreter, so assigning the script's path does not route its traffic. Routing or blocking one of Xcode's tools in /usr/bin (git, python3, clang) also covers that tool in every copy of Xcode unbraid knows of, selected or not, and in the Command Line Tools."
    private static let missingHelp = "Not on this Mac now. Its rule still applies where it was last seen, so a copy installed there again follows it, Block included. Block and Direct stay; a VPN route goes after a week or more."

    override func draw(_ dirtyRect: NSRect) {
        let size = Measure.tableIcon, y = bounds.midY
        let tile = NSRect(x: 0, y: y - size / 2, width: size, height: size)
        if let icon = shows.icon {
            icon.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: tile, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            if let symbol = Self.terminal {
                symbol.draw(in: NSRect(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        var x = size + 10
        let name = attributed(shows.name, CellFont.name, onSelection ? selectionInk : Palette.nsText)
        let room = bounds.width - x
        let nameWidth = min(textWidth(name) + 1, shows.aside == nil ? room : room * 0.6)
        line(name, x: x, y: y, width: nameWidth)
        x += nameWidth + 8
        if shows.conflict != nil, let warning = Self.warning {
            warning.draw(in: NSRect(x: x, y: y - warning.size.height / 2, width: warning.size.width, height: warning.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += warning.size.width + 8
        }
        if let aside = shows.aside {
            let color = onSelection ? selectionInk : Palette.nsDim
            line(attributed(aside, CellFont.name, color), x: x, y: y, width: bounds.width - x, cut: shows.asideIsPath ? .start : .end)
        }
    }
}

/// An app's route, the whole cell a menu. An app that follows the default reads "Netherlands · Default", so the
/// inherited and the chosen are told apart at a glance.
private final class RouteCell: DrawnCell {
    private struct Shows: Equatable {
        var app = ""
        var label = ""
        var inherited = true
        var color = NSColor.clear
    }

    private var shows = Shows()
    private var press: (() -> Void)?
    private var text = NSAttributedString()
    private var selectedText = NSAttributedString()
    private var wordsWidth: CGFloat = 0
    private static func chevron(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [color])))
    }
    private static let chevron = chevron(Palette.nsDim)
    private static let selectedChevron = chevron(selectionInk)

    func show(_ app: String, press: @escaping () -> Void) {
        self.press = press
        let s = AppModel.shared.setup
        let current = s.apps[app]
        let id = current ?? s.defaultRoute
        let new = Shows(app: app, label: s.label(id), inherited: current == nil, color: s.nsColor(id))
        guard new != shows else { return }
        shows = new
        let font = CellFont.route
        let words = NSMutableAttributedString(attributedString: attributed(new.label, font, Palette.nsText))
        if new.inherited { words.append(attributed(" · Default", font, Palette.nsDim)) }
        text = words
        let selected = NSMutableAttributedString(attributedString: attributed(new.label, font, selectionInk))
        if new.inherited { selected.append(attributed(" · Default", font, selectionInk.withAlphaComponent(0.75))) }
        selectedText = selected
        wordsWidth = textWidth(words) + 1
        toolTip = current == nil ? "Follows the default route" : "Its own route"
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Route for \(AppModel.shared.appName(app))")
        setAccessibilityValue(current == nil ? "\(new.label), default" : new.label)
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
    override func mouseDown(with event: NSEvent) { press?() }

    override func draw(_ dirtyRect: NSRect) {
        let chevron = onSelection ? Self.selectedChevron : Self.chevron
        let chevronWidth = chevron?.size.width ?? 8
        let chrome: CGFloat = 8 + 6 + 6 + 6 + chevronWidth + 9
        let textWidth = min(wordsWidth, bounds.width - chrome)
        let height: CGFloat = 24
        let chip = NSRect(x: 0.5, y: floor(bounds.midY - height / 2) + 0.5, width: floor(textWidth + chrome), height: height - 1)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let tint = onSelection ? selectionInk : shows.inherited ? Palette.nsDim : shows.color
        let capsule = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
        tint.withAlphaComponent(shows.inherited ? 0.08 : 0.14).setFill()
        capsule.fill()
        tint.withAlphaComponent(shows.inherited ? (contrast ? 0.45 : 0.18) : (contrast ? 0.6 : 0.3)).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        // The slash: a capsule a fifth as wide as it is tall, at the logo's angle.
        let slashCentre = NSPoint(x: chip.minX + 8 + 3, y: chip.midY)
        var turn = AffineTransform(translationByX: slashCentre.x, byY: slashCentre.y)
        turn.rotate(byDegrees: 18)
        let slash = NSBezierPath(roundedRect: NSRect(x: -1.5, y: -6, width: 3, height: 12), xRadius: 1.5, yRadius: 1.5)
        slash.transform(using: turn)
        (onSelection ? selectionInk : shows.color).setFill()
        slash.fill()
        line(onSelection ? selectedText : text, x: chip.minX + 8 + 6 + 6, y: chip.midY, width: textWidth, cut: .middle)
        if let chevron {
            chevron.draw(in: NSRect(x: chip.maxX - 9 - chevronWidth, y: chip.midY - chevron.size.height / 2, width: chevronWidth, height: chevron.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// This week's bytes, with a bar measured against the busiest app in its route's colour.
private final class WeekRowCell: DrawnCell {
    private struct Shows: Equatable {
        var text = "–"
        var fraction: CGFloat?
        var color: NSColor?
    }

    private var shows: Shows?
    private var plain = NSAttributedString()
    private var selected = NSAttributedString()
    private var width: CGFloat = 56

    func show(_ app: String, bytes: Int64?, peak: Int64) {
        var new = Shows(text: bytes.map(Units.bytes) ?? "–")
        if let bytes, peak > 0 {
            let s = AppModel.shared.setup
            let route = s.routeOf(app)
            new.fraction = CGFloat(bytes) / CGFloat(peak)
            new.color = bytes > 0 && route != BLOCK ? s.nsColor(route) : nil
        }
        guard new != shows else { return }
        shows = new
        plain = attributed(new.text, CellFont.number, Palette.nsDim)
        selected = attributed(new.text, CellFont.number, selectionInk)
        width = textWidth(plain)
        toolTip = bytes.map { "\($0.formatted()) bytes" } ?? "No recorded data"
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(bytes == nil ? "No data this week" : new.text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        line(onSelection ? selected : plain, x: bounds.maxX - width, y: bounds.midY, width: width)
        guard let fraction = shows?.fraction else { return }
        let bar = NSRect(x: bounds.maxX - max(56, width) - 10 - 56, y: bounds.midY - 2, width: 56, height: 4)
        (onSelection ? selectionInk.withAlphaComponent(0.3) : Palette.nsHigh).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        if let color = shows?.color {
            (onSelection ? selectionInk : color).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(4, 56 * fraction), height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }
}
