# Terminal program search and preset QA

Search includes executable programs discovered on PATH and all enabled official
Homebrew core formulae that publish executables. Match executable/package names,
descriptions and preset aliases; rank exact executable matches first. Local and
Homebrew entries for the same executable merge into one card. Queries never
install packages or launch programs. Known presets appear immediately; local
results and cached/background Homebrew results follow with query-generation
checks so older requests cannot replace a newer search.

The full index uses `full-program-search-cache-v2.json` to avoid reusing the old
restricted index. Cached full results work offline. Saved programs remain in the
library. Compatibility profiles supply useful default arguments and aliases;
they do not restrict discovery, installed versions, installation or launch.

Clicking a card resolves its executable or verifies the official formula and
specific binary before installing. The existing animation-option resolver runs
only after an explicit preview action and retries normal output once when a
documented option fails. Static output is retained after exit status 0.

Failed launches restore the previous preview and show
“Не удалось запустить программу. Пожалуйста, выберите другую.” Detailed diagnostics
remain in application logs. Failure does not quarantine a program or hide it
from search. Cancellation rolls back quietly.

## Optional preset smoke audit

`TerminalWallpaperCompatibility.profiles` records tested default launches for
animations, static cbonsai, dashboards and the lolcat/cava generated-input
adapters. Run `scripts/audit_terminal_wallpapers.sh` on a test macOS account.
Use `--install` only when provisioning the preset packages is intended.

The audit runs the real PTY/preview, checks static output retention, live updates
for 30 seconds and persisted configuration, and saves PNGs through the Metal
renderer to `.build/terminal-compatibility-audit`. Inspect the images when updating
presets. These recorded versions are QA evidence; newer releases and general CLI
programs remain searchable and can be tried from the app.
