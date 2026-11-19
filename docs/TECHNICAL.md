# Technical notes

This document keeps implementation, development, and deep troubleshooting
details out of the user-facing README.

## Architecture

Aria runs as a plugin inside Omarchy's existing `omarchy-shell`
Quickshell process. It provides a shared service, a bar widget, and a lazy-loaded
panel. There is no embedded website, browser engine, or second shell process.

Soloist is the only playback target. The app never launches the official
Spotify desktop app and never starts an audio engine of its own: it resolves
the user's Soloist receiver — a genuine Spotify Connect device — and routes
transport commands to it. Ordinary controls, media keys, and the `aria.player`
IPC target go through `soloist ctl`. Active playback on other Spotify Connect
devices comes from the Spotify Web API, refreshed while a UI is visible and at
a slower rate while that device is playing; fast `/me/player` polling is
reserved for remote or unknown targets. Spotify data and other user actions
also use the Web API.

Soloist's Connect registration can blink out of `/me/player/devices` while it
keeps playing, so device resolution also accepts Soloist's fallback report and
cross-checks playback state with `soloist ctl now --json`. A UI-only synthetic
receiver (`soloist:aria`) stands in until the real Connect id is visible, so
the device list and the Now playing card stay stable across refreshes.

Login and browsing run through the plugin-owned `omarchy-spotify-backend`
(Aria's backend) Rust process, executed with its `session` subcommand: device
authorization plus native collection, playlist, search, catalogue, and Connect
requests over private stdin/stdout. Only that subcommand runs — the backend's
embedded librespot audio engine and MPRIS interface are never started, and no
systemd unit is enabled at login.

Volume sliders apply while the knob moves; the seek slider still commits on
release so a drag cannot make the player re-buffer per frame. A drag emits a
command per input event, so `Service` coalesces them: the first value is sent
immediately and later ones are queued and flushed at a per-backend interval,
`Api.volumeFlushInterval` — 80 ms for a local command, 250 ms for the
rate-limited Web API, and 120 ms for Sonos. The queued value is only cleared
once a backend accepts the command, so the position the knob was released at is
always the one that lands. The optimistic slider value is held until the player
reports it, and playback state is refetched once the drag settles rather than
after every command.

## Runtime requirements

- Omarchy 4 with the Quickshell shell enabled
- Spotify Premium
- a paired Soloist receiver (`~/.local/bin/soloist`) for playback on this
  computer; see the README's Soloist section for setup
- Omarchy base tools: `secret-tool`, `openssl`, `socat`, `xdg-open`, `wl-copy`,
  `avahi-browse`, `systemctl`, and Python 3

The verified-release fast path also uses `curl` and GitHub CLI when available;
neither is trusted as a bypass when provenance verification cannot complete.

Omarchy's plugin installer deliberately clones and validates plugins without
running install hooks or privileged code. The enabled plugin therefore prepares
local playback on first load. It downloads the raw backend for the current
architecture from the matching version tag, checks the release checksum, then
requires GitHub's signed build provenance to match this repository, the pinned
release workflow, the exact tag and tagged commit, and a GitHub-hosted runner.
The tagged commit must be an ancestor of the checkout, and the backend source
and Rust toolchain must be unchanged between them. This permits later UI and
documentation commits without weakening the backend source binding. A
same-release checksum alone is never accepted as provenance.

If `gh` is unavailable or any download, checksum, identity, or attestation
check fails, the artifact is not executed. Setup instead builds `Cargo.lock`
from the reviewed source with the available Cargo when present.
Configuration, verified downloads, and local builds need no privilege.

Omarchy treats any write inside a plugin directory as a change to the plugin and
hot-reloads it, so the backend is compiled to
`$XDG_CACHE_HOME/aria/target` (override with `CARGO_TARGET_DIR`),
never to the plugin directory itself. This keeps the recursive file watcher
from reloading the plugin — and killing the build — mid-setup. A stale
`backend/target/` left by an older build can be removed; the backend ignores it.

## Authentication

`NativeSession.qml` supervises the repository's backend `session` command over
private stdin/stdout. The backend owns device authorization, native collection,
playlist, search, catalogue and Connect requests. No personal Developer app or
external proxy is involved. Browser pairing is performed on Spotify's website,
then a reusable librespot credential serves both browsing and playback.

An optional second, full-scope OAuth login (`AuthManager.qml`) uses the user's
own Spotify app client ID for the reads the native streaming token cannot do —
listening history and top rankings on the For you page. Its refresh token
lives in the same on-disk store, the login is one-time and renews itself, and
every other feature works without it. Native protocol extensions are implemented locally using
the existing pinned librespot dependency. Adapted JSON mapping code retains its
MIT attribution in `THIRD_PARTY_NOTICES.md`; spotatui is not a dependency.

Session cancellation and logout terminate the browsing process, discarding all
account-specific caches and pending requests. Playlist mutations are never
retried automatically. Tokens travel only through private process pipes when a
Connect receiver needs a streaming grant; they do not enter shell arguments,
settings or diagnostic logs. Old client-scoped keyring entries are untouched.

Reusable local-playback authorization is stored with owner-only permissions in
`$XDG_STATE_HOME/aria`; older credentials under `$XDG_CACHE_HOME`
are accepted once and migrated so clearing disposable caches cannot deauthorize
this computer. The backend session credentials (`oauth`, `zeroconf`), its
socket and its default configuration path are all scoped to Aria's own `aria`
names. Setup never adopts a sign-in saved under the legacy `omarchy-spotify`
name: those credentials may belong to the original Omarchy Spotify plugin, and
the account is always chosen through Aria's own login flow. Player preferences (filters, search history, scroll positions,
and similar) are written to `$XDG_STATE_HOME/aria/session.json` so they do not
pollute Omarchy's `shell.json`. The last page is not part of that state: the
player opens on the landing page chosen in Settings (For you, Liked Songs,
Search, Playlists, or one playlist; Liked Songs by default), and only an
explicit payload (an artist or album link) selects a different page. The
record also notes whether the full player was open and which Hyprland
workspace it occupied, with a short heartbeat, so a shell restart can reopen
it in place while a later login stays closed. The restored window is moved with
`follow = false` and hidden until the move completes, so the user's workspace
never changes and no copy flashes on the wrong one. Older copies kept as plugin settings
are read once and removed from `shell.json` after that file is written.
Album and playlist covers are downloaded by a small HTTP/1.1 helper into
`$XDG_STATE_HOME/aria/artwork` (capped at 320 files). Qt's own image loader uses
HTTP/2, which Spotify's image CDN intermittently drops, so covers loaded only
after a long retry backoff; the local copies are ready immediately and survive
shell restarts. Remote URLs remain the fallback until a cached file is ready,
and no covers are fetched at all when artwork is switched off.

Short-lived access tokens and PKCE values remain in the shell process. OAuth
state is checked, callback listeners bind explicitly to IPv4 loopback, API URLs
are restricted to
`https://api.spotify.com/v1`, and sensitive credential patterns are redacted
before an error can reach the interface.

The app requests only the library, follow, listening-history, playlist,
playback-position, and playback-control permissions used by visible features.
It does not request profile or email permissions.

The Spotify account grant unlocks search, library, and remote control. Local
playback remains a separate approval. The full player and mini-player stay
usable after the account connects, even while that second step is unfinished.

## Local Spotify Connect

New playback keeps Spotify's currently active device. An explicit
choice in the Devices view takes priority, and the app's local device is used
only when no active target is available. Restricted active devices are kept as
the target rather than silently moving playback locally; Spotify may reject the
new selection when it does not allow Web API control. The app can perform a
one-shot `_spotify-connect._tcp` lookup for nearby receivers omitted from
Spotify's device response. It also resolves opaque Web API device names against
the matching locally advertised alias. For ordinary receivers, the helper
re-encrypts local playback's owner-only reusable credential for the receiver's
ephemeral ZeroConf key. Access-token receivers such as JBL receive the
short-lived streaming token as the ZeroConf blob, with a device-scoped mint
and the reusable credential as fallbacks; authorization-code receivers such
as Sonos receive a receiver-scoped code exchanged from that grant.
It then waits for Spotify to report the genuine device before transferring
playback when needed. It never asks for or stores the user's password.

An album or playlist in its unfiltered Original order starts Spotify's native
context, preserving the complete server-side collection. Sorting or filtering
switches row, context-menu, and collection-level playback to the displayed URI
sequence instead. Spotify accepts at most 100 URIs in one custom play request,
so the interface reports that limit when a longer visible sequence is started.

Once a restricted Sonos is active, the Web API rejects its player commands.
The app therefore resolves that same receiver on the LAN and sends fixed UPnP
AVTransport or RenderingControl actions for play, pause, previous, next, seek,
shuffle/repeat mode, and volume. Targets still come only from validated local
Spotify Connect discovery. Discovery also reads the current Sonos master volume
from RenderingControl because Spotify's `volume_percent` field is nullable; the
UI remembers that value and updates it immediately after a volume command. The
helper drops any command issued while an earlier one is still running, so a
volume drag checks `controlBusy` and retries the queued value instead of losing
it. When playback has moved elsewhere, a local Play wake is attempted first;
the OAuth activation flow remains the fallback for a Sonos that has actually
lost its Spotify session. Receiver discovery and requests are retried briefly
because Sonos can sleep its endpoint during a handoff.

The current-playback response is also merged into the device list. This matters
for models that Spotify omits from `/me/player/devices`, or whose active device
id is null. A matching nearby receiver is recognized by name and type in that
case. Restricted devices remain visible with their current item. Controls stay
disabled unless the app has a supported local-control path such as Sonos.

Spotify changed development-mode endpoints and fields in 2026. This client uses
`/playlists/{id}/items`, `/me/library`, and search limits of 10. Some non-owned
playlist contents are no longer returned. Artist pages use artist-scoped catalog
search for the two ranked release/song columns because Spotify removed the
artist-top-tracks endpoint. Followed-playlist conversion fetches every available
page before creating a private copy, writes items in batches of 100, and removes
the original from the library only after all writes succeed.

## Local development

From a checkout on Omarchy 4:

```bash
./scripts/install-local.sh
```

The command validates the manifest, installs the user-level playback files,
links the checkout at
`~/.config/omarchy/plugins/aria`, and enables the bar widget. It
refuses to replace an existing plugin.

To install only the playback integration:

```bash
./scripts/setup.sh
```

Neither path enables or starts a unit at login. Pass
`--install-spotifyd` only if you also want the distro daemon installed as a
dormant fallback; playback always targets Soloist.

## Verification

```bash
./scripts/test.sh
```

The suite runs Omarchy manifest validation, Qt 6 QML lint, offline Qt tests with
mocked authentication responses, shell-script and Python tests (including the
artwork-cache helper), configuration checks, and a
forbidden-heavyweight-dependency scan. It ends with a network-dependent check
of the published backend release; on an offline machine only that final step
fails, everything before it is offline.

## Complete removal

Run the bundled uninstaller from outside the plugin directory:

```bash
cd "$HOME" && "$HOME/.config/omarchy/plugins/aria/scripts/uninstall.sh"
```

This removes the plugin and all plugin-owned services, binaries, config, state,
caches, sockets, backups, and keyring entries. See the README's
**Remove it completely** section for the equivalent commands and legacy
keybinding check. The `spotifyd` package remains installed because another
client may use it.

Aria installs only into its own tree (`~/.local/lib/aria`, `~/.config/aria`,
`$XDG_CACHE_HOME/aria`, `$XDG_STATE_HOME/aria`), and setup moves an older
Aria backend out of the shared `omarchy-spotify` folder it used historically —
but only when Aria's own install marker is present there, since the original
Omarchy Spotify plugin builds an identical backend from the same source and
identity checks alone cannot tell the two apart. Shared `omarchy-spotify`
locations are removed only on positive proof (Aria's marker) or explicit
consent: `--include-shared`, or a yes at the prompt the purge shows on a
terminal when shared files exist. Omarchy's plugin manager keeps a removed
plugin's data on disk and leaves no record, so a missing checkout proves
nothing; when shared files are kept, the purge prints how to remove them
deliberately.

Remove that package separately only when it was installed solely for this app:

```bash
omarchy pkg drop spotifyd
```

## Upstream projects

- [Omarchy](https://github.com/basecamp/omarchy)
- Soloist, the headless local receiver (see the README's Soloist section)
- [librespot](https://github.com/librespot-org/librespot), embedded by the session backend
- [Spotify Web API](https://developer.spotify.com/documentation/web-api)
- [lrclib.net](https://lrclib.net), the synced-lyrics provider
