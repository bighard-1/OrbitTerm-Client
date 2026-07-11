# Phase 5C Evidence: Snippet Variables, Search, And Grouping

## Scope

Phase 5C completes the local Snippet interaction layer with `{{variable}}` placeholders, bounded variable prompting, live search, and category-grouped presentation. Resolved commands continue through the existing terminal or checked Batch boundaries.

## Safety Boundary

- Variable names accept only ASCII letters, digits, and underscores inside exact double-brace placeholders.
- Duplicate variables are requested once and processed in deterministic ordinal order.
- Every required variable must be present, at most 1024 characters, and contain no control characters.
- The resolved command must be non-empty, at most 8192 characters, contain no control characters, and contain no unresolved placeholders.
- Existing insert, send, and Batch commands defensively reject templates with unresolved variables even if invoked without the WinUI prompt.
- The WinUI dialog only collects values. A pure resolver performs extraction, validation, and replacement, and the ViewModel validates the resolved command again before use.
- Search is case-insensitive across title, command, and category. It derives grouped view state without mutating or persisting a filtered subset.
- Category groups are ordered case-insensitively, followed by title ordering within each group.

## Review Findings Resolved

- Initial XAML action bindings attempted to bind enabled state to `ICommand.CanExecute`, which is a method rather than a bindable property. Explicit derived selection/terminal state properties now drive enabled state while commands retain their own guards.
- Raw command entry points initially assumed the WinUI prompt would always be used. They now detect unresolved placeholders and fail closed.
- Filter refresh now clears a selected item when it is outside the current derived result, preventing actions on an invisible Snippet.
- The first grouped UI used nested `ListView` controls sharing one selected item. It compiled but crashed `Microsoft.UI.Xaml.dll` at startup with `0xc000027b` / `E_INVALIDARG`. It was replaced with one `ListView` backed by the supported grouped `CollectionViewSource`; the rebuilt R2 remained running during the five-second startup smoke test.

## Verification

- Windows automated tests: 76 passed, 0 failed, 0 skipped.
- Windows WinUI x64 Release and XAML build: passed.
- Windows static security and release gates: passed.
- Self-contained Windows x64 R2 startup smoke: passed.
- Local XAML XML structure validation: passed.
- Full Rust core tests: 287 passed, 0 failed, 2 environment fixtures ignored.
- Rust Clippy with warnings denied: passed.
- Remote validation was confined to `D:\\Macmini2\\phase-5c-validate`; the archive was confined to `D:\\Macmini2\\orbitterm-phase-5c.zip`.

## Residual Boundary

Snippet synchronization is not enabled. Local Snippets remain protected by current-user DPAPI, so cross-device sync requires a separately versioned portable encryption envelope and explicit conflict policy. Variable values are intentionally never persisted.
