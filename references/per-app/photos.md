# Per-App Playbook — Photos.app

**Lane:** D3 (sandboxed app data)
**Risk level:** High (one wrong rsync = silently corrupted library)
**Recovery difficulty:** Hard — Photos schema migration is opaque

---

## Overview

Photos.app stores its library as a `.photoslibrary` package (looks like a folder, behaves as a single document). The package contains:

- `database/` — multiple SQLite files holding metadata, albums, faces, keywords, edits
- `originals/` — original imported files (DNG, HEIC, JPG, MOV)
- `resources/` — derived thumbnails, cached renders, sidecar metadata
- `Photos.sqlite` and friends — the master DB, evolves across macOS versions

Apple changes the schema across macOS major versions and migrates it on first open. A library opened on macOS 26 Tahoe is not byte-compatible with macOS 15 Sequoia — the migration is one-way.

**Two valid migration paths:**

1. **iCloud Photos enabled on both Macs** — sign in, wait for sync. Easiest and safest. Handles arbitrarily large libraries (years of photos sync down progressively).
2. **Local-only library** — copy the `.photoslibrary` package, then open with **Option + Shift held** to trigger "Choose Library" → point at the new location → Photos rebuilds metadata indices and migrates schema if needed.

**The hard "no":** Do NOT raw rsync a live `.photoslibrary` package and expect Photos to open it cleanly. Race conditions in the SQLite WAL files cause corruption that Photos will detect but not always recover from gracefully.

---

## Detect installed state

```bash
# Is the user using Photos.app at all?
ls -la ~/Pictures/*.photoslibrary 2>/dev/null

# How big is the library?
du -sh ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null

# Is iCloud Photos enabled?
# (No clean CLI check — read the prefs:)
defaults read com.apple.Photos | grep -i icloud

# Is the library the "System Photo Library" (used by Photos extensions, Wallpaper, Screensaver)?
defaults read com.apple.Photos SystemPhotoLibraryURL 2>/dev/null
```

---

## Capture — iCloud Photos enabled flow

```bash
# If iCloud Photos is on, the library is a local cache of cloud state.
# The capture writes a sanity reference and instructs the new Mac to sign in
# and wait for sync.

mkdir -p ~/migration-bundle/photos/
cat > ~/migration-bundle/photos/MIGRATION-METHOD.txt <<'EOF'
Photos.app: iCloud Photos sync mode.

On the new Mac:
  1. Sign in to iCloud with the same Apple ID.
  2. System Settings -> [Apple ID] -> iCloud -> Photos -> Enable.
  3. Wait for sync. Initial sync of large libraries can take 6-48 hours depending
     on photo count and network speed.
  4. Choose download mode in Photos -> Settings -> iCloud:
       "Download Originals to this Mac"  (full local copy)
       "Optimize Mac Storage"            (cloud-managed, downloads as accessed)

The local library at ~/Pictures/Photos Library.photoslibrary will rebuild as
sync progresses. No file copy from old Mac to new Mac is required.
EOF

# Optionally capture: library size + photo count, for diff verification later.
osascript -e 'tell application "Photos" to count of media items' \
    > ~/migration-bundle/photos/photo-count.txt 2>/dev/null
du -sh ~/Pictures/Photos\ Library.photoslibrary \
    >> ~/migration-bundle/photos/photo-count.txt
```

## Capture — local-only library flow

```bash
# The library is local-only (no iCloud Photos). We have two sub-options:

# Option A (preferred): use Migration Assistant for the library bundle ONLY.
#   This is the ONE case where Migration Assistant is the right tool — Apple's
#   internal migration code handles the schema upgrade across macOS versions.
#   Surface this to the user:

cat > ~/migration-bundle/photos/MIGRATION-METHOD.txt <<'EOF'
Photos.app: local-only library, large enough to warrant Migration Assistant.

The Photos library is the ONE thing Migration Assistant is uniquely good at:
its schema upgrades between macOS versions are non-trivial and Apple's MA
includes the right transformation code.

To migrate JUST the Photos library via MA:
  1. Use Migration Assistant in selective mode (NOT a full migration).
  2. On the source Mac selection screen, expand "Documents and Data".
  3. Uncheck everything EXCEPT "Pictures".
  4. Run the migration. ~/Pictures/Photos Library.photoslibrary will be copied
     and the schema will be migrated to match the new Mac's macOS version.

Alternative: AirDrop the .photoslibrary package, then on the new Mac open
Photos with Option+Shift held to trigger "Choose Library" -> select the copied
location. Photos rebuilds indices on first open (slow but works).

DO NOT raw rsync the .photoslibrary while Photos is running on the old Mac.
EOF

# Option B: rsync the package (only if Photos is quit and we accept the risk).
# We don't recommend this for the default flow. Surface as an explicit choice.

# If the user explicitly opts in to rsync flow, ensure Photos is quit:
if pgrep -x Photos >/dev/null; then
    osascript -e 'quit app "Photos"'
    sleep 5
fi

# Then rsync. Trailing slash matters.
rsync -av --info=progress2 \
    ~/Pictures/Photos\ Library.photoslibrary/ \
    ~/migration-bundle/photos/Photos-Library.photoslibrary/
```

## Capture — exports flow (granular but lossless)

If the user wants individual files (e.g., to back up to a non-Apple system, or to consolidate from multiple libraries):

```bash
# Photos has a built-in export — but it's GUI-only. Surface instructions:

cat > ~/migration-bundle/photos/EXPORT-INSTRUCTIONS.txt <<'EOF'
Photos.app: export originals as files.

In Photos:
  1. Select all photos (Edit -> Select All).
  2. File -> Export -> Export Originals... (NOT "Export N Photos..." which
     creates derivatives).
  3. Pick a destination folder. Photos writes originals as individual files,
     preserving metadata via XMP sidecars where applicable.

This loses: albums, faces, keywords, edits.
This preserves: original pixel data, EXIF, GPS, capture date.

Useful for archival to non-Apple systems. Not the right tool for migrating
TO another Mac running Photos.app.
EOF
```

---

## Restore — iCloud Photos enabled flow

```bash
# 1. Sign in to iCloud on the new Mac.
#    System Settings -> [Apple ID] -> Sign In

# 2. Enable Photos sync.
#    System Settings -> [Apple ID] -> iCloud -> Photos -> ON

# 3. Open Photos.app once to trigger initial sync setup.
open /Applications/Photos.app

# 4. (Inside Photos) Photos -> Settings -> iCloud:
#    - Choose download mode (Originals or Optimize)

# 5. Wait. Initial sync of a 200k+ photo library takes 12-48 hours.
#    Subsequent additions sync in seconds-to-minutes.
```

## Restore — local-only library flow

```bash
# Option A: Migration Assistant did the work — library is already in
# ~/Pictures/Photos Library.photoslibrary on the new Mac.

# Just open it:
open ~/Pictures/Photos\ Library.photoslibrary

# Photos detects the older-schema library and asks to upgrade. Click Upgrade.
# This can take 10-60 minutes for large libraries.

# Option B: copied via AirDrop / rsync from the bundle.

# 1. Move the package to the right location.
mv ~/migration-bundle/photos/Photos-Library.photoslibrary \
   ~/Pictures/Photos\ Library.photoslibrary

# 2. Hold Option + Shift while launching Photos to trigger "Choose Library".
#    (You can't simulate this via CLI; surface as a user instruction.)
open /Applications/Photos.app

# 3. In the library chooser, select the copied bundle.
# 4. Photos rebuilds indices. Wait for completion.

# 5. (Optional) Set as System Photo Library:
#    Photos -> Settings -> General -> Use as System Photo Library
```

---

## Gotchas

- **Schema migration is one-way.** Once Photos opens a library on a newer macOS, the library cannot be opened on the old macOS. If the user wants to keep using the old Mac while testing the new one, work on a copy.

- **Migration Assistant IS the right tool for this ONE case.** General advice in this skill is "skip Migration Assistant", but for `.photoslibrary` the MA schema-upgrade code is what makes the migration work. Run MA in selective mode, picking ONLY the Photos library, and you get Apple's tested upgrade path without inheriting the broken Brewfile/Docker/launchd state that MA otherwise causes.

- **Finder rsync of the bundle DOES NOT WORK reliably.** macOS treats `.photoslibrary` as a package with extended attributes and resource forks. `rsync` without `-E` (extended attributes), `-X` (xattrs), `-A` (ACLs) may silently drop the very metadata Photos uses to identify the library. Even WITH all those flags, race conditions during a live copy produce SQLite corruption.

- **"Optimize Mac Storage" mode leaves only thumbnails locally.** If the user has 500GB of cloud photos and 8GB of local thumbnails, the library size on disk is misleading. Don't size the bundle based on `du -sh` of the package alone — it tells you what's local, not what's in the cloud.

- **Faces, places, memories, smart albums.** These regenerate automatically after a successful migration. They're not in the bundle — Photos's ML re-analyzes the library on import.

- **Shared libraries (iCloud Shared Photo Library).** If the user is part of a Shared Library, that shared content is separate from their personal library and syncs independently. The new Mac picks up shared libraries automatically once signed in.

- **System Photo Library setting.** Multiple `.photoslibrary` files can exist on disk, but only one is the "System Photo Library" (used by Wallpaper, Screensaver, Photos extensions). Set it via Photos -> Settings -> General -> "Use as System Photo Library".

---

## Recovery

If the library won't open or shows errors:

```bash
# Quit Photos fully.
osascript -e 'quit app "Photos"' 2>/dev/null
killall Photos 2>/dev/null
sleep 5

# Hold Option + Command while launching Photos to trigger "Repair Library".
# (CLI-equivalent: not available. Must use keyboard shortcut.)
open /Applications/Photos.app

# In the dialog: "Photos found an issue with this library. Repair Library?"
# Click Repair. This rebuilds the SQLite indices from the originals/ data.
# Takes 10-90 minutes for large libraries.

# If repair fails, restore from Time Machine backup of ~/Pictures or rebuild
# from iCloud (if iCloud Photos was enabled).
```

---

## Verify

```bash
# Quick verify after migration:
osascript -e 'tell application "Photos" to count of media items'
# Compare against ~/migration-bundle/photos/photo-count.txt

# Open Photos and check:
#   - Recent photos visible
#   - Albums populated
#   - Faces / People reconstructed (may take hours on large libraries)
#   - Memories generated
#   - Smart albums (e.g., "Last Import") refreshed
```

---

## Sources

- [Apple Support — Move your Photos library to a new Mac](https://support.apple.com/guide/photos/move-your-photo-library-pht8128afc31/mac)
- [Apple Support — Use multiple libraries in Photos](https://support.apple.com/guide/photos/use-multiple-libraries-pht3a86c2d70/mac)
- [Apple Support — iCloud Photos](https://support.apple.com/guide/photos/turn-on-icloud-photos-pht9b9c4e5cf/mac)
- [Howard Oakley — How Photos manages photos](https://eclecticlight.co/2024/04/08/how-photos-manages-photos-and-its-library/) — independent reference on the `.photoslibrary` internals
- Empirical: Apple's own forum threads on `.photoslibrary` corruption from Migration Assistant edge cases
