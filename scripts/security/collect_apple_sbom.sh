#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_FILE="${1:?usage: collect_apple_sbom.sh <output-file>}"
VERSION="${ORBITTERM_RELEASE_VERSION:-1.0.1}"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

python3 - "$ROOT" "$OUT_FILE" "$VERSION" <<'PY'
import json
import sys
import re
from pathlib import Path
from urllib.parse import quote

root = Path(sys.argv[1])
output = Path(sys.argv[2])
version = sys.argv[3]
resolved = json.loads((root / "OrbitTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
cargo_lock_text = (root / "orbit-core/Cargo.lock").read_text()
freerdp_manifest_path = root / "third_party/freerdp/manifest.json"
freerdp_manifest = json.loads(freerdp_manifest_path.read_text())

def cargo_packages(lock_text):
    packages = []
    for block in lock_text.split("[[package]]")[1:]:
        def value(name):
            match = re.search(rf'^\s*{re.escape(name)}\s*=\s*"([^"]+)"\s*$', block, re.MULTILINE)
            return match.group(1) if match else None
        name = value("name")
        version = value("version")
        if name and version:
            packages.append({
                "name": name,
                "version": version,
                "source": value("source"),
                "checksum": value("checksum"),
            })
    return packages

components = [
    {
        "type": "application",
        "name": "OrbitTerm",
        "version": version,
        "bom-ref": f"pkg:generic/orbitterm@{quote(version)}",
        "properties": [{"name": "org.orbitterm.source", "value": "client"}],
    }
]

for pin in sorted(resolved.get("pins", []), key=lambda item: item["identity"]):
    state = pin.get("state", {})
    component_version = state.get("version") or state.get("revision", "unversioned")
    identity = pin["identity"]
    components.append({
        "type": "library",
        "name": identity,
        "version": component_version,
        "bom-ref": f"pkg:swift/{quote(identity)}@{quote(component_version)}",
        "externalReferences": [{"type": "vcs", "url": pin.get("location", "")}],
        "properties": [{"name": "org.orbitterm.source.revision", "value": state.get("revision", "")}],
    })

for package in sorted(cargo_packages(cargo_lock_text), key=lambda item: (item["name"], item["version"])):
    name = package["name"]
    component_version = package["version"]
    purl = f"pkg:cargo/{quote(name)}@{quote(component_version)}"
    component = {
        "type": "library",
        "name": name,
        "version": component_version,
        "bom-ref": purl,
        "purl": purl,
    }
    source = package.get("source")
    if source:
        component["externalReferences"] = [{"type": "distribution", "url": source}]
    if package.get("checksum"):
        component["hashes"] = [{"alg": "SHA-256", "content": package["checksum"]}]
    components.append(component)

components.append({
    "type": "library",
    "name": freerdp_manifest["component"],
    "version": freerdp_manifest["version"],
    "bom-ref": f"pkg:generic/freerdp@{quote(freerdp_manifest['version'])}",
    "hashes": [{"alg": "SHA-256", "content": freerdp_manifest["sha256"]}],
    "licenses": [{"license": {"id": freerdp_manifest["license"]}}],
    "externalReferences": [{"type": "distribution", "url": freerdp_manifest["source"]}],
    "properties": [
        {"name": "org.orbitterm.source.revision", "value": freerdp_manifest["tagCommit"]},
        {"name": "org.orbitterm.integration", "value": "embedded-native-runtime"},
    ],
})

for dependency in freerdp_manifest.get("dependencies", []):
    components.append({
        "type": "library",
        "name": dependency["component"],
        "version": dependency["version"],
        "bom-ref": f"pkg:generic/{quote(dependency['component'].lower())}@{quote(dependency['version'])}",
        "hashes": [{"alg": "SHA-256", "content": dependency["sha256"]}],
        "licenses": [{"license": {"id": dependency["license"]}}],
        "externalReferences": [{"type": "distribution", "url": dependency["source"]}],
        "properties": [{"name": "org.orbitterm.required-by", "value": "FreeRDP"}],
    })

document = {
    "$schema": "https://cyclonedx.org/schema/bom-1.5.schema.json",
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "version": 1,
    "metadata": {
        "component": components[0],
        "properties": [
            {"name": "org.orbitterm.spm-lock.sha256", "value": __import__("hashlib").sha256((root / "OrbitTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_bytes()).hexdigest()},
            {"name": "org.orbitterm.cargo-lock.sha256", "value": __import__("hashlib").sha256((root / "orbit-core/Cargo.lock").read_bytes()).hexdigest()},
            {"name": "org.orbitterm.freerdp-manifest.sha256", "value": __import__("hashlib").sha256(freerdp_manifest_path.read_bytes()).hexdigest()},
        ],
    },
    "components": components[1:],
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n")
PY

echo "Apple SBOM written to $OUT_FILE"
