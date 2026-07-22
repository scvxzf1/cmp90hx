#!/usr/bin/env python3
"""Read the audited BAR0 offsets only while the target GPU is unbound."""

from __future__ import annotations

import argparse
import json
import mmap
import os
import struct
from datetime import datetime, timezone
from pathlib import Path


BAR0_SIZE = 0x01000000
REGISTERS = {
    "plm": 0x00823804,
    "feature_readout_1": 0x00823818,
    "ss0": 0x0082381C,
    "ss1": 0x00823820,
    "fbpa_cfg1": 0x009A0204,
    "local_memory_range": 0x00100CE0,
}
EXPECTED = {
    "vendor": "0x10de",
    "device": "0x220d",
    "subsystem_vendor": "0x10de",
    "subsystem_device": "0x1555",
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="ascii").strip().lower()


def read32(bar0: mmap.mmap, offset: int) -> int:
    return struct.unpack_from("<I", bar0, offset)[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bdf", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise PermissionError("root is required")
    device = Path("/sys/bus/pci/devices") / args.bdf
    actual = {name: read_text(device / name) for name in EXPECTED}
    if actual != EXPECTED:
        raise RuntimeError(f"PCI identity mismatch: {actual!r}")
    if (device / "driver").exists():
        raise RuntimeError("target GPU must be unbound for snapshot")
    resource0 = device / "resource0"
    if resource0.stat().st_size < BAR0_SIZE:
        raise RuntimeError("BAR0 is smaller than the audited mapping")

    descriptor = os.open(resource0, os.O_RDONLY | os.O_SYNC)
    try:
        with mmap.mmap(
            descriptor,
            BAR0_SIZE,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ,
        ) as bar0:
            values = {name: read32(bar0, offset) for name, offset in REGISTERS.items()}
    finally:
        os.close(descriptor)

    report = {
        "schema": "cmp90hx-unbound-bar0-snapshot-v1",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "bdf": args.bdf,
        "identity": actual,
        "hardware_writes": 0,
        "registers": {name: f"0x{value:08x}" for name, value in values.items()},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
