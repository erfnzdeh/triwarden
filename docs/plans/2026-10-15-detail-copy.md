# Item Detail Copy Actions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make detail values easy to select and copy with visible, accessible actions.

**Architecture:** Reuse the existing clipboard methods and guarded copy feedback. Add a shared copy control and a website row; reuse FieldLine for the username. Preserve the existing card surfaces and masking behavior.

**Tech Stack:** SwiftUI, AppKit, XCTest UI tests.

---

### Task 1: Shared copy controls
- Create `App/Sources/DetailCopyButton.swift` with visible Copy/Copied text, a 32-point target, field-specific accessibility labels, guarded secret copying, and temporary success feedback.
- Replace the small icon in `App/Sources/VaultView.swift` FieldLine; put each field label above its selectable value to fit long values and narrow panes.

### Task 2: Username, website, notes
- Add a labeled username FieldLine to HeroCard and retain only the host in its subtitle.
- Create `App/Sources/WebsiteDetailRow.swift` with selectable full address text plus separate Copy and Open buttons.
- Add a copy action to the existing Notes heading.
- Add visible copy symbols and tooltips to password/code tiles without changing their clipboard logic.

### Task 3: Verify
- Build using `make build` and resolve compiler errors.
- Verify username and full website clipboard values with focused XCTest UI tests; verify copying does not reveal the password.
- Render detail snapshots and inspect light/dark appearances.
- Review `git diff --check` and the final diff for scope and clipboard behavior.
