#!/usr/bin/env python3
"""Probe the compose-exposed Astonia game socket latency path."""

import argparse
import datetime as dt
import json
import math
import socket
import statistics
import struct
import sys
import time
from typing import Dict, Iterable, List


OPCODE_NAMES = {
    16: "SV_TICKER",
    36: "SV_REALTIME",
    49: "SV_PING",
}


def parse_ports(value: str) -> List[int]:
    ports: List[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start_text, end_text = part.split("-", 1)
            start = int(start_text)
            end = int(end_text)
            if start > end:
                raise ValueError(f"invalid port range {part!r}")
            ports.extend(range(start, end + 1))
        else:
            ports.append(int(part))

    if not ports:
        raise ValueError("at least one port is required")
    for port in ports:
        if port < 1 or port > 65535:
            raise ValueError(f"invalid port {port}")
    return ports


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise EOFError(f"socket closed after {len(chunks)} of {size} bytes")
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(sock: socket.socket) -> Dict[str, object]:
    header = recv_exact(sock, 1)[0]
    compressed = bool(header & 0x80)

    if header & 0x40:
        frame_len = header & 0x3F
        header_len = 1
    else:
        low = recv_exact(sock, 1)[0]
        if compressed:
            frame_len = ((header & 0x7F) << 8) | low
        else:
            frame_len = (header << 8) | low
        header_len = 2

    payload = recv_exact(sock, frame_len)
    opcode = payload[0] if payload else None

    result: Dict[str, object] = {
        "header_len": header_len,
        "frame_len": frame_len,
        "compressed": compressed,
        "opcode": opcode,
        "opcode_name": OPCODE_NAMES.get(opcode, "UNKNOWN"),
    }

    if opcode == 36 and len(payload) >= 5:
        result["server_realtime"] = struct.unpack_from("<I", payload, 1)[0]

    return result


def probe_once(host: str, port: int, timeout: float) -> Dict[str, object]:
    started = time.perf_counter()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        connected = time.perf_counter()
        sock.settimeout(timeout)
        first_byte_started = time.perf_counter()
        frame = read_frame(sock)
        frame_done = time.perf_counter()

    result: Dict[str, object] = {
        "port": port,
        "ok": True,
        "connect_ms": (connected - started) * 1000.0,
        "first_frame_ms": (frame_done - first_byte_started) * 1000.0,
        "total_ms": (frame_done - started) * 1000.0,
    }
    result.update(frame)
    return result


def percentile(values: List[float], pct: int) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    index = max(0, math.ceil((pct / 100.0) * len(ordered)) - 1)
    return ordered[index]


def summarize(port: int, results: Iterable[Dict[str, object]]) -> Dict[str, object]:
    rows = list(results)
    ok_rows = [row for row in rows if row.get("ok")]
    summary: Dict[str, object] = {
        "port": port,
        "ok": len(ok_rows),
        "fail": len(rows) - len(ok_rows),
    }

    for key in ("connect_ms", "first_frame_ms", "total_ms"):
        values = [float(row[key]) for row in ok_rows]
        if values:
            summary[f"{key}_min"] = min(values)
            summary[f"{key}_p50"] = statistics.median(values)
            summary[f"{key}_p95"] = percentile(values, 95)
            summary[f"{key}_max"] = max(values)

    return summary


def format_value(value: object) -> str:
    if isinstance(value, float):
        return f"{value:.3f}"
    text = str(value)
    return "_".join(text.split())


def print_text(kind: str, values: Dict[str, object]) -> None:
    fields = " ".join(f"{key}={format_value(value)}" for key, value in values.items())
    print(f"{kind} {fields}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="server host, default: 127.0.0.1")
    parser.add_argument("--ports", default="5556", help="comma/range list, default: 5556")
    parser.add_argument("--samples", type=int, default=10, help="samples per port, default: 10")
    parser.add_argument("--timeout", type=float, default=2.0, help="socket timeout seconds, default: 2")
    parser.add_argument("--delay", type=float, default=0.05, help="delay between samples, default: 0.05")
    parser.add_argument("--format", choices=("text", "jsonl"), default="text", help="output format")
    args = parser.parse_args()

    try:
        ports = parse_ports(args.ports)
    except ValueError as exc:
        parser.error(str(exc))

    if args.samples < 1:
        parser.error("--samples must be at least 1")

    started_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    if args.format == "text":
        print_text(
            "probe",
            {
                "name": "astonia_latency_probe",
                "timestamp_utc": started_at,
                "host": args.host,
                "ports": ",".join(str(port) for port in ports),
                "samples": args.samples,
                "timeout_s": args.timeout,
            },
        )

    all_ok = True
    by_port: Dict[int, List[Dict[str, object]]] = {port: [] for port in ports}

    for port in ports:
        for index in range(1, args.samples + 1):
            try:
                row = probe_once(args.host, port, args.timeout)
            except Exception as exc:
                row = {
                    "port": port,
                    "ok": False,
                    "error": f"{type(exc).__name__}:{exc}",
                }
                all_ok = False

            row["sample"] = index
            by_port[port].append(row)

            if args.format == "jsonl":
                print(json.dumps({"type": "sample", **row}, sort_keys=True))
            else:
                print_text("sample", row)

            if args.delay and index < args.samples:
                time.sleep(args.delay)

        summary = summarize(port, by_port[port])
        if summary["fail"]:
            all_ok = False

        if args.format == "jsonl":
            print(json.dumps({"type": "summary", **summary}, sort_keys=True))
        else:
            print_text("summary", summary)

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
