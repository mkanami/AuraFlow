from __future__ import annotations

import codecs
import fcntl
import logging
import math
import os
import pty
import select
import signal
import struct
import subprocess
import termios
import threading
import time
from dataclasses import replace
from pathlib import Path

import pyte
from PIL import Image, ImageDraw, ImageFont

from . import AuraFlowError
from .streams import VideoFormat
from .terminal_config import TerminalConfig

COLORS = {
    "black": "#000000",
    "red": "#cd3131",
    "green": "#0dbc79",
    "brown": "#e5c07b",
    "blue": "#2472c8",
    "magenta": "#bc3fbc",
    "cyan": "#11a8cd",
    "white": "#e5e5e5",
    "brightblack": "#666666",
    "brightred": "#f14c4c",
    "brightgreen": "#23d18b",
    "brightbrown": "#f5f543",
    "brightblue": "#3b8eea",
    "brightmagenta": "#d670d6",
    "brightcyan": "#29b8db",
    "brightwhite": "#ffffff",
}


def font(size: int):
    try:
        result = subprocess.run(
            ["fc-match", "-f", "%{file}", "monospace"],
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        )
        if result.stdout.strip():
            return ImageFont.truetype(result.stdout.strip(), size=size)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        return ImageFont.truetype("DejaVuSansMono.ttf", size=size)
    except OSError as exc:
        raise AuraFlowError(
            "Install fontconfig and a monospace font (for example DejaVu Sans Mono)."
        ) from exc


class TerminalRenderer:
    def __init__(self, config: TerminalConfig):
        self.config = config
        self.font = font(config.font_size)
        self.cell_width = max(1.0, self.font.getlength("M"))
        ascent, descent = self.font.getmetrics()
        self.cell_height = ascent + descent + 2
        self.format = VideoFormat(
            math.ceil(self.cell_width * config.columns), self.cell_height * config.rows, config.fps
        )
        self.screen = pyte.Screen(config.columns, config.rows)
        self.stream = pyte.Stream(self.screen)
        self.image = Image.new("RGB", (self.format.width, self.format.height), config.background)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data: bytes) -> None:
        self.stream.feed(self.decoder.decode(data))

    def color(self, value: str, default: str) -> str:
        if value == "default":
            return default
        return COLORS.get(value, "#" + value if len(value) == 6 else default)

    def render(self) -> bytes:
        draw = ImageDraw.Draw(self.image)
        for row in self.screen.dirty:
            if not 0 <= row < self.config.rows:
                continue
            y = row * self.cell_height
            draw.rectangle(
                (0, y, self.format.width, y + self.cell_height), fill=self.config.background
            )
            line = self.screen.buffer[row]
            # Group foreground runs; most terminal rows need only a few draw calls.
            run, start, style = "", 0, None

            for column in range(self.config.columns):
                char = line[column]
                fg = self.color(char.fg, self.config.foreground)
                bg = self.color(char.bg, self.config.background)
                if char.reverse:
                    fg, bg = bg, fg
                if bg != self.config.background:
                    x = math.floor(column * self.cell_width)
                    right = math.floor((column + 1) * self.cell_width) - 1
                    draw.rectangle((x, y, right, y + self.cell_height - 1), fill=bg)
                next_style = (fg, bg, char.bold, char.underscore)
                if style != next_style or not char.data:
                    self._draw_run(draw, run, start, style, y)
                    run, start, style = "", column, next_style
                run += char.data or " "
            self._draw_run(draw, run, start, style, y)
        self.screen.dirty.clear()
        return self.image.tobytes()

    def _draw_run(self, draw, run, start, style, y):
        if run and style:
            fg, _bg, bold, underline = style
            x = start * self.cell_width
            draw.text((x, y), run, font=self.font, fill=fg, stroke_width=int(bold), stroke_fill=fg)
            if underline:
                bottom = y + self.cell_height - 2
                draw.line((x, bottom, x + len(run) * self.cell_width, bottom), fill=fg)


class FrameSink:
    def __init__(self, descriptor: int):
        self.descriptor = descriptor
        os.set_blocking(descriptor, False)
        self.pending = memoryview(b"")

    def offer(self, frame: bytes) -> None:
        if not self.pending:
            self.pending = memoryview(frame)

    def flush(self) -> None:
        try:
            while self.pending:
                written = os.write(self.descriptor, self.pending)
                self.pending = self.pending[written:]
        except BlockingIOError:
            pass

    def close(self) -> None:
        os.close(self.descriptor)


class TerminalProducer:
    """One PTY and ANSI screen, shared by preview or any number of desktop players."""

    def __init__(self, config: TerminalConfig, speed: float = 1.0):
        self.config, self.speed = config, speed
        executable = config.executable()
        self.renderer = TerminalRenderer(config)
        self.format = self.renderer.format
        self.latest_frame: bytes | None = None
        self.sinks: list[FrameSink] = []
        self.lock = threading.RLock()
        self.stopping = threading.Event()
        self.ready = threading.Event()
        self.failure: str | None = None
        self.paused = False
        self.closed = False
        self.group_closed = False
        self.master, slave = pty.openpty()
        self.command_output = False
        self.finished = False
        fcntl.ioctl(
            slave, termios.TIOCSWINSZ, struct.pack("HHHH", config.rows, config.columns, 0, 0)
        )
        environment = dict(
            os.environ,
            TERM="xterm-256color",
            COLORTERM="truecolor",
            COLUMNS=str(config.columns),
            LINES=str(config.rows),
            SDL_AUDIODRIVER="dummy",
            ALSOFT_DRIVERS="null",
        )
        argv = [executable, *config.argv[1:]]
        if config.live_speed:
            argv = [executable, "-u", str(self._cmatrix_delay(speed))]
        try:
            self.process = subprocess.Popen(
                argv,
                stdin=slave,
                stdout=slave,
                stderr=slave,
                env=environment,
                start_new_session=True,
            )
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)
        os.set_blocking(self.master, False)
        self.thread = threading.Thread(target=self._run, name="auraflow-terminal", daemon=True)
        self.thread.start()

    @staticmethod
    def _cmatrix_delay(speed: float) -> int:
        return min(9, max(0, round(4 / speed)))

    def attach(self):
        reader, writer = os.pipe()
        with self.lock:
            self.sinks.append(FrameSink(writer))
        return os.fdopen(reader, "rb", buffering=0)

    def wait_ready(self, timeout: float = 5) -> None:
        if not self.ready.wait(timeout) or self.failure or not self.command_output:
            raise AuraFlowError(self.failure or "The terminal command produced no output.")

    def _run(self) -> None:
        next_frame = 0.0
        try:
            while not self.stopping.is_set():
                if not self.finished and select.select([self.master], [], [], 0.01)[0]:
                    try:
                        data = os.read(self.master, 65536)
                    except OSError:
                        data = b""
                    if data:
                        self.command_output = True
                        self.renderer.feed(data)
                    elif self.process.poll() is not None:
                        self.finished = True
                code = self.process.poll()
                if code is not None:
                    self._close_group()
                if code is not None and not self.command_output:
                    self.failure = f"Terminal command exited ({code}) without output."
                    self.ready.set()
                    return
                if code not in (None, 0):
                    self.failure = f"Terminal command exited with status {code}."
                    self.ready.set()
                    return
                now = time.monotonic()
                with self.lock:
                    if now >= next_frame and self.command_output and not self.paused:
                        if self.latest_frame is None or self.renderer.screen.dirty:
                            self.latest_frame = self.renderer.render()
                        self.ready.set()
                        for sink in self.sinks:
                            sink.offer(self.latest_frame)
                        next_frame = now + 1 / self.config.fps
                    for sink in self.sinks[:]:
                        try:
                            sink.flush()
                        except BrokenPipeError:
                            sink.close()
                            self.sinks.remove(sink)
                if self.finished:
                    self.stopping.wait(0.01)
        except Exception as exc:
            self.failure = f"Terminal renderer failed: {exc}"
            logging.exception(self.failure)
            self.ready.set()

    def set_paused(self, paused: bool) -> None:
        with self.lock:
            if self.process.poll() is None and self.paused != paused:
                os.killpg(self.process.pid, signal.SIGSTOP if paused else signal.SIGCONT)
            self.paused = paused

    def set_speed(self, speed: float) -> None:
        if not self.config.live_speed or self.process.poll() is not None:
            raise AuraFlowError(
                "Live speed control is available for CMatrix. Edit other commands before Start."
            )
        with self.lock:
            os.write(self.master, str(self._cmatrix_delay(speed)).encode())
            self.speed = speed

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.stopping.set()
        self._close_group()
        self.thread.join(timeout=2)
        with self.lock:
            for sink in self.sinks:
                sink.close()
            self.sinks.clear()
        os.close(self.master)

    def _close_group(self):
        with self.lock:
            if self.group_closed:
                return
            self.group_closed = True
            try:
                os.killpg(self.process.pid, signal.SIGCONT)
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=1)


class TerminalSession:
    kind = "terminal"

    def __init__(self, config: TerminalConfig, settings, log, factory=None):
        from .backends import detect_backend, start_stream

        if factory is None:
            detect_backend(settings.backend)
        # Keep the actual selected executable for login environments with a
        # different PATH. Arguments remain exact user-provided argv values.
        config = replace(config, argv=(str(Path(config.executable()).absolute()), *config.argv[1:]))
        self.config = config
        self.producer = TerminalProducer(config, settings.speed)
        try:
            self.video = (factory or start_stream)(self.producer, settings, log)
        except BaseException:
            self.producer.close()
            raise
        self.players, self.backend = self.video.players, self.video.backend
        self.media = Path(config.argv[0])
        self.label = config.label
        self.speed_supported = config.live_speed

    def wait_ready(self):
        self.producer.wait_ready()
        self.video.wait_ready()

    def set_properties(self, properties):
        if "speed" in properties:
            self.producer.set_speed(properties["speed"])
        if "pause" in properties:
            self.producer.set_paused(properties["pause"])
        forwarded = {key: value for key, value in properties.items() if key != "speed"}
        self.video.set_properties(forwarded)

    def alive(self):
        return self.video.alive() and not self.producer.failure

    def close(self):
        try:
            self.producer.close()
        finally:
            self.video.close()
