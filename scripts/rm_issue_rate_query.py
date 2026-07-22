#!/usr/bin/env python3
"""Read and validate effective NVIDIA SM issue-rate modifiers."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


NV_IOCTL_MAGIC = ord("F")
NV_IOCTL_BASE = 200
NV_ESC_REGISTER_FD = NV_IOCTL_BASE + 1
NV_ESC_RM_FREE = 0x29
NV_ESC_RM_CONTROL = 0x2A
NV_ESC_RM_ALLOC = 0x2B
NV01_ROOT_CLIENT = 0x00000041
NV01_DEVICE_0 = 0x00000080
NV20_SUBDEVICE_0 = 0x00002080
NV2080_CTRL_CMD_GR_GET_SM_ISSUE_RATE_MODIFIER = 0x20801230
NV_DEVICE_ALLOCATION_VAMODE_OPTIONAL_MULTIPLE_VASPACES = 0
RATE_LABELS = {
    0: "full",
    1: "1/2",
    2: "1/4",
    3: "1/8",
    4: "1/16",
    5: "1/32",
    6: "1/64",
}


class NVOS21_PARAMETERS(ctypes.Structure):
    _fields_ = [
        ("hRoot", ctypes.c_uint32),
        ("hObjectParent", ctypes.c_uint32),
        ("hObjectNew", ctypes.c_uint32),
        ("hClass", ctypes.c_uint32),
        ("pAllocParms", ctypes.c_void_p),
        ("paramsSize", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
    ]


class NVOS54_PARAMETERS(ctypes.Structure):
    _fields_ = [
        ("hClient", ctypes.c_uint32),
        ("hObject", ctypes.c_uint32),
        ("cmd", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("params", ctypes.c_void_p),
        ("paramsSize", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
    ]


class NVOS00_PARAMETERS(ctypes.Structure):
    _fields_ = [
        ("hRoot", ctypes.c_uint32),
        ("hObjectParent", ctypes.c_uint32),
        ("hObjectOld", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
    ]


class NV0080_ALLOC_PARAMETERS(ctypes.Structure):
    _fields_ = [
        ("deviceId", ctypes.c_uint32),
        ("hClientShare", ctypes.c_uint32),
        ("hTargetClient", ctypes.c_uint32),
        ("hTargetDevice", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("vaSpaceSize", ctypes.c_uint64),
        ("vaStartInternal", ctypes.c_uint64),
        ("vaLimitInternal", ctypes.c_uint64),
        ("vaMode", ctypes.c_uint32),
    ]


class NV2080_ALLOC_PARAMETERS(ctypes.Structure):
    _fields_ = [("subDeviceId", ctypes.c_uint32)]


class NV2080_CTRL_GR_ROUTE_INFO(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint32), ("route", ctypes.c_uint64)]


class NV2080_CTRL_GR_GET_SM_ISSUE_RATE_MODIFIER_PARAMS(ctypes.Structure):
    _fields_ = [
        ("grRouteInfo", NV2080_CTRL_GR_ROUTE_INFO),
        ("imla0", ctypes.c_uint8),
        ("fmla16", ctypes.c_uint8),
        ("dp", ctypes.c_uint8),
        ("fmla32", ctypes.c_uint8),
        ("ffma", ctypes.c_uint8),
        ("imla1", ctypes.c_uint8),
        ("imla2", ctypes.c_uint8),
        ("imla3", ctypes.c_uint8),
        ("imla4", ctypes.c_uint8),
    ]


def ioctl_iowr(number: int, size: int) -> int:
    if not 0 < size < (1 << 14):
        raise ValueError(f"invalid ioctl size: {size}")
    return (3 << 30) | (size << 16) | (NV_IOCTL_MAGIC << 8) | number


def ioctl_struct(fd: int, number: int, value: ctypes.Structure) -> None:
    size = ctypes.sizeof(value)
    buffer = bytearray(ctypes.string_at(ctypes.addressof(value), size))
    fcntl.ioctl(fd, ioctl_iowr(number, size), buffer, True)
    ctypes.memmove(ctypes.addressof(value), bytes(buffer), size)


def rm_alloc(
    fd: int,
    root: int,
    parent: int,
    class_id: int,
    params: ctypes.Structure | None,
) -> int:
    request = NVOS21_PARAMETERS(
        hRoot=root,
        hObjectParent=parent,
        hObjectNew=0,
        hClass=class_id,
        pAllocParms=ctypes.addressof(params) if params is not None else None,
        paramsSize=ctypes.sizeof(params) if params is not None else 0,
        status=0,
    )
    ioctl_struct(fd, NV_ESC_RM_ALLOC, request)
    if request.status or not request.hObjectNew:
        raise RuntimeError(
            f"RM_ALLOC class=0x{class_id:08x} failed: 0x{request.status:08x}"
        )
    return request.hObjectNew


def rm_control(
    fd: int,
    root: int,
    obj: int,
    command: int,
    params: ctypes.Structure,
) -> None:
    request = NVOS54_PARAMETERS(
        hClient=root,
        hObject=obj,
        cmd=command,
        flags=0,
        params=ctypes.addressof(params),
        paramsSize=ctypes.sizeof(params),
        status=0,
    )
    ioctl_struct(fd, NV_ESC_RM_CONTROL, request)
    if request.status:
        raise RuntimeError(
            f"RM_CONTROL cmd=0x{command:08x} failed: 0x{request.status:08x}"
        )


def rm_free(fd: int, root: int, parent: int, obj: int) -> str:
    request = NVOS00_PARAMETERS(
        hRoot=root,
        hObjectParent=parent,
        hObjectOld=obj,
        status=0,
    )
    ioctl_struct(fd, NV_ESC_RM_FREE, request)
    return f"0x{request.status:08x}"


def command_output(command: list[str]) -> str:
    return subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    ).stdout.strip()


def verify_identity(args: argparse.Namespace) -> dict:
    base = Path("/sys/bus/pci/devices") / args.bdf
    actual = {
        "vendor": (base / "vendor").read_text().strip().lower(),
        "device": (base / "device").read_text().strip().lower(),
        "subsystem_vendor": (base / "subsystem_vendor").read_text().strip().lower(),
        "subsystem_device": (base / "subsystem_device").read_text().strip().lower(),
        "driver": (base / "driver").resolve().name,
    }
    expected = {
        "vendor": "0x10de",
        "device": "0x220d",
        "subsystem_vendor": "0x10de",
        "subsystem_device": "0x1555",
        "driver": "nvidia",
    }
    if actual != expected:
        raise RuntimeError(f"GPU identity mismatch: {actual!r}")
    smi = command_output(
        [
            "nvidia-smi",
            "--query-gpu=uuid,memory.total,driver_version",
            "--format=csv,noheader,nounits",
        ]
    )
    if len(smi.splitlines()) != 1:
        raise RuntimeError("this package requires exactly one NVIDIA GPU")
    fields = [field.strip() for field in smi.split(",")]
    if fields != [args.uuid, str(args.memory_mib), args.driver]:
        raise RuntimeError(f"nvidia-smi identity mismatch: {fields!r}")
    return {**actual, "bdf": args.bdf, "uuid": fields[0], "memory_mib": int(fields[1])}


def query() -> tuple[dict, dict]:
    handles: dict[str, int] = {}
    free_status: dict[str, str] = {}
    fd = os.open("/dev/nvidiactl", os.O_RDWR | os.O_CLOEXEC)
    device_fd: int | None = None
    try:
        root = rm_alloc(fd, 0, 0, NV01_ROOT_CLIENT, None)
        handles["root"] = root
        device_fd = os.open("/dev/nvidia0", os.O_RDWR | os.O_CLOEXEC)
        control_fd = ctypes.c_int(fd)
        ioctl_struct(device_fd, NV_ESC_REGISTER_FD, control_fd)
        device_params = NV0080_ALLOC_PARAMETERS(
            deviceId=0,
            hClientShare=root,
            hTargetClient=0,
            hTargetDevice=0,
            flags=0,
            vaSpaceSize=0,
            vaStartInternal=0,
            vaLimitInternal=0,
            vaMode=NV_DEVICE_ALLOCATION_VAMODE_OPTIONAL_MULTIPLE_VASPACES,
        )
        device = rm_alloc(fd, root, root, NV01_DEVICE_0, device_params)
        handles["device"] = device
        subdevice_params = NV2080_ALLOC_PARAMETERS(subDeviceId=0)
        subdevice = rm_alloc(fd, root, device, NV20_SUBDEVICE_0, subdevice_params)
        handles["subdevice"] = subdevice
        values = NV2080_CTRL_GR_GET_SM_ISSUE_RATE_MODIFIER_PARAMS()
        rm_control(
            fd,
            root,
            subdevice,
            NV2080_CTRL_CMD_GR_GET_SM_ISSUE_RATE_MODIFIER,
            values,
        )
        names = (
            "imla0",
            "fmla16",
            "dp",
            "fmla32",
            "ffma",
            "imla1",
            "imla2",
            "imla3",
            "imla4",
        )
        rates = {
            name: {
                "value": int(getattr(values, name)),
                "rate": RATE_LABELS.get(int(getattr(values, name)), "unknown"),
            }
            for name in names
        }
        return rates, {"handles": handles, "free_status": free_status}
    finally:
        root = handles.get("root")
        device = handles.get("device")
        subdevice = handles.get("subdevice")
        if root is not None:
            if subdevice is not None and device is not None:
                free_status["subdevice"] = rm_free(fd, root, device, subdevice)
            if device is not None:
                free_status["device"] = rm_free(fd, root, root, device)
            free_status["root"] = rm_free(fd, root, 0, root)
        if device_fd is not None:
            os.close(device_fd)
        os.close(fd)


def validate_rates(rates: dict, expectation: str) -> None:
    if expectation == "full":
        if not all(entry["value"] == 0 for entry in rates.values()):
            raise RuntimeError(f"not all issue rates are full: {rates!r}")
        return
    if rates["dp"]["value"] != 1:
        raise RuntimeError(f"unexpected locked DP value: {rates!r}")
    for name in ("ffma", "fmla16", "fmla32", "imla0", "imla1", "imla2", "imla3", "imla4"):
        if rates[name]["value"] != 5:
            raise RuntimeError(f"unexpected locked rate for {name}: {rates!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bdf", required=True)
    parser.add_argument("--uuid", required=True)
    parser.add_argument("--driver", required=True)
    parser.add_argument("--memory-mib", type=int, required=True)
    parser.add_argument("--expect", choices=("locked", "full"), required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if platform.machine() != "x86_64":
        raise RuntimeError("x86_64 is required")
    expected_sizes = (32, 32, 16, 56, 4, 16, 32)
    actual_sizes = tuple(
        ctypes.sizeof(item)
        for item in (
            NVOS21_PARAMETERS,
            NVOS54_PARAMETERS,
            NVOS00_PARAMETERS,
            NV0080_ALLOC_PARAMETERS,
            NV2080_ALLOC_PARAMETERS,
            NV2080_CTRL_GR_ROUTE_INFO,
            NV2080_CTRL_GR_GET_SM_ISSUE_RATE_MODIFIER_PARAMS,
        )
    )
    if actual_sizes != expected_sizes:
        raise RuntimeError(f"ctypes layout mismatch: {actual_sizes}")
    before = verify_identity(args)
    rates, lifecycle = query()
    after = verify_identity(args)
    if before != after:
        raise RuntimeError("identity changed across RM query")
    validate_rates(rates, args.expect)
    report = {
        "result": "PASS",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "expectation": args.expect,
        "identity": before,
        "effective_issue_rates": rates,
        "rm_lifecycle": lifecycle,
        "hardware_writes": 0,
    }
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
