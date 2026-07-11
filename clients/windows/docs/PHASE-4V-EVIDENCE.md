# Phase 4V Evidence: Checked SFTP Upload Completion

## Scope

Phase 4V closes the Windows checked SFTP upload path from the native core through the application and user interface.

## Safety Boundary

- Uploads require an active checked SFTP lease bound to a Host Key verified base session.
- Local upload paths must be absolute, bounded, and point to an existing regular file.
- Remote paths must be bounded absolute SFTP paths without control characters, backslashes, or parent traversal.
- The native core creates the remote file with exclusive create semantics and refuses to overwrite an existing path.
- Native error envelopes redact local paths and backend details.

## User Experience

- The file picker uploads into the currently listed remote directory.
- A successful upload refreshes the directory listing.
- The upload byte count and remote destination remain visible after the refresh completes.
- Initial and listing status text now accurately reports that checked upload and download are available.

## Verification

- Local Windows static gate: passed.
- Local diff whitespace check: passed.
- Rust checked SFTP tests: 17 passed, 0 failed.
- Remote Windows static gate: passed.
- Remote Windows security tests: 72 passed, 0 failed, 0 skipped.
- Remote Windows x64 Release solution build: passed with 0 warnings and 0 errors.
- Remote validation was confined to `D:\Macmini2\phase-4v-validate`.
