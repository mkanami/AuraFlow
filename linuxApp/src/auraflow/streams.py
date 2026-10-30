from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class VideoFormat:
    width: int
    height: int
    fps: int

    def options(self) -> list[str]:
        return [
            "--demuxer=rawvideo",
            f"--demuxer-rawvideo-w={self.width}",
            f"--demuxer-rawvideo-h={self.height}",
            "--demuxer-rawvideo-mp-format=rgb24",
            f"--demuxer-rawvideo-fps={self.fps}",
            "--loop-file=no",
            "--speed=1",
            "--cache=no",
            "--demuxer-readahead-secs=0",
            "--untimed=yes",
        ]
