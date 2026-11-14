# Learned wallpaper catalog APIs

AuraFlow's macOS Anime catalog now combines MoeWalls, DesktopHut,
LiveWallpapers4Free and Lively Wallpaper. MotionBGS Anime Nature and Dareful remain separate categories.

The two new public, read-only adapters were learned with
[api-anything](https://github.com/goodnight000/api-anything), version 0.4.0,
commit `985ae8f65f4c4918f24080bd7dbaf51fe92e6bf6`, on 2026-11-11.
Discovery used an isolated, signed-out Chromium profile and local-only mode.
No user browser profile, credentials or shared registry was used.

## Operations and verification

The exported operations are shipped as `desktophut-api.json` and
`livewallpapers4free-api.json` in the app's Resources. Each exposes:

| Operation | Inputs | Output |
| --- | --- | --- |
| `list` | `page` (positive integer) | Titles, source pages, thumbnails; DesktopHut also exposes preview and media kind |
| `search` | `query`, `page` | Matching cards; empty-query results are not recommendations |
| `detail` | `slug` | Preview video, original download URLs and quality labels |

Learning compared list pages 1/2 on DesktopHut, 2/3 on LiveWallpapers4Free
(the latter redirects page 1 to its canonical URL). Search compared `naruto`
page 1 and `miku` page 2. Detail compared two different public wallpaper slugs.
Server-rendered document requests were selected explicitly, avoiding unrelated
advertising/analytics requests in the captures.

Independent checks used DesktopHut list page 3, LiveWallpapers4Free list page 4,
`gojo` page 1 on both sites, the no-match query `auraflownoresults9x7z`, and
the unseen detail slugs `glowing-eyes-live-wallpaper-26aq` and
`lynae-in-the-golden-classroom-wuthering-waves`. `api-anything verify` passed
18/18 cases at plain HTTP tier 1. Public check arguments are included in the exports.
The exports explicitly set `learnedLoggedIn: false`: DesktopHut's anonymous
analytics cookies made the learner mark some captures as signed in. No exported
request has a Cookie/Authorization header; native and fresh-home HTTP checks
confirm that these operations work without authentication.

MyLiveWallpapers returned a browser challenge; WallpaperWaifu returned HTTP 403.
Neither is registered as a working source.

## Native execution

`LearnedAnimeSource` interprets the exported URL templates and CSS extraction
recipes using Foundation URLSession and SwiftSoup 2.14.3. There is no Node process,
browser, localhost server or registry dependency during normal app use.
The app executes only its bundled `list`, `search` and `detail` operations.

The initial catalog fetch reads one page per new site. Further pages load on
demand, with duplicate/cyclic page protection. Search reads at most three pages
per new site and has independent pagination. Per-site catalog caches allow
offline fallback, while failure of one site does not hide the other sources.
Media routes use the card's source host, not its Anime category.

DesktopHut Scene ZIPs are excluded because AuraFlow's video catalog cannot play
Wallpaper Engine scenes. Its no-match page contains popular recommendations;
the learned search recipe returns an empty list for that page. LiveWallpapers4Free
search cards are restricted to the site's Anime category. Media resolution keeps
small previews separate from original quality downloads, retaining source attribution
and linking back to each original page. No third-party videos are bundled.

## Replay / local REST API

Node >=22.13 and npm are needed only for these developer commands:

```sh
./script/catalog_api.sh verify
./script/catalog_api.sh call desktophut search query=gojo page=1
./script/catalog_api.sh call livewallpapers4free list page=4
./script/catalog_api.sh serve
```

The script pins api-anything 0.4.0 and seeds `.build/catalog-api` from the bundled
exports. `API_ANYTHING_CLI=/path/to/api-anything/dist/cli.js` can select an existing
checkout. It never changes the user's MCP/skill settings. `serve` binds loopback,
disables learning and writes, and exposes `/openapi.json`, `/mcp` and
`POST /v1/call/{site}/{op}`. api-anything creates its bearer token in the isolated
home; follow its startup output for the token file. The app does not require this server.

For refreshing an operation, use api-anything's `capture --outline`, select the
site's document request, then `add` with two public examples and an explicit
`--trigger` template. Validate a third value and an empty search, record `check`s,
run `verify`, and `export --keep-examples` back into Resources. Preserve `{page}`
in the trigger when adjusting recipes from saved captures. Do not commit captures,
browser profiles, cookies, tokens or the tool's private state.

Regression fixtures retain only representative public card/media markup.
`LearnedAnimeSourceTests` covers extraction, routing, pagination, cache, empty
search, original quality selection and unsupported media. The opt-in
`AURAFLOW_LIVE_LEARNED_CATALOG=1` test checks real listing/search/pages and two
preview/original MP4 pairs per site, reading at most 4 KiB of each video and
checking the MP4 header. It never starts playback or changes wallpaper settings.

## Music collection (2026-11-12)

The **With Music** catalog tab combines verified videos from DesktopHut and
LiveWallpapers4Free. Both sources now ship a fourth api-anything operation:

| Site | Operation | Inputs | Output |
| --- | --- | --- | --- |
| DesktopHut | `musicList` | `page` (positive integer) | Candidates from the site's music search |
| LiveWallpapers4Free | `musicList` | `tag` | Candidates from a public music/lofi tag |

DesktopHut was learned from `/search/music?page=1` and page 2, then checked on
page 3. LiveWallpapers4Free compared the `wallpaper-with-music` and `lofi` tags,
then checked `music-live-wallpaper`. The existing search and detail operations
are reused. Captures selected the first-party document request. Replay is tested
in a fresh, isolated api-anything home with no browser session or cookies.
The music operations are anonymous, read-only, HTTP tier 1; nothing is published
to the shared registry. Node/browser tooling remains a development dependency.

`MusicWallpaperCatalogProvider` decodes bounded samples from the **original**
video before including a candidate. It processes sixteen candidates per site per
batch, with at most four original-audio probes in flight across all sites, and caches each original URL's result
for seven days (inconclusive probes retry after ten minutes). A foreground
wallpaper download cancels catalog discovery. A music tag, a song-related title,
and an empty AAC track are insufficient for inclusion.

The bundled selection now contains 105 unique public music pages, including
lo-fi anime scenes, game soundtracks and orchestral backgrounds. All media is
resolved and audio-checked again at runtime. The original three selections remain:

- DesktopHut: **Midnight Hour Music Live Wallpaper**.
- LiveWallpapers4Free: **Girl Take a Rest LoFi** and **Darling the Franxx Anime
  Wallpaper with Music**.

Independent audio decoding of the first three seconds measured non-silent peaks
of -0.9, -13.5 and -3.5 dBFS respectively. Only page metadata is bundled; no
third-party media is redistributed with the app. Other candidates, including
**Miku Music Theme**, had silent audio or no audio and are excluded automatically.
Rare Gallery requires a download CAPTCHA; WallpaperWaifu sample downloads were
silent or unavailable. Neither is advertised as a working music source.

The music filter works across category and search results, preserves verified
flags when duplicate cards merge, and lets a later local silence check override
an older flag. Existing cached cards without a music field remain readable.
`AURAFLOW_LIVE_MUSIC_CATALOG=1` enables the opt-in live source test; ordinary
regressions use mocked providers and never change Desktop or Lock Screen playback.

## Expansion (2026-11-14)

The selection grew from 3 to **105** metadata-only music pages. A bounded audit
read 236 candidates from DesktopHut music/lofi/chill/sound search pages and
LiveWallpapers4Free music/lofi tags, decoding the actual originals. It confirmed
107 audible videos; unrelated birthday editing templates and phone-only releases
were removed, and the original selections retained. A music title or container
track alone is still insufficient: the production provider checks decoded audio.
Normal browsing loads sixteen candidates per source on demand, with four probes
total; it does not crawl or download this entire audit at startup. Music search
uses the same limit rather than the old four-result cap. A failed source page
can be retried without hiding another site's successful page.

The **With Music** tab reveals all already-known music selections independently
of the ordinary catalog's twelve-card display window. Reaching its end requests
new remote pages rather than consuming an unrelated hidden page and stopping on
the same trailing music card. Poster loading remains limited to the viewport.

**Lively Wallpaper** adds a public Anime library of **237** entries at the time of
verification. Its operations were learned and exported with api-anything 0.4.0
in an isolated, signed-out, local-only profile:

| Operation | Input | Output / verification |
| --- | --- | --- |
| `firstPage` | none | Canonical initial Anime page (this static site has no `/anime/1/` route) |
| `list` | `page` | Anime cards and pagination; learned pages 2/3, checked page 4 |
| `search` | none | The site's public `data/wallpaper-cards.json` index; the app applies the query and Anime filter locally, as the site's own search does |
| `detail` | `slug` | Small preview and full original MP4; learned two Gojo pages, checked Tanjiro |

All 8 api-anything checks passed at plain HTTP tier 1. The native search includes
matches from later pages, rejects non-Anime rows and unexpected media hosts, and
caches the index for the current source instance. Relative links resolve against
the final canonical response URL. The media allowlist adds only
`cdn.livelywallpaper.app`, and attribution links back to each source page.
The 237-original audio audit found no audio tracks, so this source belongs in the
ordinary Anime catalog and is not advertised as music. No media files, browser
profile, advertising requests, credentials or capture data ship with the app.

`MusicCatalogAuditTests.musicCatalogAuditCandidateAudio` is an opt-in metadata
refresh tool. Set `AURAFLOW_MUSIC_AUDIT_INPUT` to an absolute JSON array of
`CatalogWallpaper` candidates and `AURAFLOW_MUSIC_AUDIT_OUTPUT` to an absolute
output JSON path, then run only that test. It emits confirmed metadata and reads
bounded audio samples with four probes total. It never starts wallpaper playback,
orders windows, changes preferences or touches Desktop/Lock Screen descriptors.

During UI acceptance on macOS 27, the system collection action
`AXScrollToBottom` trapped inside SwiftUI's `AGAttribute.syncMainIfReferences` →
`ForEachState.item` → `AccessibilityLazyLayoutNode.accessibilityPerformAction`.
Use ordinary scroll-area scrolling for this verification. The catalog tests and
ordinary scrolling use stable card IDs; the collection's instant accessibility
jump is not used by the application itself.
