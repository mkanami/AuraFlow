from __future__ import annotations

import hashlib
import html
import http.client
import json
import os
import re
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path

from bs4 import BeautifulSoup

from . import AuraFlowError
from .paths import AppPaths, private_directory

SOURCES = {"moewalls": "MoeWalls", "motionbgs": "MotionBGS", "dareful": "Dareful"}
BASES = {
    "moewalls": "https://moewalls.com/",
    "motionbgs": "https://motionbgs.com/",
    "dareful": "https://dareful.com/",
}
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AuraFlow/0.2"
VIDEO_SUFFIXES = (".mp4", ".webm", ".mov", ".m4v")


class Cancelled(AuraFlowError):
    def __init__(self):
        super().__init__("Download cancelled.")


def check_cancel(cancel: threading.Event | None) -> None:
    if cancel and cancel.is_set():
        raise Cancelled()


def remote_url(value: str, base: str = "") -> str:
    result = urllib.parse.urljoin(base, html.unescape(value))
    parts = urllib.parse.urlsplit(result)
    if parts.scheme not in ("https", "http") or not parts.hostname or parts.username:
        raise AuraFlowError("The catalog returned an invalid web URL.")
    return result


def open_url(url: str, referer: str = ""):
    request = urllib.request.Request(
        remote_url(url),
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
            "Referer": referer,
        },
    )
    try:
        response = urllib.request.urlopen(request, timeout=12)
        remote_url(response.url)
        return response
    except (urllib.error.URLError, OSError) as exc:
        raise AuraFlowError(f"Catalog request failed: {exc}") from exc


def fetch(url: str, limit: int = 4 * 1024 * 1024) -> bytes:
    try:
        with open_url(url) as response:
            data = response.read(limit + 1)
    except (http.client.HTTPException, OSError) as exc:
        raise AuraFlowError(f"Catalog transfer failed: {exc}") from exc
    if len(data) > limit:
        raise AuraFlowError("Catalog response is too large.")
    return data


@dataclass(frozen=True)
class Wallpaper:
    source: str
    title: str
    page_url: str
    poster_url: str | None = None

    @property
    def id(self) -> str:
        return hashlib.sha256(self.page_url.encode()).hexdigest()[:24]


@dataclass(frozen=True)
class CatalogPage:
    items: list[Wallpaper]
    has_more: bool
    cached: bool = False
    next_url: str | None = None


@dataclass(frozen=True)
class ResolvedMedia:
    original: str
    preview: str | None = None


def title_text(value: str) -> str:
    text = BeautifulSoup(value, "html.parser").get_text(" ", strip=True)
    return re.sub(r"\s+(?:Live Wallpaper|live wallpaper)(?:\s*[-|].*)?$", "", text).strip()


def parse_listing(source: str, text: str, page_url: str) -> CatalogPage:
    soup = BeautifulSoup(text, "html.parser")
    items, seen = [], set()
    for anchor in soup.select("a[href]"):
        image = anchor.find("img")
        if not image:
            continue
        url = remote_url(str(anchor["href"]), page_url)
        path = urllib.parse.urlsplit(url).path
        if urllib.parse.urlsplit(url).hostname != urllib.parse.urlsplit(page_url).hostname:
            continue
        if source == "moewalls" and not path.rstrip("/").endswith("-live-wallpaper"):
            continue
        if source == "motionbgs" and "live wallpaper" not in str(anchor.get("title", "")).lower():
            continue
        if source == "dareful" and not ("/video/" in path or "stock-footage" in path):
            continue
        if url in seen:
            continue
        seen.add(url)
        title = title_text(str(anchor.get("title") or image.get("alt") or anchor.get_text(" ")))
        title = title or path.rstrip("/").rsplit("/", 1)[-1].replace("-", " ")
        poster = image.get("data-src") or image.get("data-lazy-src") or image.get("src")
        items.append(
            Wallpaper(source, title, url, remote_url(str(poster), page_url) if poster else None)
        )
    next_url = None
    for anchor in soup.select("a[href], link[href]"):
        if "next" in anchor.get("rel", []) or anchor.get_text(strip=True).lower().startswith(
            "next"
        ):
            candidate = remote_url(str(anchor["href"]), page_url)
            if (
                urllib.parse.urlsplit(candidate).hostname
                == urllib.parse.urlsplit(page_url).hostname
            ):
                next_url = candidate
                break
    return CatalogPage(items, bool(next_url), next_url=next_url)


def parse_detail(item: Wallpaper, text: str) -> ResolvedMedia:
    soup = BeautifulSoup(text, "html.parser")
    videos = []
    for node in soup.select("video[src], source[src], meta[property^='og:video']"):
        value = node.get("src") or node.get("content")
        if value:
            videos.append(remote_url(str(value), item.page_url))
    if item.source == "moewalls":
        button = soup.select_one("#moe-download")
        value = str(button.get("data-url") or button.get("href") or "") if button else ""
        if value and re.fullmatch(r"[A-Za-z0-9%=_+\-]+", value):
            original = "https://go.moewalls.com/download.php?video=" + value
        elif value and value != "#":
            original = remote_url(value, item.page_url)
        else:
            originals = [url for url in videos if "/preview/" not in url]
            original = originals[0] if originals else None
        preview = next((url for url in videos if "/preview/" in url), None)
    elif item.source == "motionbgs":
        downloads = [
            remote_url(str(a["href"]), item.page_url)
            for a in soup.select("a[href]")
            if re.match(r"/dl/(4k|hd)/\d+", urllib.parse.urlsplit(str(a["href"])).path)
        ]
        downloads.sort(key=lambda url: "/4k/" not in url)
        original = downloads[0] if downloads else None
        preview = videos[0] if videos else None
    else:
        node = soup.select_one("mux-player[playback-id]")
        match = re.search(r"https://stream\.mux\.com/([A-Za-z0-9_-]+)\.m3u8", text)
        playback = str(node["playback-id"]) if node else (match[1] if match else "")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", playback):
            raise AuraFlowError("Dareful did not provide a playable video.")
        original, preview = (
            f"https://stream.mux.com/{playback}/{quality}.mp4" for quality in ("high", "low")
        )
    if not original:
        raise AuraFlowError(f"{SOURCES[item.source]} did not provide an original download link.")
    return ResolvedMedia(remote_url(original), preview)


class Catalog:
    def __init__(self, paths: AppPaths, fetcher=fetch, opener=open_url):
        self.paths, self.fetch, self.open = paths, fetcher, opener

    def listing_url(self, source: str, query: str, page: int) -> str:
        if source not in SOURCES or not 1 <= page <= 10000:
            raise AuraFlowError("Choose a valid catalog source and page.")
        base = BASES[source]
        if source == "moewalls":
            if query:
                return base + "?" + urllib.parse.urlencode({"s": query, "paged": page})
            return base + "category/anime/" + (f"page/{page}/" if page > 1 else "")
        if source == "motionbgs":
            if query:
                return base + "search?" + urllib.parse.urlencode({"q": query, "page": page})
            return base + "tag:anime-nature/" + (f"{page}/" if page > 1 else "")
        return (
            base
            + "wp-json/wp/v2/posts?"
            + urllib.parse.urlencode(
                {
                    "per_page": 30,
                    "page": page,
                    "search": query,
                    "_fields": "id,link,title,featured_media,_embedded",
                    "_embed": "wp:featuredmedia",
                }
            )
        )

    def cached_page(self, source: str, query: str = "", page: int = 1) -> CatalogPage | None:
        cache = self._cache(self.listing_url(source, query, page))
        try:
            raw = json.loads(cache.read_text())
            return CatalogPage(
                [Wallpaper(**item) for item in raw["items"]],
                raw["has_more"],
                True,
                raw.get("next_url"),
            )
        except (OSError, ValueError, TypeError, KeyError):
            return None

    def page(self, source: str, query: str = "", page: int = 1) -> CatalogPage:
        url = self.listing_url(source, query, page)
        cache_key = url
        if source == "motionbgs" and query and page > 1:
            previous = self.cached_page(source, query, page - 1)
            if previous is None:
                raise AuraFlowError("Load the preceding search page first.")
            if not previous.next_url:
                return CatalogPage([], False)
            url = remote_url(previous.next_url)
            if urllib.parse.urlsplit(url).hostname != urllib.parse.urlsplit(BASES[source]).hostname:
                raise AuraFlowError("Invalid catalog pagination link.")
        try:
            data = self.fetch(url).decode("utf-8", errors="replace")
            if source == "dareful":
                posts = json.loads(data)
                items = []
                for post in posts:
                    images = post.get("_embedded", {}).get("wp:featuredmedia", [])
                    poster = images[0].get("source_url") if images else None
                    items.append(
                        Wallpaper(
                            source,
                            title_text(post["title"]["rendered"]),
                            remote_url(post["link"]),
                            poster,
                        )
                    )
                result = CatalogPage(items, len(items) == 30)
            else:
                result = parse_listing(source, data, url)
            if not result.items:
                if any(word in data.lower() for word in ("cf-chl-", "just a moment", "captcha")):
                    raise AuraFlowError(
                        "The provider requires browser verification. Open its source page."
                    )
                return result
            self._write_json(
                self._cache(cache_key),
                {
                    "items": [asdict(item) for item in result.items],
                    "has_more": result.has_more,
                    "next_url": result.next_url,
                },
            )
            return result
        except (AuraFlowError, ValueError, KeyError, TypeError) as exc:
            cached = self.cached_page(source, query, page)
            if cached:
                return cached
            if isinstance(exc, AuraFlowError):
                raise
            raise AuraFlowError(
                f"{SOURCES[source]} returned an unsupported catalog response."
            ) from exc

    def resolve(self, item: Wallpaper) -> ResolvedMedia:
        if item.source not in SOURCES:
            raise AuraFlowError("Unknown catalog source.")
        if (
            urllib.parse.urlsplit(item.page_url).hostname
            != urllib.parse.urlsplit(BASES[item.source]).hostname
        ):
            raise AuraFlowError("Wallpaper page does not belong to its source.")
        return parse_detail(item, self.fetch(item.page_url).decode("utf-8", errors="replace"))

    def poster(self, item: Wallpaper) -> bytes:
        if not item.poster_url:
            return b""
        target = self.paths.data / "catalog/posters" / (item.id + ".image")
        if target.exists():
            return target.read_bytes()
        data = self.fetch(item.poster_url, limit=4 * 1024 * 1024)
        self._write_bytes(target, data)
        return data

    def download(
        self,
        item: Wallpaper,
        *,
        cancel: threading.Event | None = None,
        progress: Callable[[int, int | None], None] = lambda *_: None,
        preview: bool = False,
    ) -> Path:
        check_cancel(cancel)
        kind = "previews" if preview else "downloads"
        directory = self.paths.data / "catalog" / kind
        for suffix in VIDEO_SUFFIXES:
            cached = directory / (item.id + suffix)
            if cached.is_file() and cached.stat().st_size:
                self._write_json(cached.with_suffix(".json"), asdict(item))
                return cached
        media = self.resolve(item)
        url = media.preview if preview else media.original
        if not url:
            raise AuraFlowError(
                "No lightweight preview is available. Download the original to preview it."
            )
        check_cancel(cancel)
        suffix = Path(urllib.parse.urlsplit(url).path).suffix.lower()
        suffix = suffix if suffix in VIDEO_SUFFIXES else ".mp4"
        target = directory / (item.id + suffix)
        private_directory(target.parent)
        fd, temporary = tempfile.mkstemp(prefix=".download-", dir=target.parent)
        received = 0
        try:
            with os.fdopen(fd, "wb") as stream, self.open(url, item.page_url) as response:
                content_type = response.headers.get("Content-Type", "").lower()
                if "text/" in content_type or "html" in content_type or "json" in content_type:
                    raise AuraFlowError("The provider returned a web page instead of a video.")
                try:
                    total = int(response.headers.get("Content-Length", "0")) or None
                except (ValueError, TypeError) as exc:
                    raise AuraFlowError("The provider returned an invalid download size.") from exc
                if total and total < 0:
                    raise AuraFlowError("The provider returned an invalid download size.")
                max_size = 64 * 1024 * 1024 if preview else 4 * 1024 * 1024 * 1024
                if total and total > max_size:
                    raise AuraFlowError("The media exceeds the download size limit.")
                while True:
                    check_cancel(cancel)
                    chunk = response.read(128 * 1024)
                    if not chunk:
                        break
                    if received == 0 and chunk.lstrip().lower().startswith(
                        (b"<!doctype", b"<html")
                    ):
                        raise AuraFlowError("The provider returned an HTML verification page.")
                    if received == 0:
                        if chunk.startswith(b"\x1a\x45\xdf\xa3"):
                            target = target.with_suffix(".webm")
                        elif len(chunk) < 12 or chunk[4:8] not in (
                            b"ftyp",
                            b"moov",
                            b"mdat",
                            b"wide",
                            b"free",
                        ):
                            raise AuraFlowError(
                                "The response is not a supported MP4 or WebM video."
                            )
                    stream.write(chunk)
                    received += len(chunk)
                    if received > max_size:
                        raise AuraFlowError("The media exceeds the download size limit.")
                    progress(received, total)
                if not received or (total and received != total):
                    raise AuraFlowError("The video download is incomplete.")
                stream.flush()
                os.fsync(stream.fileno())
            check_cancel(cancel)
            os.replace(temporary, target)
            self._write_json(target.with_suffix(".json"), asdict(item))
            return target
        except http.client.HTTPException as exc:
            raise AuraFlowError(f"Video transfer was interrupted: {exc}") from exc
        finally:
            Path(temporary).unlink(missing_ok=True)

    def downloaded(self) -> list[tuple[Wallpaper, Path]]:
        result = []
        for sidecar in sorted((self.paths.data / "catalog/downloads").glob("*.json")):
            try:
                item = Wallpaper(**json.loads(sidecar.read_text()))
                for suffix in VIDEO_SUFFIXES:
                    media = sidecar.with_suffix(suffix)
                    if media.is_file():
                        result.append((item, media))
                        break
            except (OSError, ValueError, TypeError):
                continue
        return result

    def _cache(self, url: str) -> Path:
        return (
            self.paths.data / "catalog/pages" / (hashlib.sha256(url.encode()).hexdigest() + ".json")
        )

    @staticmethod
    def _write_bytes(path: Path, data: bytes) -> None:
        private_directory(path.parent)
        fd, temporary = tempfile.mkstemp(prefix=".catalog-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
            os.replace(temporary, path)
        finally:
            Path(temporary).unlink(missing_ok=True)

    @classmethod
    def _write_json(cls, path: Path, value: object) -> None:
        cls._write_bytes(path, json.dumps(value, ensure_ascii=False).encode())
