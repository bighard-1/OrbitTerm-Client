#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="${DOTNET:-dotnet}"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$1"
}

command -v "$DOTNET" >/dev/null 2>&1 || fail "dotnet SDK not found"

"$ROOT/scripts/check_windows_static.sh"

for project in \
  "$ROOT/src/OrbitTerm.NativeBridge/OrbitTerm.NativeBridge.csproj" \
  "$ROOT/src/OrbitTerm.Terminal/OrbitTerm.Terminal.csproj" \
  "$ROOT/src/OrbitTerm.Application/OrbitTerm.Application.csproj" \
  "$ROOT/src/OrbitTerm.Presentation/OrbitTerm.Presentation.csproj" \
  "$ROOT/src/OrbitTerm.Platform.Windows/OrbitTerm.Platform.Windows.csproj"; do
  "$DOTNET" build "$project" -c Debug
done
pass "Windows non-UI projects build"

"$DOTNET" test "$ROOT/tests/OrbitTerm.Security.Tests/OrbitTerm.Security.Tests.csproj" -c Debug
pass "Windows security tests pass"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    "$DOTNET" build "$ROOT/OrbitTerm.Windows.sln" -c Debug
    pass "Full WinUI solution builds on Windows"
    ;;
  *)
    printf '[INFO] Full WinUI build skipped on %s because Windows App SDK XAML compilation requires Windows.\n' "$(uname -s)"
    ;;
esac

pass "Windows toolchain checks"
