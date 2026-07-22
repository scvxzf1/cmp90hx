#!/usr/bin/env python3
"""Apply the two audited full-speed selectors to an unbound CMP 90HX."""

from __future__ import annotations

import argparse
import json
import mmap
import os
import struct
import sys
import time
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
PLM_OPEN = 0xFFFFFFFF
# The first two pairs are the package's original expected locked state.  The
# third pair was observed on this exact card twice after the V67 candidate had
# opened PLM and the NVIDIA driver was unbound.  Keeping pairs together avoids
# accepting a mixed or otherwise unknown BAR0 state.
NATIVE_SELECTOR_PAIRS = {
    (0x23756124, 0x00000000),
    (0x23756134, 0x00000000),
    (0x00424054, 0x00000006),
}
FULL_SS0 = 0x88888888
FULL_SS1 = 0x00000008


def read32(bar0: mmap.mmap, offset: int) -> int:
    return struct.unpack_from("<I", bar0, offset)[0]


def write32(bar0: mmap.mmap, offset: int, value: int) -> None:
    struct.pack_into("<I", bar0, offset, value)


def snapshot(bar0: mmap.mmap) -> dict[str, int]:
    return {name: read32(bar0, offset) for name, offset in REGISTERS.items()}


def formatted(values: dict[str, int]) -> dict[str, str]:
    return {name: f"0x{value:08x}" for name, value in values.items()}


def read_text(path: Path) -> str:
    return path.read_text(encoding="ascii").strip().lower()


def execute(bdf: str) -> dict:
    if os.geteuid() != 0:
        raise PermissionError("root is required")
    device = Path("/sys/bus/pci/devices") / bdf
    resource0 = device / "resource0"
    expected = {
        "vendor": "0x10de",
        "device": "0x220d",
        "subsystem_vendor": "0x10de",
        "subsystem_device": "0x1555",
    }
    actual = {name: read_text(device / name) for name in expected}
    if actual != expected:
        raise RuntimeError(f"PCI identity mismatch: {actual!r}")
    if (device / "driver").exists():
        raise RuntimeError("target GPU must be unbound before BAR0 write")
    if resource0.stat().st_size < BAR0_SIZE:
        raise RuntimeError("BAR0 is smaller than the audited mapping")

    report: dict = {
        "schema": "cmp90hx-share-bar0-compute-override-v1",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "bdf": bdf,
        "writes": [],
    }
    descriptor = os.open(resource0, os.O_RDWR | os.O_SYNC)
    try:
        with mmap.mmap(
            descriptor,
            BAR0_SIZE,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        ) as bar0:
            before = snapshot(bar0)
            report["before"] = formatted(before)
            if before["plm"] != PLM_OPEN:
                raise RuntimeError(
                    f"FEAT_OVR_PLM is not open: 0x{before['plm']:08x}"
                )
            if (before["ss0"], before["ss1"]) not in NATIVE_SELECTOR_PAIRS:
                raise RuntimeError(
                    f"native speed-selector mismatch: {formatted(before)}"
                )

            for name, value in (("ss1", FULL_SS1), ("ss0", FULL_SS0)):
                offset = REGISTERS[name]
                write32(bar0, offset, value)
                immediate = read32(bar0, offset)
                time.sleep(0.020)
                settled = read32(bar0, offset)
                report["writes"].append(
                    {
                        "register": name,
                        "offset": f"0x{offset:08x}",
                        "requested": f"0x{value:08x}",
                        "immediate": f"0x{immediate:08x}",
                        "settled": f"0x{settled:08x}",
                    }
                )
                if immediate != value or settled != value:
                    raise RuntimeError(
                        f"{name} write/readback failed: "
                        f"0x{immediate:08x}/0x{settled:08x}"
                    )

            after = snapshot(bar0)
            report["after"] = formatted(after)
            if after["plm"] != PLM_OPEN:
                raise RuntimeError("PLM changed while applying selectors")
            if after["ss0"] != FULL_SS0 or after["ss1"] != FULL_SS1:
                raise RuntimeError(f"full-speed readback mismatch: {formatted(after)}")
            for name in ("fbpa_cfg1", "local_memory_range"):
                if after[name] != before[name]:
                    raise RuntimeError(f"non-compute invariant changed: {name}")
            report["result"] = "PASS_COMPUTE_OVERRIDE_APPLIED"
            report["hardware_writes"] = 2
            return report
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bdf", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = execute(args.bdf)
        rc = 0
    except Exception as exc:  # pylint: disable=broad-exception-caught
        report = {
            "schema": "cmp90hx-share-bar0-compute-override-v1",
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "result": "FAIL",
            "error": str(exc),
        }
        rc = 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
