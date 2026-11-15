# Music collection expansion — 15 November 2026

The reviewed collection contains **311 distinct wallpaper videos**: 295 from DesktopHut and 16 from LiveWallpapers4Free. These are anime, illustrated scenery and natural scenery, with original dimensions of at least 1920×1080 and at least 23.5 fps. Six copies with different names/source pages were removed by comparing original frames. Entries with visible creator/site marks, channel covers, end bumpers, poor formats or unrelated subjects were excluded. Known watermark aliases were also added to the global content exclusions.

Each selected original was decoded at five positions: near the beginning, quarter, middle, three quarters and near the end. Temporal contact sheets and enlarged corners were reviewed; the registry records original URLs and dimensions, not guesses from thumbnails. This is sampled review of the source available on the review date, not an automatic guarantee against future replacement of a site's files.

- **216** videos retain their own decoded, audible music or nature ambience. Audio was inspected without playing it. A local SoundAnalysis classification helped separate music/nature ambience from unrelated sound; titles and the mere existence of AAC tracks were not used as proof of sound.
- **95** clean videos are explicitly paired with one of three independent instrumental tracks. These reuse distinct artwork, rather than counting alternate soundtracks as additional wallpapers.
- The three MP3 tracks total 10,027,561 bytes and are downloaded once, shared and checked against bundled SHA-256 fingerprints and a decoded-audio check. No audio/video binaries are bundled in the app or committed to the repository.

## Soundtrack sources

All three authors publish these recordings under CC0. The detail view links to the track and credits its author separately from the wallpaper source.

| Track | Author | Source |
|---|---|---|
| Cozy Puzzle | MintoDog | https://opengameart.org/content/cozy-puzzle-in-game-2 |
| Our Expanse | Bobjt | https://opengameart.org/content/our-expanse |
| Blackout | SkyleTheFrench | https://opengameart.org/content/blackout |

The paired track is installed beside the managed video using an atomic hard-link/copy. Cached and already downloaded videos receive the attachment too; no video re-encoding is needed. Compatibility conversions carry the attachment to their output. Removing a downloaded video removes its companion, while deleting the shared soundtrack cache does not damage downloaded pairs.

The existing audio-only player resolves the companion and keeps its own full-length timeline. Short video loops and video refreshes do not restart it. Window visibility, screen saver, secure lock, sleep and volume-zero still use the existing shared pause/mute policy. No wallpaper descriptors, startup preferences or lock presentation behavior were changed.

## Loading and source routing

Reviewed native-audio entries use the bound bundled review evidence; opening Music no longer triggers hundreds of network/audio probes. Paired entries check only the three shared tracks. Unreviewed discovery remains disabled in Music. The complete bounded collection drains in the background without scroll-driven probe batches; cancellation/retry and full-collection search remain covered. Source routing uses the actual learned site's host, including nature cards, rather than inferring a site from the Anime/Scenic label.

The source adapters replay the existing public read-only api-anything recipes. A broad candidate scan was followed by original-media quality/audio checks and visual curation; no login, private endpoint, watermark removal or paid-download bypass was used.

## Validation

- 179 targeted catalog, audio and Desktop music tests passed. Coverage includes 320-card complete loading/search, ordinary/music source merging, old silent-video metadata with a new soundtrack, corrupt/missing/silent track rejection, 32 simultaneous requests sharing one download, repeat attachment installation and replacement, cached-video reuse, downloaded metadata and the real audio clock's pause/resume for embedded and separate sound.
- The production Music provider loaded all 311 entries from a cold catalog cache in 4.64 seconds, with the three real tracks fingerprinted and natively decoded as audible. No original-video probing was needed during that browse.
- 31 public api-anything operation checks passed across the existing source adapters.

## Native UI verification after unlock

The running build displayed `311 Music`. Sequential scroll-view Scroll Down actions reached the bottom (`scroll bar = 1`); accessibility snapshots encountered **311 distinct catalog card IDs**, including the final Light Beam Forest card. Posters and glass Audio badges were visible at both ends, and the count stayed at 311. The collection's AXScrollToBottom/AXScrollToTop actions were not used. The computer-use wheel command failed with `noWindowsAvailable`, so this verifies full list reachability and rendering rather than a physical-wheel frame-rate measurement.

The Light Beam Forest detail showed 1920×1080 and the separate Cozy Puzzle/MintoDog/CC0 credit. Download through the real UI succeeded and staged the preview. The managed H.264 video is 8,775,517 bytes (19.966667 seconds), its MP3 companion is 5,122,216 bytes (128 seconds), and the companion SHA-256 matches the bundled Cozy Puzzle fingerprint. The downloaded manifest retains `soundtrackID = cozy-piano` and `hasMusic = true`. The full Music list was reopened at the top afterward. The active Desktop/Lock Screen wallpaper and volume preferences were not changed.
