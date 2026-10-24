/// Guide navigation only. These checks never grant access or establish that a program is safe.
public enum ToolGuide {
    public static func showsTools(saved: Bool?, hasTools: Bool) -> Bool { saved ?? hasTools }

    public enum Step: Int, CaseIterable, Sendable {
        case key, tool, helper, launch, daily
        public init(restoring value: Int) { self = Self(rawValue: value) ?? .key }

        public func canContinue(keyReady: Bool, toolReady: Bool, helperReady: Bool, launchConfirmed: Bool = false) -> Bool {
            switch self {
            case .key: keyReady || toolReady
            case .tool: toolReady
            case .helper: toolReady && helperReady
            case .launch: toolReady && helperReady && launchConfirmed
            case .daily: true
            }
        }
    }
}
