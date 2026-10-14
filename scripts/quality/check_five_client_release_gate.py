#!/usr/bin/env python3
"""Reject accidental five-client external-release claims while P0 evidence is open."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "docs" / "release" / "FIVE_CLIENT_RELEASE_GATE.json"
WINDOWS = ROOT / "clients" / "windows" / "release" / "release-readiness.json"
ANDROID_BUILD = ROOT / "clients" / "android" / "OrbitTermAndroid" / "app" / "build.gradle.kts"
IOS_SESSION_MANAGER = ROOT / "OrbitTerm" / "Core" / "SessionManager.swift"
ANDROID_RDP = ROOT / "clients" / "android" / "OrbitTermAndroid" / "domain" / "src" / "main" / "java" / "com" / "orbitterm" / "android" / "domain" / "remote" / "RemoteDesktopAdapter.kt"

REQUIRED_CLIENTS = {"macos", "windows", "linux", "ios", "android"}
REQUIRED_P0 = {"cross-platform-asset-tombstones", "large-transfer-interactive-concurrency"}
OPEN_STATUSES = {"not-started", "in-progress", "blocked"}


def fail(message: str) -> None:
    raise SystemExit(f"five-client release gate failed: {message}")


def main() -> int:
    for path in (GATE, WINDOWS, ANDROID_BUILD, IOS_SESSION_MANAGER, ANDROID_RDP):
        if not path.is_file():
            fail(f"missing {path.relative_to(ROOT)}")

    data = json.loads(GATE.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        fail("unsupported schema_version")
    if data.get("release_scope") != "internal-validation-only":
        fail("release scope must remain internal-validation-only until evidence is recorded")
    if data.get("external_distribution_enabled") is not False:
        fail("external distribution cannot be enabled while shared P0 evidence is open")

    clients = set(data.get("required_clients", []))
    if clients != REQUIRED_CLIENTS:
        fail("required_clients must be exactly macos, windows, linux, ios, android")
    posture = data.get("client_posture", {})
    if set(posture) != REQUIRED_CLIENTS:
        fail("client_posture must cover every required client")
    for client, details in posture.items():
        if not details.get("distribution") or not details.get("blockers"):
            fail(f"{client} is missing distribution posture or blockers")

    blockers = {item.get("id"): item for item in data.get("shared_p0_blockers", [])}
    if set(blockers) != REQUIRED_P0:
        fail("shared P0 blocker set has changed")
    for blocker_id, blocker in blockers.items():
        if blocker.get("status") not in OPEN_STATUSES or not blocker.get("required_evidence"):
            fail(f"{blocker_id} must remain open with explicit required evidence")

    windows = json.loads(WINDOWS.read_text(encoding="utf-8"))
    if windows.get("external_distribution_enabled") is not False:
        fail("Windows release readiness enables external distribution")
    if "multiplatform-alpha" not in ANDROID_BUILD.read_text(encoding="utf-8"):
        fail("Android version must retain its alpha qualifier until production evidence exists")
    if 'detail: "当前平台尚未开放远程桌面"' not in IOS_SESSION_MANAGER.read_text(encoding="utf-8"):
        fail("iOS RDP must remain explicitly unavailable")
    if "RemoteDesktopRuntimeCapability.unavailable" not in ANDROID_RDP.read_text(encoding="utf-8"):
        fail("Android RDP must remain fail-closed")

    print("Five-client external release remains correctly blocked by open evidence gates.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
