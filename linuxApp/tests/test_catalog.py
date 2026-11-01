import io
import json
import threading
from pathlib import Path

import pytest

from auraflow import AuraFlowError
from auraflow.catalog import (
    Cancelled,
    Catalog,
    ResolvedMedia,
    Wallpaper,
    parse_detail,
    parse_listing,
    remote_url,
)

FIXTURES = Path(__file__).parent / "fixtures"
MP4 = b"\x00\x00\x00\x20ftypisom" + b"data" * 100000


class Response(io.BytesIO):
    def __init__(self, data=MP4, content_type="video/mp4", length=None):
        super().__init__(data)
        self.headers = {
            "Content-Type": content_type,
            "Content-Length": str(len(data) if length is None else length),
        }


@pytest.fixture
def wallpaper():
    return Wallpaper(
        "moewalls",
        "../../A title & rain",
        "https://moewalls.com/anime/test-live-wallpaper/",
        "https://cdn.moewalls.com/poster.jpg",
    )


def test_moewalls_parser_uses_the_same_fixtures_as_macos():
    page = parse_listing(
        "moewalls",
        (FIXTURES / "moewalls_archive_anime.html").read_text(),
        "https://moewalls.com/category/anime/",
    )
    assert [item.title for item in page.items] == ["Neon Ruins", "Black Hole"]
    assert page.has_more
    media = parse_detail(page.items[0], (FIXTURES / "moewalls_detail_neon_ruins.html").read_text())
    assert media.original == "https://media.moewalls.com/videos/neon-ruins-3840x2160.mp4"


def test_token_download_is_distinct_from_preview_and_never_executes_page_scripts(wallpaper):
    media = parse_detail(
        wallpaper,
        """
        <script>throw new Error('must never run')</script>
        <a id="moe-download" data-url="abc%2Btoken="></a>
        <video src="https://moewalls.com/wp-content/uploads/preview/2026/test.webm"></video>
    """,
    )
    assert media.original == "https://go.moewalls.com/download.php?video=abc%2Btoken="
    assert media.preview.endswith("test.webm")


def test_motionbgs_handles_unquoted_html_relative_urls_and_prefers_4k():
    page = parse_listing(
        "motionbgs",
        """
        <a title="Moon Lake live wallpaper" href=/moon-lake>
        <img src=/media/10/moon.jpg><span class=ttl>Moon Lake</span></a>
        <a href=/tag:anime-nature/2/>Next</a>
    """,
        "https://motionbgs.com/tag:anime-nature/",
    )
    assert page.items[0].page_url == "https://motionbgs.com/moon-lake"
    media = parse_detail(
        page.items[0],
        """
        <a href=/dl/hd/10>HD</a><a href=/dl/4k/10>4K</a>
        <meta content=https://motionbgs.com/media/10/moon.960x540.mp4 property=og:video>
    """,
    )
    assert media.original == "https://motionbgs.com/dl/4k/10"
    assert media.preview.endswith("960x540.mp4")


def test_dareful_wordpress_and_mux_details(paths):
    posts = [
        {
            "link": "https://dareful.com/video/mountains/",
            "title": {"rendered": "Mountains &amp; water"},
            "_embedded": {"wp:featuredmedia": [{"source_url": "https://dareful.com/poster.jpg"}]},
        }
    ]
    catalog = Catalog(paths, fetcher=lambda _: json.dumps(posts).encode())
    page = catalog.page("dareful")
    assert page.items[0].title == "Mountains & water"
    media = parse_detail(
        page.items[0], '<mux-player playback-id="abc123" metadata-video-title="Mountains">'
    )
    assert media == ResolvedMedia(
        "https://stream.mux.com/abc123/high.mp4", "https://stream.mux.com/abc123/low.mp4"
    )


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "ftp://example.com/f.mp4",
        "https://user:password@example.com/video.mp4",
    ],
)
def test_non_web_urls_and_embedded_credentials_are_rejected(url):
    with pytest.raises(AuraFlowError):
        remote_url(url)


def test_catalog_keeps_page_cache_for_offline_browsing(paths):
    listing = (FIXTURES / "moewalls_archive_anime.html").read_bytes()
    catalog = Catalog(paths, fetcher=lambda _: listing)
    fresh = catalog.page("moewalls")

    def offline(*_):
        raise AuraFlowError("Offline")

    catalog.fetch = offline
    cached = catalog.page("moewalls")
    assert cached.cached and cached.items == fresh.items
    assert catalog.cached_page("moewalls", "different query") is None


def test_download_is_atomic_reusable_offline_and_does_not_select_or_apply(paths, wallpaper, store):
    catalog = Catalog(paths, opener=lambda *_: Response())
    catalog.resolve = lambda _: ResolvedMedia("https://cdn.moewalls.com/file.mp4")
    before = store.load()
    progress = []
    target = catalog.download(
        wallpaper, progress=lambda current, total: progress.append((current, total))
    )
    assert target.parent == paths.data / "catalog/downloads"
    assert target.read_bytes() == MP4
    assert progress[-1] == (len(MP4), len(MP4))
    assert catalog.downloaded() == [(wallpaper, target)]
    assert store.load() == before

    def offline(*_):
        pytest.fail("A saved wallpaper must not require the network")

    catalog.resolve = offline
    assert catalog.download(wallpaper) == target
    assert list(target.parent.glob(".download-*")) == []


def test_cancellation_removes_partial_file_and_keeps_downloaded_library(paths, wallpaper):
    cancel = threading.Event()
    catalog = Catalog(paths, opener=lambda *_: Response())
    catalog.resolve = lambda _: ResolvedMedia("https://cdn.moewalls.com/file.mp4")
    with pytest.raises(Cancelled):
        catalog.download(wallpaper, cancel=cancel, progress=lambda *_: cancel.set())
    assert catalog.downloaded() == []
    assert list((paths.data / "catalog/downloads").iterdir()) == []


@pytest.mark.parametrize(
    "data,kind,length",
    [
        (b"<html>challenge</html>", "text/html", None),
        (b"<html>challenge</html>", "application/octet-stream", None),
        (b"not a video", "video/mp4", None),
        (MP4, "video/mp4", len(MP4) + 1),
    ],
)
def test_html_bad_media_and_truncated_transfers_are_not_published(
    paths, wallpaper, data, kind, length
):
    catalog = Catalog(paths, opener=lambda *_: Response(data, kind, length))
    catalog.resolve = lambda _: ResolvedMedia("https://cdn.moewalls.com/file.mp4")
    with pytest.raises(AuraFlowError):
        catalog.download(wallpaper)
    assert catalog.downloaded() == []
    assert list((paths.data / "catalog/downloads").iterdir()) == []


def test_webm_preview_keeps_its_container_and_is_not_a_downloaded_original(paths, wallpaper):
    payload = b"\x1a\x45\xdf\xa3" + b"webm bytes" * 10
    catalog = Catalog(paths, opener=lambda *_: Response(payload, "video/webm"))
    catalog.resolve = lambda _: ResolvedMedia(
        "https://cdn.moewalls.com/file.mp4", "https://cdn.moewalls.com/preview.webm"
    )
    target = catalog.download(wallpaper, preview=True)
    assert target.suffix == ".webm"
    assert target.parent.name == "previews"
    assert catalog.downloaded() == []


def test_missing_preview_does_not_download_the_large_original(paths, wallpaper):
    catalog = Catalog(paths)
    catalog.resolve = lambda _: ResolvedMedia("https://cdn.moewalls.com/large.mp4")
    with pytest.raises(AuraFlowError, match="lightweight"):
        catalog.download(wallpaper, preview=True)


def test_source_page_identity_is_checked_before_network(paths):
    catalog = Catalog(paths, fetcher=lambda _: pytest.fail("Must not request this page"))
    with pytest.raises(AuraFlowError, match="does not belong"):
        catalog.resolve(Wallpaper("moewalls", "Bad", "https://example.org/wallpaper"))


def test_motion_search_follows_provider_next_link_instead_of_guessing_route(paths):
    requests = []

    def fetcher(url):
        requests.append(url)
        return b"""<a title="Anime Lake live wallpaper" href=/anime-lake><img src=/lake.jpg></a>
                   <link href="https://motionbgs.com/tag:anime/2/" rel=next>"""

    catalog = Catalog(paths, fetcher=fetcher)
    catalog.page("motionbgs", "anime", 1)
    catalog.page("motionbgs", "anime", 2)
    assert requests[1] == "https://motionbgs.com/tag:anime/2/"


def test_unavailable_provider_does_not_poison_another_sources_cache(paths):
    catalog = Catalog(
        paths, fetcher=lambda _: (FIXTURES / "moewalls_archive_anime.html").read_bytes()
    )
    catalog.page("moewalls")

    def denied(*_):
        raise AuraFlowError("HTTP 403")

    catalog.fetch = denied
    with pytest.raises(AuraFlowError, match="403"):
        catalog.page("dareful")
    assert catalog.page("moewalls").cached
