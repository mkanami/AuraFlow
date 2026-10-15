#!/usr/bin/env python3
"""Read-only macOS wallpaper soak sampler. CPU is percent of one CPU core.

Usage: python3 scripts/profile_wallpaper_processes.py --output /tmp/video.jsonl
       --duration 1800 --warmup 120
Reports process-local footprint and I/O, not summed shared GPU allocations.
"""
import argparse
import ctypes as C
import json
import pathlib
import plistlib
import subprocess
import time


class Usage(C.Structure):
    _fields_ = [("uuid", C.c_uint8 * 16)] + [(name, C.c_uint64) for name in (
        "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins",
        "wired", "resident", "footprint", "start", "exit", "child_user",
        "child_system", "child_idle", "child_interrupt", "child_pageins",
        "child_elapsed", "disk_read", "disk_write")]


class Task(C.Structure):
    _fields_ = [(name, C.c_uint64) for name in (
        "virtual", "resident", "user", "system", "threads_user", "threads_system")]
    _fields_ += [(name, C.c_int32) for name in (
        "policy", "faults", "pageins", "cow", "sent", "received", "mach_calls",
        "unix_calls", "switches", "threads", "running", "priority")]


class Timebase(C.Structure):
    _fields_ = [("numer", C.c_uint32), ("denom", C.c_uint32)]


def descriptor_count(lib, pid):
    # A size-only query includes allocation headroom; enumerate actual entries.
    capacity = 128
    while capacity <= 65536:
        buffer = C.create_string_buffer(capacity * 8)
        size = lib.proc_pidinfo(pid, 1, 0, buffer, len(buffer))
        if size <= 0:
            return None
        if size < len(buffer):
            return size // 8
        capacity *= 2
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--duration", type=float, default=1800)
    parser.add_argument("--warmup", type=float, default=120)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--resume", action="store_true", help="Continue an interrupted sample file")
    args = parser.parse_args()
    if args.interval <= 0 or args.duration <= 0 or args.warmup < 0:
        parser.error("duration/interval must be positive and warmup nonnegative")
    lib = C.CDLL("/usr/lib/libproc.dylib")
    system = C.CDLL("/usr/lib/libSystem.B.dylib")
    base = Timebase()
    system.mach_timebase_info(C.byref(base))
    seconds_per_tick = base.numer / base.denom / 1e9
    previous = {}
    started = time.monotonic()
    if args.resume and args.output.exists():
        records = args.output.read_text().splitlines()
        if records:
            started -= json.loads(records[-1])["elapsed"]
    data_root = pathlib.Path.home() / "Library/Application Support/AuraFlow"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    names = {"WallpaperControlApp", "AuraWallpaperAgent", "AuraTerminalWallpaperAgent",
             "AuraWallpaperNativeBridge", "AuraWebWallpaperAgent", "WindowServer",
             "WallpaperAgent", "WallpaperAerialsExtension", "ScreenSaverEngine", "legacyScreenSaver"}
    with args.output.open("a" if args.resume else "w") as output:
        while time.monotonic() - started <= args.warmup + args.duration:
            now = time.monotonic()
            listing = subprocess.check_output(
                ["ps", "-axo", "pid=,ppid=,%cpu=,comm="], text=True)
            processes = {}
            fallback_cpu = {}
            for line in listing.splitlines():
                fields = line.split(None, 3)
                if len(fields) == 4:
                    processes[int(fields[0])] = (int(fields[1]), pathlib.Path(fields[3]).name)
                    fallback_cpu[int(fields[0])] = float(fields[2])
            selected = {pid for pid, (_, name) in processes.items() if name in names}
            # Include every CLI descendant, even if its executable is unfamiliar.
            while True:
                children = {pid for pid, (parent, _) in processes.items() if parent in selected}
                expanded = selected | children
                if expanded == selected:
                    break
                selected = expanded
            samples = []
            next_previous = {}
            for pid in sorted(selected):
                usage, task = Usage(), Task()
                if lib.proc_pid_rusage(pid, 2, C.byref(usage)) != 0:
                    samples.append({"pid": pid, "name": processes[pid][1], "unavailable": True,
                                    "ps_cpu_percent": fallback_cpu[pid]})
                    continue
                lib.proc_pidinfo(pid, 4, 0, C.byref(task), C.sizeof(task))
                old = previous.get((pid, usage.start))
                cpu_time = usage.user + usage.system
                elapsed = now - old[0] if old else 0
                samples.append({
                    "pid": pid, "parent_pid": processes[pid][0], "name": processes[pid][1],
                    "cpu_percent": (cpu_time - old[1]) * seconds_per_tick / elapsed * 100 if old else None,
                    "footprint_mb": usage.footprint / 1048576,
                    "resident_mb": usage.resident / 1048576,
                    "threads": task.threads, "fds": descriptor_count(lib, pid),
                    "disk_read_bytes": usage.disk_read, "disk_write_bytes": usage.disk_write,
                    "idle_wakeups": usage.idle_wakeups,
                })
                next_previous[(pid, usage.start)] = (now, cpu_time)
            health = {}
            for kind, relative in (("video", "daemon_health.json"),
                                   ("terminal", "terminal-wallpaper/health.json")):
                try:
                    raw = json.loads((data_root / relative).read_text())
                    health[kind] = {key: raw.get(key) for key in (
                        "pid", "child_pid", "frames", "rendered_frames", "columns", "rows",
                        "reason", "paused", "suspicious") if key in raw}
                except (OSError, ValueError):
                    pass
            gpu = {}
            locked = None
            try:
                roots = plistlib.loads(subprocess.check_output(
                    ["ioreg", "-a", "-r", "-n", "Root", "-d", "1"]))
                if roots:
                    locked = roots[0].get("IOConsoleLocked")
            except (OSError, ValueError, subprocess.CalledProcessError):
                pass
            try:
                accelerators = plistlib.loads(subprocess.check_output(
                    ["ioreg", "-a", "-r", "-c", "AGXAccelerator", "-d", "1"]))
                if accelerators:
                    stats = accelerators[0].get("PerformanceStatistics", {})
                    gpu = {key: stats.get(key) for key in (
                        "Device Utilization %", "Renderer Utilization %", "Tiler Utilization %",
                        "In use system memory") if key in stats}
            except (OSError, ValueError, subprocess.CalledProcessError):
                pass
            output.write(json.dumps({"elapsed": round(now - started, 3),
                "measured": now - started >= args.warmup,
                "processes": samples, "health": health, "system_gpu": gpu,
                "fd_count_method": "enumerated", "screen_locked": locked}) + "\n")
            output.flush()
            previous = next_previous
            time.sleep(min(args.interval, max(0, args.duration + args.warmup - (time.monotonic() - started))))


if __name__ == "__main__":
    main()
