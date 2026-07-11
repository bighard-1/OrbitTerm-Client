# Phase 2B Evidence: Terminal Interaction Ergonomics

## Scope

This phase improves the terminal workbench interaction layer without expanding
native surface area:

- bounded command history in `MainWindowViewModel`;
- previous and next history commands for UI buttons and keyboard shortcuts;
- terminal clear command owned by Presentation;
- input readiness and command-history summaries for the workbench side panel;
- thin WinUI key handling that dispatches Up/Down to tested ViewModel commands.

## Safety Boundary

Terminal history and clear behavior are presentation-only state. They do not
call native terminal APIs, mutate verified sessions, change Host Key state, or
touch credential storage.

The WinUI code-behind does not implement history policy. It only maps keyboard
events to existing ViewModel commands.

## Self-Review

- Raw native methods remain isolated outside the UI layer.
- Command history is bounded to 100 entries.
- Consecutive duplicate commands are suppressed.
- Clearing terminal output does not close the terminal channel.
- Keyboard Up/Down behavior reuses the same tested commands as toolbar buttons.

## Validation Result

Passed gates:

- local Windows client static checks;
- local Windows non-UI project build;
- local Windows security tests: 46 passed, 0 failed;
- Windows host path restriction under `D:\Macmini2`;
- Windows host non-UI project build;
- Windows host security tests: passed with 44 discovered tests;
- `orbit-core` debug and release builds for `x86_64-pc-windows-msvc`;
- `orbit_core.dll` dynamic load and required checked terminal export smoke;
- full WinUI x64 solution build.

The Windows host currently reports 44 discovered managed tests while the local
portable run reports 46. The source package contains the Phase 2B tests and the
local gate validates them; the host discrepancy should be investigated before
release-grade CI is declared complete.
