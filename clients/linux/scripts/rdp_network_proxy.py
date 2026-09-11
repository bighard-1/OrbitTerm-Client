#!/usr/bin/env python3
"""Loopback-only latency/bandwidth proxy for authorised RDP release testing.

This harness never interprets or records RDP bytes. It binds to loopback, keeps
the target explicit, and exits without changing firewall or host settings.
"""

import argparse
import asyncio
import contextlib
import signal
from typing import Optional


async def pump(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    delay_seconds: float,
    bytes_per_second: int,
) -> None:
    try:
        while True:
            chunk = await reader.read(64 * 1024)
            if not chunk:
                break
            if delay_seconds:
                await asyncio.sleep(delay_seconds)
            writer.write(chunk)
            await writer.drain()
            if bytes_per_second:
                await asyncio.sleep(len(chunk) / bytes_per_second)
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


async def serve(args: argparse.Namespace) -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for name in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(name, stop.set)

    async def handle(
        client_reader: asyncio.StreamReader,
        client_writer: asyncio.StreamWriter,
    ) -> None:
        try:
            remote_reader, remote_writer = await asyncio.open_connection(
                args.target_host, args.target_port
            )
        except Exception:
            client_writer.close()
            with contextlib.suppress(Exception):
                await client_writer.wait_closed()
            return
        delay = args.one_way_delay_ms / 1000.0
        await asyncio.gather(
            pump(client_reader, remote_writer, delay, args.bytes_per_second),
            pump(remote_reader, client_writer, delay, args.bytes_per_second),
        )

    server = await asyncio.start_server(handle, "127.0.0.1", args.listen_port)
    print(
        f"READY 127.0.0.1:{args.listen_port} -> "
        f"{args.target_host}:{args.target_port}",
        flush=True,
    )
    async with server:
        await stop.wait()


def positive_port(value: str) -> int:
    port = int(value)
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def non_negative(value: str) -> int:
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("value must be non-negative")
    return number


def parse_args(argv: Optional[list] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=positive_port, required=True)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=positive_port, required=True)
    parser.add_argument("--one-way-delay-ms", type=non_negative, default=0)
    parser.add_argument("--bytes-per-second", type=non_negative, default=0)
    return parser.parse_args(argv)


if __name__ == "__main__":
    asyncio.run(serve(parse_args()))
