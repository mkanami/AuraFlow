# Learned anime catalog APIs

AuraFlow's macOS Anime catalog now combines MoeWalls, DesktopHut and
LiveWallpapers4Free. MotionBGS Anime Nature and Dareful remain separate categories.

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
