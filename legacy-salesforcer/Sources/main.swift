import AppKit
import Carbon
import Foundation

private let appName = "SOQL Quick"
private let previewLimit = 100
private let resultPrefix = "SOQL_QUICK_RESULT:"

struct QueryResponse: Decodable {
    let ok: Bool
    let kind: String?
    let message: String?
    let columns: [String]?
    let textColumns: [Bool]?
    let rows: [[String]]?
    let total: Int?
}

final class QueryRunner {
    private(set) var process: Process?
    private var timeout: DispatchWorkItem?
    private var activeToken: UUID?

    func run(query: String, completion: @escaping (Result<QueryResponse, Error>) -> Void) {
        cancel()
        guard let resourceURL = Bundle.main.resourceURL else {
            completion(.failure(AppError("The app backend could not be located.")))
            return
        }
        let backend = resourceURL.appendingPathComponent("query_backend.R").path
        guard FileManager.default.fileExists(atPath: backend) else {
            completion(.failure(AppError("The bundled R backend is missing.")))
            return
        }
        let rscriptCandidates = ["/usr/local/bin/Rscript", "/opt/homebrew/bin/Rscript", "/usr/bin/Rscript"]
        guard let rscript = rscriptCandidates.first(where: FileManager.default.fileExists) else {
            completion(.failure(AppError("Rscript was not found. Install R, then reopen SOQL Quick.")))
            return
        }

        let task = Process()
        let token = UUID()
        activeToken = token
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        task.executableURL = URL(fileURLWithPath: rscript)
        task.arguments = ["--vanilla", backend]
        var environment = ProcessInfo.processInfo.environment
        environment["SOQL_QUICK_RESOURCE_DIR"] = resourceURL.path
        task.environment = environment
        task.standardInput = input
        task.standardOutput = output
        task.standardError = error
        let capture = ProcessPipeCapture(stdout: output, stderr: error)
        process = task

        task.terminationHandler = { [weak self] finished in
            capture.notify { outputData, errorData in
                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                guard self?.activeToken == token else { return }
                self?.activeToken = nil
                self?.timeout?.cancel()
                self?.timeout = nil
                self?.process = nil
                guard let line = stdout.split(separator: "\n", omittingEmptySubsequences: true)
                    .last(where: { $0.hasPrefix(resultPrefix) }) else {
                    let safeError = stderr.isEmpty ? "The R backend returned no readable response." : String(stderr.prefix(2000))
                    completion(.failure(AppError(safeError)))
                    return
                }
                let json = line.dropFirst(resultPrefix.count)
                do {
                    completion(.success(try JSONDecoder().decode(QueryResponse.self, from: Data(json.utf8))))
                } catch {
                    completion(.failure(AppError("The backend response could not be decoded: \(error.localizedDescription)")))
                }
            }
        }

        do {
            try task.run()
            let request = try JSONSerialization.data(withJSONObject: ["query": query])
            input.fileHandleForWriting.write(request)
            try? input.fileHandleForWriting.close()
        } catch {
            process = nil
            completion(.failure(error))
            return
        }

        let work = DispatchWorkItem { [weak self, weak task] in
            guard let self, self.activeToken == token, let task, task.isRunning else { return }
            self.activeToken = nil
            task.terminate()
            self.process = nil
            DispatchQueue.main.async {
                completion(.failure(AppError("The query timed out after 120 seconds.")))
            }
        }
        timeout = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: work)
    }

    func cancel() {
        activeToken = nil
        timeout?.cancel()
        timeout = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
}

final class QueryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private var queryView: QueryTextView!
    private let splitView = NSSplitView()
    private let schemaSidebar = SchemaSidebarController()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let errorDetailsButton = NSButton(title: "Details", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let runButton = NSButton(title: "Run Query", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Table", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let runner = QueryRunner()
    private let completionPanel = CompletionPanelController()
    private var completionContext: CompletionContext?
    private var errorDetailsWindow: ErrorDetailsWindowController?
    private var fullStatusText = "Ready"
    private var columns: [String] = []
    private var textColumns: [Bool] = []
    private var allRows: [[String]] = []
    private var previewRows: [[String]] { Array(allRows.prefix(previewLimit)) }
    private var queryIsRunning = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        super.init(window: window)
        buildInterface()
        schemaSidebar.insertField = { [weak self] name in self?.insertFieldName(name) }
        completionPanel.accept = { [weak self] item in self?.acceptCompletion(item) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let mainPane = NSView()
        splitView.addArrangedSubview(mainPane)
        splitView.addArrangedSubview(schemaSidebar.view)
        schemaSidebar.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        schemaSidebar.view.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            root.topAnchor.constraint(equalTo: mainPane.topAnchor),
            root.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor)
        ])

        let queryScroll = NSScrollView()
        queryView = QueryTextView(frame: .zero)
        queryView.minSize = NSSize(width: 0, height: 0)
        queryView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        queryView.isVerticallyResizable = true
        queryView.isHorizontallyResizable = true
        queryView.autoresizingMask = [.width]
        queryView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        queryView.textContainer?.widthTracksTextView = false
        queryScroll.documentView = queryView
        queryScroll.hasVerticalScroller = true
        queryScroll.hasHorizontalScroller = true
        queryScroll.borderType = .bezelBorder
        queryScroll.drawsBackground = true
        queryScroll.backgroundColor = .white
        queryView.isEditable = true
        queryView.isSelectable = true
        queryView.allowsUndo = true
        queryView.isRichText = false
        queryView.isAutomaticQuoteSubstitutionEnabled = false
        queryView.isAutomaticDashSubstitutionEnabled = false
        queryView.isAutomaticSpellingCorrectionEnabled = false
        queryView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        queryView.drawsBackground = true
        queryView.usesAdaptiveColorMappingForDarkAppearance = false
        queryView.backgroundColor = .white
        queryView.textColor = .black
        queryView.insertionPointColor = .black
        queryView.selectedTextAttributes = [
            .backgroundColor: NSColor.systemBlue,
            .foregroundColor: NSColor.white
        ]
        queryView.textContainerInset = NSSize(width: 8, height: 8)
        queryView.delegate = self
        queryView.handleCompletionKey = { [weak self] event in self?.handleCompletionKey(event) ?? false }
        queryView.string = "SELECT Id, Name\nFROM Account\nLIMIT 10"
        queryView.textStorage?.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.black
        ], range: NSRange(location: 0, length: queryView.string.utf16.count))
        queryView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        queryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        root.addArrangedSubview(queryScroll)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        runButton.target = self
        runButton.action = #selector(runQuery)
        runButton.keyEquivalent = "\r"
        runButton.keyEquivalentModifierMask = [.command]
        cancelButton.target = self
        cancelButton.action = #selector(cancelQuery)
        cancelButton.isEnabled = false
        copyButton.target = self
        copyButton.action = #selector(copyTable)
        copyButton.isEnabled = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        errorDetailsButton.target = self
        errorDetailsButton.action = #selector(showErrorDetails)
        errorDetailsButton.isHidden = true
        controls.addArrangedSubview(runButton)
        controls.addArrangedSubview(cancelButton)
        controls.addArrangedSubview(spinner)
        controls.addArrangedSubview(statusLabel)
        controls.addArrangedSubview(errorDetailsButton)
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(countLabel)
        controls.addArrangedSubview(copyButton)
        root.addArrangedSubview(controls)

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.borderType = .bezelBorder
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableScroll.documentView = tableView
        root.addArrangedSubview(tableScroll)
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitView.setPosition(max(600, self.splitView.bounds.width - 320), ofDividerAt: 0)
        }
    }

    func showAndFocus() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(queryView)
    }

    func shutdown() {
        runner.cancel()
        completionPanel.close()
        schemaSidebar.shutdown()
    }

    @objc func toggleSchemaBrowser() {
        schemaSidebar.view.isHidden.toggle()
        splitView.adjustSubviews()
    }

    private func insertFieldName(_ name: String) {
        completionPanel.close()
        let range = queryView.selectedRange()
        guard queryView.shouldChangeText(in: range, replacementString: name) else { return }
        queryView.textStorage?.replaceCharacters(in: range, with: name)
        queryView.didChangeText()
        queryView.setSelectedRange(NSRange(location: range.location + name.utf16.count, length: 0))
        window?.makeFirstResponder(queryView)
    }

    @objc private func runQuery() {
        completionPanel.close()
        let query = queryView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { setStatus("Enter a SOQL query before running it.", error: true); return }
        guard !queryIsRunning else { return }
        startRunning()
        runner.run(query: query) { [weak self] result in
            guard let self else { return }
            self.stopRunning()
            switch result {
            case .failure(let error):
                self.setStatus(error.localizedDescription, error: true)
            case .success(let response):
                guard response.ok else {
                    self.setStatus(response.message ?? "Salesforce rejected the query.", error: true)
                    return
                }
                self.columns = response.columns ?? []
                self.textColumns = response.textColumns ?? []
                self.allRows = response.rows ?? []
                self.rebuildColumns()
                let total = response.total ?? self.allRows.count
                self.countLabel.stringValue = "\(total) rows"
                self.copyButton.isEnabled = !self.columns.isEmpty
                self.setStatus(total == 0 ? "Query succeeded; no records returned." : "Query succeeded.", error: false)
            }
        }
    }

    @objc private func cancelQuery() {
        guard queryIsRunning else { return }
        runner.cancel()
        stopRunning()
        setStatus("Query canceled.", error: false)
    }

    private func startRunning() {
        schemaSidebar.pause()
        queryIsRunning = true
        runButton.isEnabled = false
        cancelButton.isEnabled = true
        copyButton.isEnabled = false
        spinner.startAnimation(nil)
        setStatus("Running query… Salesforce login may open in your browser.", error: false)
    }

    private func stopRunning() {
        queryIsRunning = false
        runButton.isEnabled = true
        cancelButton.isEnabled = false
        spinner.stopAnimation(nil)
        schemaSidebar.resume()
    }

    private func setStatus(_ text: String, error: Bool) {
        fullStatusText = text
        statusLabel.stringValue = text.replacingOccurrences(of: "\n", with: " ")
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = text
        errorDetailsButton.isHidden = !error
    }

    @objc private func showErrorDetails() {
        let controller = ErrorDetailsWindowController(message: fullStatusText)
        errorDetailsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func textDidChange(_ notification: Notification) { updateCompletions(explicit: false) }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !queryView.hasMarkedText() else { return }
        if completionPanel.isVisible { updateCompletions(explicit: false) }
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control) {
            updateCompletions(explicit: true); return true
        }
        guard completionPanel.isVisible else { return false }
        switch event.keyCode {
        case 125: completionPanel.move(1); return true
        case 126: completionPanel.move(-1); return true
        case 48: completionPanel.acceptSelected(); return true
        case 36, 76:
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option]) {
                completionPanel.acceptSelected(); return true
            }
            return false
        case 53: completionPanel.close(); return true
        default: return false
        }
    }

    private func updateCompletions(explicit: Bool) {
        guard !queryIsRunning else { completionPanel.close(); return }
        let cursor = queryView.selectedRange().location
        let context = SOQLCompletion.context(in: queryView.string, cursor: cursor)
        guard explicit || !context.fragment.isEmpty else { completionPanel.close(); return }
        completionContext = context
        var items = SOQLCompletion.termItems(for: context)
        if context.schemaKind == .object {
            items += schemaSidebar.completionObjects().compactMap {
                SOQLCompletion.schemaItem(apiName: $0.apiName, label: $0.label, detail: "Salesforce object", kind: .object, fragment: context.fragment)
            }
            showCompletionItems(items, context: context)
        } else if context.schemaKind == .field, let object = context.objectName {
            showCompletionItems(items, context: context)
            schemaSidebar.completionFields(object: object) { [weak self] fields in
                guard let self else { return }
                let current = SOQLCompletion.context(in: self.queryView.string, cursor: self.queryView.selectedRange().location)
                guard current == context else { return }
                let fieldItems = fields.compactMap {
                    SOQLCompletion.schemaItem(apiName: $0.apiName, label: $0.label, detail: $0.type, kind: .field, fragment: context.fragment)
                }
                self.showCompletionItems(items + fieldItems, context: context)
            }
        } else {
            showCompletionItems(items, context: context)
        }
    }

    private func showCompletionItems(_ items: [CompletionItem], context: CompletionContext) {
        let sorted = SOQLCompletion.sorted(items)
        guard !sorted.isEmpty else { completionPanel.close(); return }
        var actual = NSRange()
        let rect = queryView.firstRect(forCharacterRange: NSRange(location: context.replacementRange.location, length: 0), actualRange: &actual)
        completionPanel.show(sorted, at: NSPoint(x: rect.minX, y: rect.minY), parent: window)
    }

    private func acceptCompletion(_ item: CompletionItem) {
        guard let context = completionContext else { return }
        let current = SOQLCompletion.context(in: queryView.string, cursor: queryView.selectedRange().location)
        guard current.replacementRange == context.replacementRange else { return }
        guard queryView.shouldChangeText(in: current.replacementRange, replacementString: item.insertionText) else { return }
        queryView.textStorage?.replaceCharacters(in: current.replacementRange, with: item.insertionText)
        queryView.didChangeText()
        let offset = item.cursorOffset ?? item.insertionText.utf16.count
        queryView.setSelectedRange(NSRange(location: current.replacementRange.location + offset, length: 0))
        completionPanel.close()
        window?.makeFirstResponder(queryView)
    }

    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for (index, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = name
            column.width = min(max(CGFloat(name.count * 8), 110), 280)
            column.minWidth = 70
            column.maxWidth = 600
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { previewRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn),
              row < previewRows.count,
              columnIndex < previewRows[row].count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
            view.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()
        let value = previewRows[row][columnIndex]
        cell.textField?.stringValue = value
        cell.textField?.toolTip = value
        return cell
    }

    @objc private func copyTable() {
        guard !columns.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TSVFormatter.table(columns: columns, textColumns: textColumns, rows: allRows), forType: .string)
        setStatus("Copied \(allRows.count) rows to the clipboard.", error: false)
    }
}

final class ErrorDetailsWindowController: NSWindowController {
    private let message: String

    init(message: String) {
        self.message = message
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 320), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Query Error Details"
        window.minSize = NSSize(width: 420, height: 220)
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.string = message
        text.isVerticallyResizable = true; text.isHorizontallyResizable = true; text.textContainer?.widthTracksTextView = false
        scroll.documentView = text
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyMessage))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        let buttons = NSStackView(views: [NSView(), copy, close]); buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll); content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    @objc private func copyMessage() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message, forType: .string) }
    @objc private func closeWindow() { close() }
}

final class PreferencesWindowController: NSWindowController {
    private let keyPopup = NSPopUpButton()
    private let controlCheck = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let optionCheck = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let commandCheck = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let shiftCheck = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    var onSave: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SOQL Quick Settings"
        super.init(window: window)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let content = window?.contentView else { return }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Shortcut key:"), keyPopup],
            [NSTextField(labelWithString: "Modifiers:"), NSStackView(views: [controlCheck, optionCheck, commandCheck, shiftCheck])]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        keyPopup.addItems(withTitles: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init))
        keyPopup.selectItem(withTitle: UserDefaults.standard.string(forKey: "hotKey") ?? "S")
        let modifiers = UserDefaults.standard.integer(forKey: "hotModifiers")
        let saved = modifiers > 0 ? modifiers : Int(controlKey | optionKey)
        controlCheck.state = (saved & Int(controlKey)) != 0 ? .on : .off
        optionCheck.state = (saved & Int(optionKey)) != 0 ? .on : .off
        commandCheck.state = (saved & Int(cmdKey)) != 0 ? .on : .off
        shiftCheck.state = (saved & Int(shiftKey)) != 0 ? .on : .off

        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    @objc private func closeWindow() { close() }
    @objc private func saveSettings() {
        var modifiers = 0
        if controlCheck.state == .on { modifiers |= Int(controlKey) }
        if optionCheck.state == .on { modifiers |= Int(optionKey) }
        if commandCheck.state == .on { modifiers |= Int(cmdKey) }
        if shiftCheck.state == .on { modifiers |= Int(shiftKey) }
        guard modifiers != 0 else { NSSound.beep(); return }
        UserDefaults.standard.set(keyPopup.titleOfSelectedItem ?? "S", forKey: "hotKey")
        UserDefaults.standard.set(modifiers, forKey: "hotModifiers")
        onSave?()
        close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var queryWindow: QueryWindowController!
    private var preferencesWindow: PreferencesWindowController?
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["hotKey": "S", "hotModifiers": Int(controlKey | optionKey)])
        queryWindow = QueryWindowController()
        buildMainMenu()
        buildMenuBar()
        installHotKeyHandler()
        registerHotKey()
        queryWindow.showAndFocus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        queryWindow?.shutdown()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSchema = NSMenuItem(title: "Toggle Schema Browser", action: #selector(toggleSchemaBrowser), keyEquivalent: "b")
        toggleSchema.keyEquivalentModifierMask = [.command, .option]
        toggleSchema.target = self
        viewMenu.addItem(toggleSchema)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        queryWindow.showAndFocus()
        return true
    }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: appName)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open SOQL Quick", action: #selector(showQueryWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SOQL Quick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        for item in menu.items where item !== quitItem { item.target = self }
        statusItem.menu = menu
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.id == 1 {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.queryWindow.showAndFocus() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func registerHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        let key = UserDefaults.standard.string(forKey: "hotKey") ?? "S"
        let modifiers = UInt32(UserDefaults.standard.integer(forKey: "hotModifiers"))
        let keyCode = keyCodeForLetter(key)
        let signature = OSType(UInt32(ascii: "SOQL"))
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSSound.beep() }
    }

    private func keyCodeForLetter(_ letter: String) -> Int {
        let codes: [String: Int] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46]
        return codes[letter.uppercased()] ?? 1
    }

    @objc private func showQueryWindow() { queryWindow.showAndFocus() }
    @objc private func toggleSchemaBrowser() { queryWindow.toggleSchemaBrowser() }
    @objc private func showSettings() {
        let controller = PreferencesWindowController()
        controller.onSave = { [weak self] in self?.registerHotKey() }
        preferencesWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

extension UInt32 {
    init(ascii: String) {
        self = ascii.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
