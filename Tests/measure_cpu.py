#!/usr/bin/env python3
"""Measure a live app's CPU time; exit nonzero when its average exceeds a budget."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def cpu_seconds(pid: int) -> float:
    value = subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", "time="], text=True
    ).strip()
    return sum(float(part) * 60**index for index, part in enumerate(reversed(value.split(":"))))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--duration", type=float, default=12)
    parser.add_argument("--max-cpu", type=float, default=10)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 1 <= args.duration <= 60:
        parser.error("duration must be between 1 and 60 seconds")

    initial = previous = cpu_seconds(args.pid)
    start = last = time.monotonic()
    measurements = []
    while (elapsed := time.monotonic() - start) < args.duration:
        time.sleep(min(2, args.duration - elapsed))
        current = cpu_seconds(args.pid)
        now = time.monotonic()
        measurements.append(round((current - previous) / (now - last) * 100, 2))
        previous, last = current, now

    elapsed = last - start
    average = (previous - initial) / elapsed * 100
    result = {
        "pid": args.pid,
        "elapsed_seconds": round(elapsed, 3),
        "cpu_seconds": round(previous - initial, 3),
        "average_cpu_percent": round(average, 2),
        "interval_cpu_percent": measurements,
        "max_cpu_percent": args.max_cpu,
        "passed": average <= args.max_cpu,
    }
    output = json.dumps(result, indent=2) + "\n"
    print(output, end="", flush=True)
    if args.output:
        args.output.write_text(output)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
