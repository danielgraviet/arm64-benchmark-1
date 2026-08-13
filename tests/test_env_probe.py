"""Unit tests for harness.env_probe."""

from __future__ import annotations

import json

from harness.env_probe import (
    host_env,
    merge_env,
    parse_cpuinfo,
    parse_probe_stdout,
    probe_shell_command,
    skipped_env,
)


X86_CPUINFO = """
processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 85
model name	: Intel(R) Xeon(R) Platinum 8488C
stepping	: 8
""".strip()

ARM_CPUINFO = """
processor	: 0
BogoMIPS	: 48.00
Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics
CPU implementer	: 0x41
CPU architecture: 8
CPU variant	: 0x0
CPU part	: 0xd0c
CPU revision	: 1
Hardware	: NVIDIA Grace / Olympus
""".strip()


def test_parse_cpuinfo_x86_model_name() -> None:
    assert parse_cpuinfo(X86_CPUINFO) == "Intel(R) Xeon(R) Platinum 8488C"


def test_parse_cpuinfo_arm_hardware() -> None:
    assert parse_cpuinfo(ARM_CPUINFO) == "NVIDIA Grace / Olympus"


def test_parse_cpuinfo_empty() -> None:
    assert parse_cpuinfo("") == "unknown"


def test_merge_env_shape() -> None:
    host = {"host_arch": "arm64", "host_cpu": "Apple M2 Pro"}
    remote = {
        "arch": "aarch64",
        "cpu_model": "NVIDIA Grace / Olympus",
        "cpu_count": 88,
        "platform": "Linux-6.1",
    }
    env = merge_env(host, remote, probe="rlp")
    assert env["arch"] == "aarch64"
    assert env["cpu_model"] == "NVIDIA Grace / Olympus"
    assert env["cpu_count"] == 88
    assert env["host_arch"] == "arm64"
    assert env["host_cpu"] == "Apple M2 Pro"
    assert env["probe"] == "rlp"
    assert "probe_error" not in env


def test_merge_env_probe_failed() -> None:
    host = {"host_arch": "arm64", "host_cpu": None}
    env = merge_env(host, None, probe="docker", probe_error="boom")
    assert env["cpu_model"] == "probe_failed"
    assert env["probe_error"] == "boom"
    assert env["host_arch"] == "arm64"


def test_skipped_env() -> None:
    env = skipped_env({"host_arch": "x86_64", "host_cpu": None})
    assert env["probe"] == "skipped"
    assert env["arch"] is None


def test_host_env_has_arch() -> None:
    env = host_env()
    assert env["host_arch"]
    assert "host_cpu" in env


def test_parse_probe_stdout_last_line() -> None:
    payload = {"arch": "x86_64", "cpu_model": "test", "cpu_count": 2, "platform": "Linux"}
    stdout = "noise\n" + json.dumps(payload)
    assert parse_probe_stdout(stdout)["arch"] == "x86_64"


def test_probe_shell_command_contains_python() -> None:
    cmd = probe_shell_command("python3")
    assert cmd.startswith("python3 -c ")
    assert "base64" in cmd
