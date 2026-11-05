import SwiftUI

extension Binding {
    /// Binds an identified array element without retaining the element's old array index.
    ///
    /// SwiftUI's projected `ForEach($rows)` bindings subscript the array by the index captured
    /// when a row was built. AppKit can ask a text field for its value once more while a removed
    /// row is animating out, after that index no longer exists. Looking the element up by identity
    /// keeps reorderings correct and lets a disappearing control finish layout without trapping.
    func identifiedElement<Element: Identifiable>(id: Element.ID, fallback: Element) -> Binding<Element>
        where Value == [Element]
    {
        Binding<Element>(
            get: { self.wrappedValue.first(where: { $0.id == id }) ?? fallback },
            set: { updated in
                var elements = self.wrappedValue
                guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
                elements[index] = updated
                self.wrappedValue = elements
            }
        )
    }
}
