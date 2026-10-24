import Testing
@testable import SecretsAgent

struct ToolGuideTests {
    @Test func developerPagesAreOptionalAndExistingToolsKeepTheirEntry() {
        #expect(!ToolGuide.showsTools(saved: nil, hasTools: false))
        #expect(ToolGuide.showsTools(saved: nil, hasTools: true))
        #expect(!ToolGuide.showsTools(saved: false, hasTools: true))
        #expect(ToolGuide.showsTools(saved: true, hasTools: false))
    }

    @Test func restoresOnlyValidGuidePages() {
        #expect(ToolGuide.Step(restoring: -1) == .key)
        #expect(ToolGuide.Step(restoring: 99) == .key)
        #expect(ToolGuide.Step(restoring: 3) == .launch)
        #expect(ToolGuide.Step.allCases.count == 5)
    }

    @Test func prerequisitesDoNotTreatSetupOrCopyAsASuccessfulLaunch() {
        #expect(!ToolGuide.Step.key.canContinue(keyReady: false, toolReady: false, helperReady: false))
        #expect(ToolGuide.Step.key.canContinue(keyReady: true, toolReady: false, helperReady: false))
        #expect(!ToolGuide.Step.tool.canContinue(keyReady: true, toolReady: false, helperReady: false))
        #expect(ToolGuide.Step.helper.canContinue(keyReady: false, toolReady: true, helperReady: true))
        #expect(!ToolGuide.Step.helper.canContinue(keyReady: true, toolReady: true, helperReady: false))
        #expect(!ToolGuide.Step.launch.canContinue(keyReady: true, toolReady: true, helperReady: true))
        #expect(ToolGuide.Step.launch.canContinue(keyReady: true, toolReady: true, helperReady: true, launchConfirmed: true))
        #expect(!ToolGuide.Step.launch.canContinue(keyReady: true, toolReady: false, helperReady: true, launchConfirmed: true))
        #expect(!ToolGuide.Step.launch.canContinue(keyReady: true, toolReady: true, helperReady: false, launchConfirmed: true))
    }
}
