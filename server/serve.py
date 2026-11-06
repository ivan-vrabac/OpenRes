"""Start the game server on the CPUs it may use (owner 2026-11-06).

One process per CPU (procs.py says why processes, not threads). How many:
- WORKERS=<n> in the environment: exactly n
- else the container's CPU limit (Docker `cpus:`), rounded down
- else CPU_SHARE (default 0.8) of the machine's CPUs: always leave some for the system and other programs
So the same image fits a small or a big machine, and a new limit is only a restart away.
"""
import math
import os

import uvicorn


def machine_cpus() -> int:
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


def limit_cpus() -> float | None:
    """The container's CPU limit (cgroup v2 cpu.max), or None without one."""
    try:
        quota, period = open("/sys/fs/cgroup/cpu.max").read().split()
        return None if quota == "max" else int(quota) / int(period)
    except (OSError, ValueError):
        return None


def workers() -> int:
    if os.environ.get("WORKERS", "auto") != "auto":
        return max(1, int(os.environ["WORKERS"]))
    limit = limit_cpus()
    if limit is not None:
        return max(1, math.floor(limit))
    return max(1, math.floor(machine_cpus() * float(os.environ.get("CPU_SHARE", "0.8"))))


if __name__ == "__main__":
    n = workers()
    print(f"OpenRes server: {n} processes (machine {machine_cpus()} CPUs, limit {limit_cpus()})", flush=True)
    uvicorn.run("main:app", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), workers=n,
                proxy_headers=True, forwarded_allow_ips=os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1"),
                log_level=os.environ.get("LOG_LEVEL", "warning"))
