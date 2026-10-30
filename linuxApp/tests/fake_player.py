"""A real child process implementing just enough mpv IPC for transport tests."""

import json
import os
import shlex
import socket
import sys
from pathlib import Path

if sys.argv[1] == "-o":
    options = shlex.split(sys.argv[2])
    endpoint = next(
        item.partition("=")[2] for item in options if item.startswith("--input-ipc-server=")
    )
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(endpoint)
    listener.listen(1)
    Path(os.environ["AURAFLOW_TEST_PLAYER_PID"]).write_text(str(os.getpid()))
    connection, _ = listener.accept()
else:
    connection = socket.socket(fileno=int(sys.argv[1]))
stream = connection.makefile("r", encoding="utf-8")
properties = {
    "video-params": {"w": 64, "h": 48},
    "vo-configured": True,
    "pause": False,
    "speed": 1.0,
}
for line in stream:
    request = json.loads(line)
    command = request["command"]
    error, data = "success", None
    if command[0] == "get_property":
        if command[1] in properties:
            data = properties[command[1]]
        else:
            error = "property unavailable"
    elif command[0] == "set_property":
        properties[command[1]] = command[2]
    else:
        error = "command not found"
    connection.sendall(b'{"event":"playback-restart"}\n')
    reply = json.dumps({"request_id": request["request_id"], "error": error, "data": data}).encode()
    # Deliberately split a response across socket reads.
    connection.sendall(reply[:8])
    connection.sendall(reply[8:] + b"\n")
