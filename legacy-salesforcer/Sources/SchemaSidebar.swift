import AppKit
import Foundation

final class SchemaSidebarController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let view = NSView()
    private let service = MetadataService()
    private let objectSearch = NSSearchField()
    private let fieldSearch = NSSearchField()
    private let objectTable = NSTableView()
    private let fieldTable = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Loading cached schema…")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let insertButton = NSButton(title: "Insert Field", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy API Name", target: nil, action: nil)
    private var objects: [SchemaObject] = []
    private var fields: [SchemaField] = []
    private var filteredObjects: [SchemaObject] = []
    private var filteredFields: [SchemaField] = []
    private var selectedObject: SchemaObject?
    var insertField: ((String) -> Void)?

    override init() {
        super.init()
        build()
        loadInitial()
    }

    func pause() { service.pause() }
    func resume() { service.resume(); if objects.isEmpty { refresh(interactive: false) } }
    func shutdown() { service.shutdown() }

    func completionObjects() -> [SchemaObject] { objects }

    func completionFields(object apiName: String, completion: @escaping ([SchemaField]) -> Void) {
        if selectedObject?.apiName.caseInsensitiveCompare(apiName) == .orderedSame, !fields.isEmpty {
            completion(fields)
            return
        }
        service.cachedFields(object: apiName) { [weak self] cached, _ in
            completion(cached)
            guard cached.isEmpty, let self else { return }
            self.service.refreshFields(object: apiName) { response in
                if response.ok, let refreshed = response.fields { completion(refreshed) }
            }
        }
    }

    private func build() {
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8; root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let header = NSStackView(); header.orientation = .horizontal
        let title = NSTextField(labelWithString: "Salesforce Schema"); title.font = .boldSystemFont(ofSize: 14)
        refreshButton.target = self; refreshButton.action = #selector(refreshClicked)
        header.addArrangedSubview(title); header.addArrangedSubview(NSView()); header.addArrangedSubview(refreshButton); root.addArrangedSubview(header)
        objectSearch.placeholderString = "Search objects"; objectSearch.delegate = self; objectSearch.target = self; objectSearch.action = #selector(searchChanged); root.addArrangedSubview(objectSearch)
        root.addArrangedSubview(makeScroll(table: objectTable, identifier: "object", height: 190))
        fieldSearch.placeholderString = "Search fields"; fieldSearch.delegate = self; fieldSearch.target = self; fieldSearch.action = #selector(searchChanged); fieldSearch.isEnabled = false; root.addArrangedSubview(fieldSearch)
        root.addArrangedSubview(makeScroll(table: fieldTable, identifier: "field", height: 250))
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); root.addArrangedSubview(status)
        let buttons = NSStackView(); buttons.orientation = .horizontal
        insertButton.target = self; insertButton.action = #selector(insertSelected); insertButton.isEnabled = false
        copyButton.target = self; copyButton.action = #selector(copySelected); copyButton.isEnabled = false
        buttons.addArrangedSubview(copyButton); buttons.addArrangedSubview(insertButton); root.addArrangedSubview(buttons)
    }

    private func makeScroll(table: NSTableView, identifier: String, height: CGFloat) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = identifier.capitalized
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(tableDoubleClicked)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true; return scroll
    }

    private func loadInitial() {
        service.cachedObjects { [weak self] objects, date in
            guard let self else { return }; self.setObjects(objects)
            if objects.isEmpty { self.status.stringValue = "Connect Salesforce to load objects." }
            if date == nil || !SchemaHelpers.isFresh(date!) { self.refresh(interactive: false) }
        }
    }

    @objc private func refreshClicked() { refresh(interactive: objects.isEmpty) }
    private func refresh(interactive: Bool) {
        status.stringValue = interactive ? "Opening Salesforce authorization…" : "Refreshing objects in background…"
        service.refreshObjects(interactive: interactive) { [weak self] response in
            guard let self else { return }
            if response.ok, let objects = response.objects { self.setObjects(objects); self.status.stringValue = "\(objects.count) queryable objects" }
            else if response.kind == "auth_required" { self.status.stringValue = "Connect Salesforce to load objects."; self.refreshButton.title = "Connect" }
            else { self.status.stringValue = response.message ?? "Schema refresh failed; cached schema remains available." }
        }
    }

    private func setObjects(_ values: [SchemaObject]) {
        objects = values.filter(\.queryable).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        refreshButton.title = objects.isEmpty ? "Connect" : "Refresh"; applyFilters()
    }
    private func setFields(_ values: [SchemaField]) {
        fields = values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }; applyFilters()
    }
    @objc private func searchChanged() { applyFilters() }
    func controlTextDidChange(_ notification: Notification) { applyFilters() }
    private func applyFilters() {
        filteredObjects = objects.filter { SchemaHelpers.matches(objectSearch.stringValue, label: $0.label, apiName: $0.apiName) }
        filteredFields = fields.filter { SchemaHelpers.matches(fieldSearch.stringValue, label: $0.label, apiName: $0.apiName) }
        objectTable.reloadData(); fieldTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === objectTable ? filteredObjects.count : filteredFields.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("schemaCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id; let label = NSTextField(wrappingLabelWithString: ""); label.maximumNumberOfLines = 2; label.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(label); c.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c
        }()
        if tableView === objectTable { let item = filteredObjects[row]; cell.textField?.stringValue = "\(item.label)\n\(item.apiName)"; cell.textField?.toolTip = item.apiName }
        else { let item = filteredFields[row]; let flags = [item.type, item.calculated ? "formula" : nil, item.nillable ? nil : "required", item.referenceTo.isEmpty ? nil : "→ \(item.referenceTo.joined(separator: ", "))"].compactMap { $0 }.joined(separator: " • "); cell.textField?.stringValue = "\(item.label) — \(item.apiName)\n\(flags)"; cell.textField?.toolTip = "\(item.apiName)\nType: \(item.type)\nFilterable: \(item.filterable)\nSortable: \(item.sortable)\nRelationship: \(item.relationshipName ?? "None")" }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === objectTable, table.selectedRow >= 0 {
            selectedObject = filteredObjects[table.selectedRow]
            fieldSearch.isEnabled = true
            fields = []
            insertButton.isEnabled = false
            copyButton.isEnabled = false
            fieldTable.deselectAll(nil)
            applyFilters()
            loadFields(selectedObject!)
        }
        let hasField = fieldTable.selectedRow >= 0; insertButton.isEnabled = hasField; copyButton.isEnabled = hasField
    }

    private func loadFields(_ object: SchemaObject) {
        status.stringValue = "Loading \(object.label) fields…"
        service.cachedFields(object: object.apiName) { [weak self] fields, date in
            guard let self, self.selectedObject?.apiName == object.apiName else { return }
            if !fields.isEmpty { self.setFields(fields); self.status.stringValue = "\(fields.count) fields" }
            if date == nil || !SchemaHelpers.isFresh(date!) {
                self.service.refreshFields(object: object.apiName) { [weak self] response in
                    guard let self, self.selectedObject?.apiName == object.apiName else { return }
                    if response.ok, let fields = response.fields { self.setFields(fields); self.status.stringValue = "\(fields.count) fields" }
                    else { self.status.stringValue = response.message ?? "Field refresh failed; cached fields remain available." }
                }
            }
        }
    }

    private var selectedField: SchemaField? { let row = fieldTable.selectedRow; return row >= 0 && row < filteredFields.count ? filteredFields[row] : nil }
    @objc private func tableDoubleClicked() { if fieldTable.clickedRow >= 0 { fieldTable.selectRowIndexes(IndexSet(integer: fieldTable.clickedRow), byExtendingSelection: false); insertSelected() } }
    @objc private func insertSelected() { if let field = selectedField { insertField?(field.apiName) } }
    @objc private func copySelected() { if let field = selectedField { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(field.apiName, forType: .string); status.stringValue = "Copied \(field.apiName)" } }
}
