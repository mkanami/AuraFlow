#!/usr/bin/env python3
"""Exercise the AuraWallpaperNativeBridge JSON-lines protocol."""

import json
import select
import subprocess
import sys


def request(bridge: subprocess.Popen, action: str) -> dict:
    request_id = "ci-smoke-" + action
    assert bridge.stdin is not None
    assert bridge.stdout is not None
    bridge.stdin.write(json.dumps({"id": request_id, "action": action}) + "\n")
    bridge.stdin.flush()
    readable, _, _ = select.select([bridge.stdout], [], [], 15)
    if not readable:
        raise RuntimeError("native bridge did not respond to " + action)
    response = json.loads(bridge.stdout.readline())
    if response.get("id") != request_id:
        raise RuntimeError("native bridge returned the wrong request id")
    if response.get("action") != action:
        raise RuntimeError("native bridge returned the wrong action")
    if not isinstance(response.get("succeeded"), bool):
        raise RuntimeError("native bridge response has no boolean result")
    return response


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: native_bridge_smoke.py PATH_TO_BRIDGE")

    bridge = subprocess.Popen(
        [sys.argv[1]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        prepare = request(bridge, "prepare")
        show = request(bridge, "show")
        hide = request(bridge, "hide")
        shutdown = request(bridge, "shutdown")
        if not all(
            response["succeeded"]
            for response in (prepare, show, hide, shutdown)
        ):
            failed_actions = [
                action
                for action, response in (
                    ("prepare", prepare),
                    ("show", show),
                    ("hide", hide),
                    ("shutdown", shutdown),
                )
                if not response["succeeded"]
            ]
            raise RuntimeError(
                "native bridge request failed: " + ", ".join(failed_actions)
            )
        if bridge.wait(timeout=10) != 0:
            raise RuntimeError("native bridge exited with a failure status")
        print(
            json.dumps(
                {
                    "prepare": prepare["succeeded"],
                    "show": show["succeeded"],
                    "hide": hide["succeeded"],
                    "shutdown": shutdown["succeeded"],
                }
            )
        )
        return 0
    finally:
        if bridge.poll() is None:
            bridge.terminate()
            try:
                bridge.wait(timeout=10)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
