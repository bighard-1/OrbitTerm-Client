# FreeRDP integration policy

OrbitTerm embeds the FreeRDP client libraries; it does not launch or wrap a
standalone `xfreerdp` process. The authoritative component versions, source
URLs and checksums are stored in `manifest.json`.

The default application build remains fail-closed when the audited runtime is
absent. `scripts/build_freerdp_macos.sh` downloads only pinned release
archives, verifies every SHA-256 checksum before extraction, and produces a
minimal client runtime under `.tooling/freerdp-macos/install`.

The upstream Apache-2.0 license and notices must be copied into every package
that contains FreeRDP libraries. The packaging step must also emit the exact
manifest above into the release evidence/SBOM.

Remote macOS targets, credential persistence in the adapter, automatic
certificate acceptance and shelling out to a platform RDP client are
deliberately excluded.
