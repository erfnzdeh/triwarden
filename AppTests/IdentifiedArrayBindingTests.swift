import SwiftUI
import XCTest

@MainActor
final class IdentifiedArrayBindingTests: XCTestCase {
    private struct Row: Identifiable, Equatable {
        let id: UUID
        var text: String
    }

    func testRemovedTextFieldCanReadAndWriteItsStaleBinding() {
        let removed = Row(id: UUID(), text: "draft")
        var rows = [removed]
        let rowsBinding = Binding(get: { rows }, set: { rows = $0 })
        let field = rowsBinding.identifiedElement(id: removed.id, fallback: removed).text

        rows.removeAll()

        XCTAssertEqual(field.wrappedValue, "draft")
        field.wrappedValue = "late AppKit write"
        XCTAssertTrue(rows.isEmpty)
    }

    func testBindingFollowsIdentityAfterRowsReorder() {
        let first = Row(id: UUID(), text: "first")
        let second = Row(id: UUID(), text: "second")
        var rows = [first, second]
        let rowsBinding = Binding(get: { rows }, set: { rows = $0 })
        let field = rowsBinding.identifiedElement(id: first.id, fallback: first).text

        rows.swapAt(0, 1)
        field.wrappedValue = "updated"

        XCTAssertEqual(rows.first(where: { $0.id == first.id })?.text, "updated")
        XCTAssertEqual(rows.first(where: { $0.id == second.id })?.text, "second")
    }
}
