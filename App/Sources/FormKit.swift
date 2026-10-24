import SwiftUI

// The app's form language, shared by every "new" and "edit" form (items, Sends, folders): a title with a line of
// help, white cards on the window's wash, labels above soft rounded fields, switches at the row's end, and one
// footer bar with the actions.

/// The form's heading: an icon tile, a title, and what the form is for.
struct FormHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            // A solid tile in the brand's blue, like the primary buttons: white symbol, a soft light from the top.
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color.brandFill, Color.brandButton], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.white.opacity(scheme == .dark ? 0.18 : 0.35), lineWidth: 0.5))
                        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.1), radius: 2, y: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A group of fields on a card.
struct FormCard<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.panelStrong, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.panelEdge))
    }
}

/// A label above its field, with an optional note under it.
struct FormField<Content: View>: View {
    let label: LocalizedStringKey
    var note: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }
}

/// Multi-line text in the same soft, rounded look as `SoftFieldStyle`.
struct SoftEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 90
    var monospaced = false
    /// Shown in the empty editor, like a text field's prompt.
    var prompt: LocalizedStringKey?
    @FocusState private var focused: Bool

    private var font: Font { .system(size: monospaced ? 12 : 13, design: monospaced ? .monospaced : .default) }

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            // The system scroller sits inside the box as a grey bar with "Show scroll bars: Always"; it still scrolls.
            .scrollIndicators(.never)
            .focused($focused)
            .overlay(alignment: .topLeading) {
                if let prompt, text.isEmpty {
                    // Lined up with the editor's first line (its text container insets the text by 5pt).
                    Text(prompt).font(font).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// A choice from a list, drawn as a soft field with a chevron (not the system pop-up button).
struct SoftMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var placeholder: LocalizedStringKey = "Choose"
    var accessibilityLabel: LocalizedStringKey

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.0
                } label: {
                    if option.0 == selection {
                        Label { Text(verbatim: option.1) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: option.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let current = options.first(where: { $0.0 == selection })?.1 {
                    Text(verbatim: current).foregroundStyle(.primary)
                } else {
                    Text(placeholder).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// A date in the app's own field: the date as text, typed or picked from a calendar in a popover. The same 38 pt
/// soft field as every other input, so a date no longer reads as a system control dropped into the form (issue #96).
/// Whatever is typed or picked is kept inside `range`.
struct SoftDateField: View {
    /// The field's name: its VoiceOver label and the calendar's title.
    let label: LocalizedStringKey
    @Binding var date: Date
    /// The window the date must stay in. A typed or picked date outside it is pulled to the nearest edge.
    let range: ClosedRange<Date>
    @State private var picking = false
    /// What is in the field while the user is in it. Committed on Return or when the field gives up focus, so a
    /// half-typed date never snaps back at the typist.
    @State private var draft = ""
    /// Bumped when what was typed isn't a date: the field shakes rather than quietly putting the old date back.
    @State private var rejected = 0
    @FocusState private var focused: Bool

    /// The field shows and accepts the same format, in the user's own locale.
    private static let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
    /// A date on its own keeps the time the field already had.
    private static let dayOnly = Date.FormatStyle(date: .abbreviated, time: .omitted)

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .labelsHidden()
                .focused($focused)
                .onSubmit { commit(refuse: true) }
                .onAppear { draft = Self.format.format(date) }
                .onChange(of: date) { _, now in
                    // The calendar, or a shorter deletion window, moved the date. Typing never reaches this: a
                    // typed date only becomes `date` when it is committed.
                    draft = Self.format.format(now)
                }
                .onChange(of: focused) { _, now in
                    // Leaving the field puts it back in the app's format, so it never sits there holding text that
                    // isn't a date. Return is where a typo is worth stopping for.
                    if !now { commit(refuse: false) }
                }
                .shake(on: rejected)
            Button { picking = true } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text("Choose a date"))
            .accessibilityLabel(Text("Choose a date"))
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                DateCalendar(label: label, date: clamped, range: range)
            }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 38)
        .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var clamped: Binding<Date> {
        Binding(get: { date }, set: { date = clamp($0) })
    }

    private func clamp(_ value: Date) -> Date {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Takes what was typed and keeps it in range. Text that isn't a date puts the field back in the app's format;
    /// with `refuse` (Return) it also shakes first, so the typo is noticed rather than silently dropped.
    private func commit(refuse: Bool) {
        if !draft.isEmpty, let typed = parse(draft) {
            date = clamp(typed)
        } else if !draft.isEmpty, refuse {
            rejected += 1
            return
        }
        draft = Self.format.format(date)
    }

    private func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let full = try? Self.format.parseStrategy.parse(trimmed) { return full }
        guard let day = try? Self.dayOnly.parseStrategy.parse(trimmed) else { return nil }
        let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Calendar.current.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day)
    }
}

/// The calendar behind `SoftDateField`: a month at a time in the app's colours, and the time of day under it (a
/// date picker alone has no time, and a Send's expiry is a moment, not a day).
struct DateCalendar: View {
    let label: LocalizedStringKey
    @Binding var date: Date
    let range: ClosedRange<Date>
    @State private var month: Date

    init(label: LocalizedStringKey, date: Binding<Date>, range: ClosedRange<Date>) {
        self.label = label
        _date = date
        self.range = range
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: date.wrappedValue)?.start ?? date.wrappedValue)
    }

    private var calendar: Calendar { Calendar.current }
    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        // Sunday-first, as the calendar's own first weekday says (Monday in most of Europe).
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first) }
    }
    private var symbols: [String] {
        let names = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { names[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { step(-1) } label: { chevron("chevron.left", enabled: canStep(-1)) }
                    .buttonStyle(.plain).disabled(!canStep(-1))
                    .accessibilityLabel(Text("Previous month"))
                Spacer()
                Text(month, format: .dateTime.month(.wide).year())
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { step(1) } label: { chevron("chevron.right", enabled: canStep(1)) }
                    .buttonStyle(.plain).disabled(!canStep(1))
                    .accessibilityLabel(Text("Next month"))
            }
            HStack(spacing: 0) {
                // By position, not by symbol: "T" is both Tuesday and Thursday in English.
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { dayButton(day) } else { Color.clear.frame(height: 26) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text("Time").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                DateStepper(date: $date, range: range)
            }
        }
        .padding(12)
        .frame(width: 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        // Reopened later, the popover shows the month the date is in now, not the one it was left on.
        .onAppear { month = calendar.dateInterval(of: .month, for: date)?.start ?? date }
    }

    private func chevron(_ symbol: String, enabled: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
            .frame(width: 24, height: 24).contentShape(.rect)
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let allowed = day >= calendar.startOfDay(for: range.lowerBound) && day <= range.upperBound
        return Button {
            let clock = calendar.dateComponents([.hour, .minute], from: date)
            let moved = calendar.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day) ?? day
            date = min(max(moved, range.lowerBound), range.upperBound)
        } label: {
            Text(verbatim: "\(calendar.component(.day, from: day))")
                .font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(selected ? Color.white : allowed ? Color.primary : Color.secondary.opacity(0.45))
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(selected ? Color.brandButton : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Text(day, format: .dateTime.month(.wide).day().year()))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func step(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    /// A month is only reachable while some of it is inside the range.
    private func canStep(_ months: Int) -> Bool {
        guard let target = calendar.date(byAdding: .month, value: months, to: month),
              let interval = calendar.dateInterval(of: .month, for: target) else { return false }
        return interval.end > range.lowerBound && interval.start <= range.upperBound
    }
}

/// The time of day under the calendar, in the same soft chrome: the hour and minute, typed or stepped a minute at a
/// time. Not a `DatePicker` — the point of the form's date control is that it looks like the rest of the form.
private struct DateStepper: View {
    @Binding var date: Date
    let range: ClosedRange<Date>
    @State private var text = ""
    @FocusState private var focused: Bool

    /// 24-hour where the system says so, 12-hour with AM/PM where it doesn't.
    private static var format: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { step(-60) } label: { chevron("minus", enabled: canStep(-60)) }
                .buttonStyle(.plain).disabled(!canStep(-60))
                .accessibilityLabel(Text("Earlier"))
            TextField("Time", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: date) { _, now in if !focused { text = Self.format.format(now) } }
                .onChange(of: focused) { _, now in if !now { commit() } }
                .frame(width: 74)
            Button { step(60) } label: { chevron("plus", enabled: canStep(60)) }
                .buttonStyle(.plain).disabled(!canStep(60))
                .accessibilityLabel(Text("Later"))
        }
        .frame(height: 26)
        .background(Color.formInputFill, in: .rect(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .onAppear { text = Self.format.format(date) }
    }

    private func chevron(_ symbol: String, enabled: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
            .frame(width: 22, height: 26).contentShape(.rect)
    }

    private func step(_ seconds: TimeInterval) {
        date = min(max(date.addingTimeInterval(seconds), range.lowerBound), range.upperBound)
    }

    private func canStep(_ seconds: TimeInterval) -> Bool {
        range.contains(date.addingTimeInterval(seconds))
    }

    /// Takes a typed time ("21:30", "9:30 PM"), on the day the field is already on.
    private func commit() {
        defer { text = Self.format.format(date) }
        guard let typed = try? Self.format.parseStrategy.parse(text.trimmingCharacters(in: .whitespaces)),
              let moved = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: typed),
                                                minute: Calendar.current.component(.minute, from: typed),
                                                second: 0, of: date)
        else { return }
        date = min(max(moved, range.lowerBound), range.upperBound)
    }
}

/// A row that opens to reveal a setting the form keeps out of the way until it is wanted, with a one-line summary
/// of what is set while it is closed (issue #97).
struct FormDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    /// Shown at the row's end while it is closed, so a setting that is on does not hide with it.
    var summary: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).font(.system(size: 13))
                    Spacer(minLength: 8)
                    if !isExpanded, let summary {
                        Text(verbatim: summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: summary ?? ""))
            if isExpanded { content }
        }
    }
}

/// The footer every form ends with: a note on the left, Cancel and the primary action on the right.
struct FormFooter<Note: View>: View {
    let action: LocalizedStringKey
    var busy = false
    var disabled = false
    let cancel: () -> Void
    let submit: () -> Void
    @ViewBuilder var note: Note

    var body: some View {
        HStack(spacing: 10) {
            note
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(.appSecondary).keyboardShortcut(.cancelAction)
            Button(action: submit) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(action)
                }
            }
            .buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            .disabled(disabled || busy)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(alignment: .top) { Divider().opacity(0.5) }
    }
}

extension FormFooter where Note == EmptyView {
    init(action: LocalizedStringKey, busy: Bool = false, disabled: Bool = false, cancel: @escaping () -> Void,
         submit: @escaping () -> Void) {
        self.init(action: action, busy: busy, disabled: disabled, cancel: cancel, submit: submit) { EmptyView() }
    }
}

/// Choosing a folder when folders nest ("Work/Dev"): each level opens as a submenu (a cascader), a parent can be
/// chosen itself from the top of its submenu, and the field shows the path as a breadcrumb. With `create`, the menu
/// ends in "New Folder…" (and "New Subfolder of …" for the chosen one): the field turns into a name field in place,
/// Return makes the folder and picks it, Escape or × goes back to the menu.
struct FolderCascader: View {
    let folders: [Grouping]
    @Binding var selection: String?
    /// Makes a folder from its full path ("Work/Servers") and returns its id; nil when it couldn't.
    var create: ((String) async -> String?)?
    /// Naming a new folder: the path it goes inside ("" for the top level), nil when choosing.
    var newFolderIn: Binding<String?> = .constant(nil)

    @State private var name = ""
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    private var path: String? {
        selection.flatMap { id in folders.first { $0.id == id }?.name }
    }

    var body: some View {
        if let parent = newFolderIn.wrappedValue {
            nameField(in: parent)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button { selection = nil } label: { check(selection == nil, "No Folder") }
            if !folders.isEmpty {
                Divider()
                FolderLevel(nodes: FolderNode.tree(folders), selection: $selection)
            }
            if create != nil {
                Divider()
                Button("New Folder…", systemImage: "folder.badge.plus") { startNaming(in: "") }
                if let path {
                    Button("New Subfolder of “\(leaf(path))”…", systemImage: "folder.badge.plus") { startNaming(in: path) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selection == nil ? "tray" : "folder")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let path {
                    // Work › Dev: the parents quiet, the folder itself in full.
                    breadcrumb(path, last: Text(verbatim: leaf(path)).foregroundStyle(.primary))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No Folder").foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .fieldChrome(focused: false)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Folder"))
        .accessibilityValue(Text(verbatim: path ?? String(localized: "No Folder")))
    }

    private func nameField(in parent: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.system(size: 12)).foregroundStyle(.secondary)
                if !parent.isEmpty {
                    breadcrumb(parent + "/", last: Text(verbatim: ""))
                        .lineLimit(1).truncationMode(.head)
                }
                TextField("Folder name", text: $name, prompt: Text(parent.isEmpty ? "e.g. Work/Servers" : "e.g. Servers"))
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: stopNaming)
                    .disabled(busy)
                    .frame(minWidth: 140)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: commit) {
                        Image(systemName: "return").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(trimmed.isEmpty ? 0.04 : 0.1), in: .rect(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain).foregroundStyle(trimmed.isEmpty ? .tertiary : .primary)
                    .disabled(trimmed.isEmpty)
                    .help("Create Folder")
                    .accessibilityLabel(Text("Create Folder"))
                    Button(action: stopNaming) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Cancel")
                    .accessibilityLabel(Text("Cancel New Folder"))
                }
            }
            .font(.system(size: 13))
            .fieldChrome(focused: nameFocused)
            Text(parent.isEmpty ? "Return to create and pick it. Use / to nest." : "Return to create and pick it.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .onAppear { nameFocused = true }
        .transition(.opacity)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func startNaming(in parent: String) {
        name = ""
        withAnimation(.easeOut(duration: 0.15)) { newFolderIn.wrappedValue = parent }
    }

    private func stopNaming() {
        guard !busy else { return }
        withAnimation(.easeOut(duration: 0.15)) { newFolderIn.wrappedValue = nil }
    }

    private func commit() {
        guard let parent = newFolderIn.wrappedValue, let create, !busy else { return }
        // "Work/ Servers /" → "Work/Servers": no empty or padded parts.
        let parts = trimmed.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        let full = ((parent.isEmpty ? [] : [parent]) + parts).joined(separator: "/")
        // Already there: just pick it rather than make a twin.
        if let existing = folders.first(where: { $0.name.compare(full, options: .caseInsensitive) == .orderedSame }) {
            selection = existing.id
            stopNaming()
            return
        }
        busy = true
        Task {
            let id = await create(full)
            busy = false
            if let id {
                selection = id
                stopNaming()
            } else {
                nameFocused = true
            }
        }
    }

    private func leaf(_ path: String) -> String {
        path.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? path
    }

    /// The parents of `path` quietly, each followed by "›", then `last`.
    private func breadcrumb(_ path: String, last: Text) -> Text {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.dropLast().reduce(Text(verbatim: "")) { $0 + Text(verbatim: "\($1) › ").foregroundStyle(.secondary) } + last
    }
}

private extension View {
    /// The soft field look shared by the folder menu and its name field.
    func fieldChrome(focused: Bool) -> some View {
        font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.formInputFill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// One level of the folder tree: leaves are choices, parents open a submenu.
private struct FolderLevel: View {
    let nodes: [FolderNode]
    @Binding var selection: String?

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                if let id = node.folderIds.first {
                    Button { selection = id } label: { check(node.folderIds.contains(selection ?? ""), node.name, symbol: "folder") }
                }
            } else {
                Menu {
                    // The parent itself, when it's a real folder (not just a prefix of its children's names).
                    if let id = node.folderIds.first {
                        Button { selection = id } label: { check(node.folderIds.contains(selection ?? ""), node.name, symbol: "folder") }
                        Divider()
                    }
                    FolderLevel(nodes: node.children, selection: $selection)
                } label: {
                    // A tick on the way to the chosen folder.
                    check(contains(node, selection), node.name, symbol: "folder")
                }
            }
        }
    }

    private func contains(_ node: FolderNode, _ id: String?) -> Bool {
        guard let id else { return false }
        return node.folderIds.contains(id) || node.children.contains { contains($0, id) }
    }
}

@ViewBuilder
private func check(_ on: Bool, _ title: LocalizedStringKey) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}

@ViewBuilder
private func check(_ on: Bool, _ title: String, symbol: String) -> some View {
    Label { Text(verbatim: title) } icon: { Image(systemName: on ? "checkmark" : symbol) }
}
