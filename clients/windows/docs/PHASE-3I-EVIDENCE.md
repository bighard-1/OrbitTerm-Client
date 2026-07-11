# Phase 3I Evidence: Full WinUI Host Build Gate

Goal: validate the Windows App XAML project on a real Windows host instead of
relying only on non-UI cross-platform builds.

## Implementation

- Ran the full WinUI build on the remote Windows host without the skip flag.
- Identified invalid WPF-style `MinWidth` and `MinHeight` attributes on the
  WinUI `Window` root.
- Moved the release quality window size policy into `MainWindow.xaml.cs` using
  WinUI `AppWindow.Resize`.
- Updated release quality static checks to reject unsupported root window size
  attributes and verify the code-side size policy.

## Validation

- Initial full WinUI host build: Failed with XAML compiler errors for
  unsupported `Window.MinWidth` and `Window.MinHeight`.
- Local cross-platform Windows toolchain gate after fix: Passed.
- Remote Windows full WinUI host build after fix: Passed with static checks,
  non-UI builds, 57/57 security tests, and full WinUI solution build.
- Sensitive material scan: Passed.
- Generated `bin`/`obj` cleanup check: Passed locally and on the remote
  Windows validation directory.

## Review Notes

- The fix keeps XAML compatible with WinUI 3 instead of carrying over WPF-style
  window attributes.
- The release quality gate now protects against reintroducing unsupported root
  `Window` size attributes.
