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

The current bundled music selection contains **60 visually reviewed pages**.
The earlier audio-only expansion and its historical counts are documented below;
audio presence alone did not reject branded channel covers. The content-policy
cleanup now supersedes those counts and removes two of the original three
anchors. Midnight Hour remains; the underwater Medusa scene supplies a reviewed
LiveWallpapers4Free selection. Only metadata is bundled; third-party media is
resolved and audio-checked at runtime.

Other candidates, including **Miku Music Theme**, had silent audio or no audio
and are excluded automatically. Rare Gallery requires a download CAPTCHA;
WallpaperWaifu sample downloads were silent or unavailable. Neither is advertised
as a working music source.

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

## Another 104 music wallpapers (2026-11-14)

The music selection increased from **105 to 209** pages, retaining every existing
entry. Additional listings came from the already-learned, anonymous api-anything
search operations: later DesktopHut music/lofi/sound pages plus soundtrack,
piano, synthwave and song searches, and LiveWallpapers4Free music/lofi/soundtrack/
song searches. Forty-eight bounded listing calls ran at HTTP tier 1; missing
pages were skipped without bypassing challenges or increasing request budgets.

The native audit checked 273 previously untested candidates and confirmed
111 audible originals. It first resolved all 105 current originals, excluded
matching original URLs, and counted each newly confirmed original URL once.
Seven technical event backgrounds and ambiguous ambient or long-form
releases were removed, leaving **104 additions**. The audit exports a
companion `.proof.json` containing the original URL and check time for each
confirmed card; these developer artifacts and media files are not bundled.

New and previous selections are interleaved, keeping the original three anchor
pages easy to find while making additions visible in the first music pages.
Identifiers use the decoded source-page slug, matching native site parsing;
percent-encoded Unicode must not create a second card for the same page.
Runtime audio verification, the four-probe limit and on-demand paging stay in
place. The bundled metadata does not assign `hasMusic` flags itself.

For a subsequent audit, set `AURAFLOW_MUSIC_AUDIT_EXCLUDE_CURRENT=1` along with
the input/output variables. This resolves the current selection with four
requests at most and rejects matching originals before decoding candidate audio.
An explicitly supplied empty input fails before making network requests.

## Music pagination repair (2026-11-14)

The visible music collection previously depended on the last cards receiving
another `onAppear`. Already-visible rows could miss that event after a page or
refresh completed, and a filtered page containing only silent or duplicate
candidates could leave the same trailing ID and stop pagination. The grid now
tracks visible IDs and checks the end again after loading, refresh and item-list
changes. A glass **Load more** button provides an explicit path; failures offer
**Try again**. Counts include `+` while more music pages remain.

`WallpaperCatalogMusicPaging` routes music-only requests through the repository
to the music provider without advancing unrelated sites. Music and ordinary
end-of-list state are independent. Up to three pages that add no visible results
are skipped per request, after which automatic loading pauses for an explicit
retry; unavailable or duplicate-only sources cannot produce a busy request loop.
Initial refresh owns provider cursors: local cached cards may expand during it,
but remote pagination waits until refresh finishes.

Music refresh preserves the previously verified catalog, including its progress
callbacks, and prioritizes not-yet-loaded candidates. A confirmed silent original
can still remove an old cached music claim. Cancelled verification batches are
restored to their queues instead of permanently skipping candidate wallpapers.
Poster loading remains tied to visible rows and a small lookahead; no videos are
resolved merely to draw catalog cards.

Regression coverage includes steady visible rows receiving several small pages,
filtered empty pages, scoped source routing, bounded retries, initial-refresh
cursor ownership, preserving an expanded cache, confirmed silence and cancelled
batch recovery. The targeted catalog suite passed 135 tests.

Live UI acceptance reached 210 verified music cards through ordinary scrolling.
The persisted music catalog contained all 209 bundled selections, plus one
additional discovered wallpaper. Closing and reopening the catalog retained all
210 entries. No collection accessibility instant-jump action was used.


## Watermark and channel-cover cleanup (2026-11-14)

A visual audit examined 676 current catalog posters and sampled preview-video
frames for the 97 music candidates outside the 113-entry channel-cover family.
Corner enlargements exposed DesktopHut marks and channel signatures that were
not apparent in the listing thumbnails. The exclusion registry records **163**
entries: 113 channel covers/bumpers, 41 other branded/promotional entries, and
9 music videos withheld because a complete frame sample could not be reviewed.
The 210-card music cache therefore has 60 accepted pages. These are sampled
visual reviews, not a claim of automatic recognition of every possible watermark
in every frame or future source upload.

`CatalogContentPolicy` rejects reviewed IDs, source-page aliases and poster
aliases (including tracking-query variants), plus the HDsoundi/music-cover
family. Managed refresh/progress, cached catalogs, search, ordinary and music
pagination, UI merges and remote media resolution share the same policy.
Old unified caches are pruned and rewritten. Downloaded branded cards are hidden
from the catalog; their manifests and personal media files are preserved.
The app neither crops nor paints over marks, and source attribution links remain.

The default music sources now consume only the reviewed bundled pages, including
when searching and reopening an older cache. A cached audio flag cannot approve
an unreviewed page or a changed poster. Once the reviewed queues end, pagination
finishes without requesting arbitrary channel-cover search results. Original
audio decoding and the four-probe limit remain in place. Ordinary site discovery
continues with the shared exclusions; newly encountered visual marks need review
and a registry update.

`CatalogArtworkAuditTests.catalogArtworkAuditResolvesPreviewVideos` is an opt-in
read-only developer helper using `AURAFLOW_ARTWORK_AUDIT_INPUT` and
`AURAFLOW_ARTWORK_AUDIT_OUTPUT`. It resolves at most four public previews at once
without playing media or changing Desktop/Lock Screen preferences.

Validation: 142 targeted catalog tests passed, followed by the opt-in live
original-audio check against both music sites. The rebuilt app launched and its
native interface showed zero HDsoundi search results, 60 music cards, a completed
end of list after ordinary scrolling, and the same 60 cards after reopening.
The rewritten unified cache held 513 cards and the music cache 60; neither
contained any excluded IDs or channel-cover titles. Screen capture was
unavailable, so UI verification used the native accessibility tree.

## Scroll responsiveness (2026-11-14)

A live process sample during scrolling found repeated `musicCount` reads running
full metadata deduplication and content-policy regex matching inside the catalog
header. A 600-card presentation benchmark reproduced the cost: one set of header
and grid reads took a median 126.94 ms before the fix.

Catalog presentation values now cache their results until the underlying list,
filter or audio evidence changes. Content-policy decisions use a bounded,
thread-safe cache keyed by the inspected metadata, with precompiled matching
rules. Changed IDs/titles/pages/posters still receive independent decisions.
The same benchmark's repeated reads were below 0.01 ms after the fix. Its initial
cold read was 60.72 ms; this is a CPU benchmark of derived data, not a display-FPS
measurement.

Visibility bookkeeping no longer publishes a SwiftUI state change for each card
entering or leaving the viewport. Stable cards have an Equatable boundary, and
the audio badge observes metadata independently. Repeated inspection of an
already-known music card does not republish the same value across the app.
The footer retains the same height while loading, avoiding a document-size jump.
Native Liquid Glass styling remains unchanged.

Browsing now loads posters only. Unknown remote audio is checked in the detail
view rather than resolving original videos for passing grid cards. Known music
badges remain available; local-download audio inspection waits briefly so a fast
scroll can cancel it. Existing bounded image loading, shared requests and poster
lookahead remain in place.

Validation: 147 targeted catalog tests passed, including continuous two-way
scrolling, steady trailing rows receiving additional pages, first-click handling,
cache invalidation after search/paging/audio changes, no remote-video resolution
while browsing, and stable document height/offset while loading. The new app
bundle built and launched successfully through `script/build_and_run.sh --verify`.

### Live UI acceptance (2026-11-15)

After unlocking the Mac, the installed `c72d130` build was exercised through the
native UI. Ordinary wheel scrolling expanded the catalog from 24 to **589**
cards, including a remote page beyond the restored cache. Twenty further wheel
operations moved up and down the loaded list; reported scroll positions advanced
monotonically in each direction and returned to the starting offset. There was
no crash, first-page stall or reversal reset. Opening a visible card and pressing
Back retained the same group of visible cards. Switching to With Music showed
all 60 known music entries and returned to the first music row. Screenshots
confirmed the existing glass card appearance and loaded posters.

A 15-second live process sample was captured during the two-way scroll. Before
the fix, `musicCount` occupied 2,665 of 9,541 main-thread observations (27.93%),
mostly inside repeated content-policy matching. In the new sample these header,
count, filter and policy getters occupied zero of 7,328 main-thread observations.
The removed work is no longer a sampled scrolling bottleneck. Sampling and
accessibility-driven wheel input do not measure display FPS; no fixed frame-rate
claim is made.

## Music loading from an empty cache (2026-11-15)

The tab and its count label are now named **Music**. Warm-cache scrolling could
reach all 60 reviewed entries, but that did not cover the first-launch path.
Previously, music refresh returned only the first audio-verification batch and
left the rest dependent on trailing-card events. Failed or inconclusive probes
were consumed without retaining a retry candidate, and reviewed search results
were capped at sixteen candidates per site.

The bounded reviewed collection now drains during refresh, with at most four
probes in flight across sites. Progress publishes settled prefixes so later
probe completions cannot insert cards ahead of already-visible results. Each
completed batch is persisted. Card rendering still loads posters only.
Unknown audio or a transient source failure retains the reviewed card in a
separate retry queue; that queue cannot make refresh loop indefinitely. A retry
that adds nothing reports an error and leaves the remaining candidates pending,
rather than reporting the collection exhausted. Inconclusive cached audio does
not suppress an explicit retry. A paging call on an uninitialized provider
initializes the reviewed collection instead of immediately returning an empty end.
Reviewed search checks every matching candidate with the same concurrency bound.

Music paging exposes its pending state through the managed provider and
repository. Initial refresh updates that state, and the footer shows
**Loading music…** while verification is active. The final count drops its `+`
when the reviewed collection is complete.

Validation: **153** targeted catalog tests passed. New cases cover a 60-card
empty-cache load without row-appearance events, lazy provider initialization,
40 transient failures/inconclusive results after 20 successes, bounded explicit
retry, untruncated search, stable progress order and four-probe concurrency.

For live acceptance, the GUI was stopped and only catalog metadata caches were
moved to a reversible developer backup. The rebuilt app's Music count advanced
from **7 to 21 to 60 without scrolling or pressing Load more**. The new music
cache contained all 60 reviewed IDs and 60 freshly decoded `audible` results.
Ordinary scrolling then exposed **60 distinct card IDs** and reached the true
end. Closing/reopening the catalog and restarting the application both retained
60 Music cards. Previous ordinary catalog metadata was merged back after the
cold-start test; downloaded media and wallpaper/playback preferences were not
part of the test reset.

## Text and watermark audit (2026-11-17)

Music now contains 305 reviewed selections. From the previous 311, this audit
removed 28 clips with visible lettering or signatures, four cards whose source
supplies an NSFW warning poster, and one clip whose beginning could not be
retrieved for review. These exclusions apply to cached cards, search, paging,
downloaded-card visibility and new downloads. Personal media files are retained.

The remaining 278 originals were checked using their first decoded frame,
additional samples near the beginning, and five samples across the duration.
Their site posters were compared with original frames. Enlarged edge strips
and OCR were used to flag small lettering; visual decisions, not OCR output
alone, determine exclusion. This is a sampled audit, not continuous recognition
of every frame or a guarantee against future changes at a source site.

To preserve the size of Music, 65 additional candidates were inspected. The
27 replacements use the existing verified instrumental soundtracks and have
decoded originals of at least 1920×1080 and 23.5 fps. Six original frames,
including frame zero, their enlarged corners and their site posters were
reviewed. Duplicate artwork and candidates with corner logos, creator marks,
signage, unsuitable imagery or incomplete quality checks were not added.

`MusicCatalogReview` now requires explicit approval of both frame zero and the
poster, with at least six sampled frames. A clean midpoint alone is insufficient.
Warning-poster detection also covers new IDs and URL-encoded/case variants.
Both download entry points enforce the content policy before looking for a
cached file or trying a caller-supplied original URL.

Validation: 55 targeted tests passed, including warning-poster aliases, removal
from persisted caches, direct and preferred-source download rejection without
deleting personal files, review coverage, 300+ unique selections and music
loading/paging.

The rebuilt application displayed **305 Music** entries. Searching for the
removed Ayane card returned zero results; a new Samurai on Ocean Waves card
opened its 3840×2160 detail preview with the separate soundtrack attribution.
The persisted music cache contained exactly the 305 approved IDs and no stale
entries from the previous selection.
