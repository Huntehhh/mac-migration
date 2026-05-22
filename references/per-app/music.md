# Per-App Playbook — Music.app (Apple Music)

**Lane:** D3 (sandboxed app data) + selective D2
**Risk level:** Medium (iCloud-managed for most users; local-only is the hard case)
**Recovery difficulty:** Medium — XML export is the safety net

---

## Overview

Music.app (the renamed iTunes, post-Catalina) stores its state in:

- `~/Music/Music/Music Library.musiclibrary` — package containing a SQLite DB (`Library.musicdb`), extras (`Extras.itdb`), genius (`Genius.itdb`), playlists, ratings, play counts
- `~/Music/Music/Media.localized/` — actual audio files (purchased downloads, ripped CDs, local files added via "File -> Add to Library")
- `~/Music/Music/Album Artwork/` — cached cover art

iCloud Music Library (if enabled) syncs:
- Apple Music subscription content (streaming-only or downloaded)
- iTunes Match content (the user's own files, matched or uploaded)
- Playlists and ratings
- Cross-device play counts (debatably; Apple's been inconsistent here)

iCloud Music Library does NOT sync:
- Local audio files that aren't part of Apple Music or iTunes Match
- Play history beyond ~30 days for non-subscribers
- Smart playlist rules (rules sync; the results recompute per-device)

The migration split:
- **Streaming-only users** — sign in, enable iCloud Music Library, done.
- **Local files + iTunes Match** — sign in + wait for sync, plus copy `Media.localized/` for any unmatched-but-uploaded content.
- **Local-only library (no iCloud Music)** — copy both the `.musiclibrary` package AND the `Media.localized/` directory to identical paths.

---

## Detect installed state

```bash
# Library exists?
ls -d ~/Music/Music/Music\ Library.musiclibrary 2>/dev/null

# Size of media (the data we may need to carry).
du -sh ~/Music/Music/Media.localized/ 2>/dev/null

# Apple ID signed in to Music?
defaults read com.apple.Music 2>/dev/null | grep -i 'subscribed\|cloudLibrary\|iTunesMatch'

# Is iCloud Music Library on?
# (Hard to read cleanly via defaults — surface as a question to the user instead:)
osascript -e 'tell application "Music" to get cloud status' 2>/dev/null
```

---

## Capture — iCloud Music Library + Apple Music subscriber flow

```bash
mkdir -p ~/migration-bundle/music/
cat > ~/migration-bundle/music/MIGRATION-METHOD.txt <<'EOF'
Music.app: iCloud Music Library + Apple Music subscriber.

On the new Mac:
  1. Sign in with the same Apple ID.
  2. Music.app -> Settings -> General -> "Sync Library" -> ON
  3. Wait for the library to sync. Initial sync of large libraries takes
     1-12 hours depending on track count.

The local library at ~/Music/Music/Music Library.musiclibrary rebuilds from
cloud state. No file copy required UNLESS the user has local-only files
(see Media.localized/ section).
EOF

# Optionally export an XML reference (Music -> File -> Library -> Export Library...).
# This is GUI-only — surface as a manual step:
cat >> ~/migration-bundle/music/MIGRATION-METHOD.txt <<'EOF'

SAFETY NET (recommended before migration):
  Music.app -> File -> Library -> Export Library...
  Save the resulting Library.xml in this migration bundle.
  This is a portable, human-readable backup of playlists + metadata.
  Useful for verification or recovery if iCloud sync misbehaves.
EOF
```

## Capture — local-only library flow (or hybrid)

```bash
# Quit Music BEFORE copying. The SQLite DB has WAL files that corrupt on
# a live copy.
if pgrep -x Music >/dev/null; then
    osascript -e 'quit app "Music"'
    sleep 5
fi

# Copy the library package.
rsync -av --info=progress2 \
    ~/Music/Music/Music\ Library.musiclibrary/ \
    ~/migration-bundle/music/Music-Library.musiclibrary/

# Copy the media files. This is usually the big one.
rsync -av --info=progress2 \
    ~/Music/Music/Media.localized/ \
    ~/migration-bundle/music/Media.localized/

# Export the XML reference as a portable backup.
# (This is GUI-only; instruct the user to do it before quitting Music.)
```

---

## Restore — iCloud Music Library flow

```bash
# 1. Sign in to iCloud on the new Mac with the same Apple ID.
#    System Settings -> [Apple ID] -> Sign In

# 2. Launch Music.app once to trigger setup.
open /Applications/Music.app

# 3. Inside Music: Settings -> General -> "Sync Library" -> ON.
#    User accepts the prompt to use iCloud Music Library.

# 4. Wait for sync. A 50,000 song library takes 4-8 hours.

# 5. If subscribed to Apple Music:
#    Settings -> General -> Auto-Download for Music: choose ON if the user
#    wants downloaded copies for offline (otherwise streaming-only).
```

## Restore — local-only library flow

```bash
# 1. Quit Music if running.
osascript -e 'quit app "Music"' 2>/dev/null
sleep 3

# 2. Restore the library package and media to identical paths.
mkdir -p ~/Music/Music/
rsync -av ~/migration-bundle/music/Music-Library.musiclibrary/ \
    ~/Music/Music/Music\ Library.musiclibrary/
rsync -av ~/migration-bundle/music/Media.localized/ \
    ~/Music/Music/Media.localized/

# 3. Launch Music with Option held to trigger "Choose Library".
#    (CLI-equivalent: not available. Manual user step.)
#    In the dialog, select ~/Music/Music/Music Library.musiclibrary.
open /Applications/Music.app

# 4. Music opens. Play counts, smart playlists, ratings are intact.
#    Smart playlists recompute their members from the rules; if the rules
#    referenced specific files that aren't present, smart playlists are empty.
```

---

## Gotchas

- **Quit Music BEFORE copying the library.** SQLite WAL files corrupt on live copies. If Music is running, the `.musiclibrary` package's `Library.musicdb-wal` and `Library.musicdb-shm` are open and the copy will be inconsistent.

- **Smart playlists rebuild from rules, not from raw data.** If a smart playlist rule is "Genre is Jazz AND Rating >= 4", the new Mac recomputes membership by re-evaluating the rule against the restored library. As long as the rule is preserved in the `.musiclibrary` (it is), this works automatically. If the user wants to FREEZE the current contents (rare), they need to convert smart playlists to regular playlists BEFORE migration: right-click playlist -> Copy to New Playlist.

- **Play counts.** Sync via iCloud Music Library (mostly). Local-only library preserves play counts in the `.musiclibrary`. If the user wants to be SURE, export Library.xml as a frozen reference before migration.

- **Identical paths matter.** The library DB stores absolute paths to media files. If `Media.localized/` lives at `~/Music/Music/Media.localized/` on the old Mac and at `~/Music/Media/` on the new Mac, every track shows as "missing" with a `!` icon. Stick to the default Apple path on both Macs.

- **"Keep Music Media folder organized" setting.** If enabled (the default), Music auto-renames files into `Artist/Album/01 Track.m4a` structure. After migration, this should already be the case. If disabled and the user has hand-organized files, preserve their structure exactly.

- **Apple Music subscription state.** This is account-level — signing in re-activates the subscription. No local state to migrate.

- **iTunes Match (deprecated but still functional for legacy users).** Same as Apple Music — account-level. Sync resumes on sign-in.

- **"Allow downloads of past purchases".** Settings -> Store -> Music -> ON. This lets the user re-download purchased music without re-buying. Useful as a recovery path if local files are lost.

- **Loss-of-WAV-and-ALAC-metadata.** Music.app uses a sidecar metadata system for lossless formats. The metadata lives in the `.musiclibrary` DB, NOT in the audio file. If the user later moves files out of the library system, the metadata stays behind. Capturing both library and media preserves this.

- **The "Music" vs "iTunes" naming confusion.** Pre-Catalina (macOS 10.15) the app was iTunes; its library was `~/Music/iTunes/iTunes Library.itl`. Post-Catalina, Music.app picks up that old library on first launch and converts it to `~/Music/Music/Music Library.musiclibrary`. If the user is migrating from a pre-Catalina Mac, surface this — the library path differs.

---

## Recovery

```bash
# Symptom: tracks show with "!" icon (missing files).
# Cause:   media path mismatch between Library DB and actual file location.
# Fix:     point Music at the right location.

# In Music: Settings -> Files -> Music Media folder location -> Change...
# Select the actual folder where Media.localized/ lives.
# Music updates internal paths; tracks resolve.

# If the library itself is corrupt:
osascript -e 'quit app "Music"' 2>/dev/null
sleep 3

# Hold Option while opening to trigger library chooser:
# Music -> File -> Library -> New... (then re-import)
# OR
# Use the XML export (if captured) -> File -> Library -> Import Playlist... -> select Library.xml
# This regenerates the library from the XML reference, preserving playlists + ratings.

open /Applications/Music.app
```

---

## Verify

```bash
# Smoke test:
osascript -e 'tell application "Music" to count of tracks'
# Compare against expected count

# Check for missing files (those with "!" icon):
osascript -e 'tell application "Music" to count of (every track whose location is missing value)'
# Should be 0 (or close to it)

# Spot-check playlists are intact:
osascript -e 'tell application "Music" to get name of every user playlist'

# Confirm smart playlists are populated:
osascript -e 'tell application "Music" to count of tracks of (first playlist whose smart is true)'
```

---

## Sources

- [Apple Support — Move your Music library to a new Mac](https://support.apple.com/guide/music/move-your-music-library-mus30c61eaf2/mac)
- [Apple Support — How Music app handles your music files](https://support.apple.com/guide/music/where-music-files-stored-mus30acbd1c2/mac)
- [Apple Support — iCloud Music Library and Sync Library](https://support.apple.com/HT204146)
- [Howard Oakley — How Music stores your library](https://eclecticlight.co/2020/02/24/last-week-on-my-mac-tracking-down-itunes-app-bundle-issues/) — independent reference on Catalina+ library structure
