"""NUMA / cpuset-mems pinning for local Docker (no live daemon)."""

from __future__ import annotations

from pathlib import Path

import pytest

from harness.paths import result_series_name
from harness.runners.docker import DockerRunner, numa_node_cpulist


def test_numa_node_cpulist_reads_sysfs(tmp_path: Path) -> None:
    node = tmp_path / "node0"
    node.mkdir()
    (node / "cpulist").write_text("0-87,176-263\n", encoding="utf-8")
    assert numa_node_cpulist(0, sysfs=tmp_path) == "0-87,176-263"


def test_result_series_docker_numa() -> None:
    assert result_series_name("docker", numa_node=0) == "docker-numa0"
    assert result_series_name("docker", host_cpus=88, cpuset_mems="0") == "docker-c88-m0"
    assert result_series_name("docker", host_cpus=32) == "docker-c32"


def test_docker_run_args_include_cpuset_mems() -> None:
    runner = DockerRunner(host_cpus=8, cpuset_mems="0")
    cmd = runner._run_args("img")
    assert "--cpuset-cpus=0-7" in cmd
    assert "--cpuset-mems=0" in cmd
    meta = runner.docker_limits_meta()
    assert meta["docker_cpuset_mems"] == "0"
    assert meta["host_cpus"] == 8


def test_docker_numa_node_requires_sysfs() -> None:
    with pytest.raises(FileNotFoundError):
        DockerRunner(numa_node=99)
