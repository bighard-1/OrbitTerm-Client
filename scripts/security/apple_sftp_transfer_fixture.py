#!/usr/bin/env python3
"""Disposable loopback-only SFTP fixture; all files and credentials are virtual."""

import asyncio
import json
import os
from pathlib import Path
import secrets
import sys

import asyncssh


async def main(root: Path) -> None:
    password = secrets.token_urlsafe(24)
    remote = root / "remote"
    remote.mkdir(mode=0o700)
    (remote / "virtual.bin").write_bytes(bytes(range(256)) * 1024)
    with (remote / "slow.bin").open("wb") as stream:
        stream.truncate(8 * 1024 * 1024)

    class Server(asyncssh.SSHServer):
        def begin_auth(self, _username):
            return True

        def password_auth_supported(self):
            return True

        def validate_password(self, username, supplied):
            return username == "qa" and secrets.compare_digest(supplied, password)

    class SFTP(asyncssh.SFTPServer):
        def __init__(self, channel):
            super().__init__(channel, chroot=os.fsencode(remote))

        async def read(self, file_obj, offset, size):
            if Path(os.fsdecode(file_obj.name)).name == "slow.bin":
                (root / "slow-read-started").touch()
                await asyncio.sleep(0.05)
            return super().read(file_obj, offset, min(size, 32768))

        async def write(self, file_obj, offset, data):
            if (root / "stall-upload-write").exists():
                (root / "upload-write-started").touch()
                await asyncio.sleep(60)
            if (root / "fail-upload-write").exists() and offset >= 65536:
                raise asyncssh.SFTPPermissionDenied("untrusted-server induced write fault")
            return super().write(file_obj, offset, data)

        def remove(self, path):
            if (root / "fail-upload-cleanup").exists():
                raise asyncssh.SFTPPermissionDenied("untrusted-server induced cleanup fault")
            return super().remove(path)

    key = asyncssh.generate_private_key("ssh-ed25519")
    listener = await asyncssh.listen(
        "127.0.0.1", 0, server_factory=Server,
        server_host_keys=[key], sftp_factory=SFTP,
    )
    port = listener.get_port()
    security = root / "orbitterm"
    security.mkdir(mode=0o700)
    known_hosts = security / "known_hosts"
    known_hosts.write_text(f"[127.0.0.1]:{port} " + key.export_public_key().decode())
    known_hosts.chmod(0o600)
    config = root / "config.json"
    config.write_text(json.dumps(dict(root=str(root), port=port, password=password)))
    config.chmod(0o600)
    try:
        await asyncio.sleep(300)
    finally:
        listener.close()
        await listener.wait_closed()


if __name__ == "__main__":
    asyncio.run(main(Path(sys.argv[1]).resolve()))
