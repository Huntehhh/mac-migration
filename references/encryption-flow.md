# Lane I Credentials — GPG Encryption Flow

**Audience:** The `mac-migration` skill (capture + restore + inventory preflight). Lane I is the credentials lane — SSH private keys, GPG keys, AWS access keys, cloud CLI tokens, npm tokens, cargo tokens, WireGuard private keys.
**Purpose:** Define how Lane I plaintext gets sealed into `credentials.tar.gz.gpg` before the bundle leaves the old Mac, and how it gets unsealed on the new Mac.

---

## Why encrypt

Lane I is the only lane where the bundle contents are catastrophic if intercepted. The transit channel between the two Macs is one of:

- **AirDrop** — encrypted in transit, but the receiving Mac stores the file in `~/Downloads/` plaintext.
- **USB stick** — file is whatever the filesystem says it is. Lost stick = lost credentials.
- **iCloud Drive** — Apple holds keys for non-Advanced-Data-Protection accounts. Subpoenable.
- **rsync over SSH between LANs** — depends on both endpoints being clean (the new Mac usually isn't yet).

The whole point of the bundle is "I can carry this in my pocket". That only works if Lane I is sealed with a key the user already trusts.

GPG with the user's own keypair is the cleanest fit:
- The key is already on the old Mac (Lane I captures it anyway).
- The key is portable to the new Mac via a separate, smaller export.
- It's airgap-friendly — no online key escrow service needed.
- The threat model matches: "anyone who finds my USB stick should not be able to read my credentials" → asymmetric encryption with a passphrase-protected private key is exactly that.

---

## The flow (capture side)

```
~/migration-bundle/
  credentials/                  <- plaintext (transient, never leaves the old Mac)
    aws-credentials
    aws-config
    gcloud/
    cloudflared/
    cloudflared-cert.pem
    doctl-config
    gh-hosts.yml
    gitconfig
    ssh-id_rsa
    ssh-id_ed25519
    ssh-config
    ssh-known_hosts
    gpg-secret.asc            <- redundant on purpose; see "GPG key chicken-and-egg" below
    gpg-trust.txt
    npmrc
    cargo-credentials.toml
    gem-credentials
    composer-auth.json
    pypirc
    huggingface-token
    netrc
    wireguard-tunnels/
```

The capture lane builds this directory plaintext, then immediately seals it:

```bash
# scripts/encrypt_creds.sh seal
cd ~/migration-bundle/

# Tar up the plaintext credentials dir into a single file.
tar czf credentials.tar.gz credentials/

# Encrypt to the user's default GPG key (or --recipient KEYID if supplied).
RECIPIENT="${MIGRATION_GPG_RECIPIENT:-$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/ {print $5; exit}')}"
if [ -z "$RECIPIENT" ]; then
    echo "ERROR: no GPG secret key found. Run preflight_check.sh first." >&2
    exit 2
fi

gpg --batch --yes --trust-model always --encrypt \
    --recipient "$RECIPIENT" \
    --output credentials.tar.gz.gpg \
    credentials.tar.gz

# Shred plaintext aggressively. Use `rm -P` on macOS (3-pass overwrite).
rm -P credentials.tar.gz
find credentials/ -type f -exec rm -P {} \;
rm -rf credentials/

echo "Sealed -> credentials.tar.gz.gpg ($(stat -f%z credentials.tar.gz.gpg) bytes)"
```

After seal, only `credentials.tar.gz.gpg` ships in the bundle. The plaintext directory is gone.

`rm -P` (capital P) is the macOS BSD `rm` flag for 3-pass overwrite before unlink — better than plain `rm` for credential paths. On APFS it doesn't actually overwrite physical blocks (APFS is copy-on-write) but it's the strongest atomic the platform offers without a full secure-erase pass on the volume.

---

## The flow (restore side)

```bash
# scripts/encrypt_creds.sh unseal
cd ~/migration-bundle/

if [ ! -f credentials.tar.gz.gpg ]; then
    echo "ERROR: credentials.tar.gz.gpg not found." >&2
    exit 2
fi

# Decrypt. GPG will prompt for the passphrase interactively.
gpg --decrypt --output credentials.tar.gz credentials.tar.gz.gpg

# Untar to a temp dir.
mkdir -p credentials/
tar xzf credentials.tar.gz -C .

# Restore lane consumes credentials/ from here. After lane finishes:
rm -P credentials.tar.gz
find credentials/ -type f -exec rm -P {} \;
rm -rf credentials/
```

The restore sub-skill calls `encrypt_creds.sh unseal` once at the start of Lane I, lets the Lane I steps consume the plaintext directory, then calls the cleanup tail.

---

## Recipient selection

By default the script uses the FIRST secret key in the user's GPG keyring:

```bash
gpg --list-secret-keys --with-colons | awk -F: '/^sec/ {print $5; exit}'
```

This is correct for the common case (single personal GPG key). For users with multiple keys (work key + personal key + a key for a specific project), they can override:

```bash
MIGRATION_GPG_RECIPIENT=AABBCCDD11223344 ./scripts/encrypt_creds.sh seal
# or
./scripts/encrypt_creds.sh seal --recipient AABBCCDD11223344
```

`KEYID` accepts long key ID, short key ID, fingerprint, or email — anything `gpg --recipient` understands.

---

## Pre-flight ties in

`inventory/preflight_check.sh` refuses to start a migration if the user has no GPG secret key. Otherwise the user would build a bundle they can't decrypt on the new Mac.

```bash
# inventory/preflight_check.sh excerpt
if ! gpg --list-secret-keys --with-colons | grep -q '^sec'; then
    cat <<EOF
ERROR: No GPG secret key found in this keyring.

Lane I (credentials) requires GPG to seal sensitive material before
the bundle can leave this Mac. You need at least one secret key.

Quick fix:
    gpg --full-generate-key
        Choose: (1) RSA and RSA, 4096 bits, 0 (does not expire),
                Real name + email, strong passphrase.

Or, if you have a YubiKey or smartcard:
    gpg --card-edit -> generate

Then re-run preflight.
EOF
    exit 2
fi
```

---

## GPG key chicken-and-egg — bring the key with you

The bundle includes the user's GPG secret key inside `credentials/gpg-secret.asc` (Lane I3). But that secret key is also what we encrypted the bundle WITH. If the user only has the bundle on the new Mac and nothing else, they can't decrypt the bundle to extract the key inside.

**Solution: the GPG private key travels separately from the bundle.** Document this as a pre-migration step the user does FIRST, before generating the bundle.

### Pre-migration step (on the old Mac, before running capture):

```bash
# Export the secret key (armored, copy-pastable).
gpg --export-secret-keys --armor > ~/migration-key.asc

# Verify the export.
gpg --list-packets ~/migration-key.asc | head

# Move it to one of these channels (pick whichever the user trusts most):
#   (a) USB stick that is NOT the same one carrying the bundle.
#   (b) Password manager attachment field (1Password, Bitwarden secure note).
#   (c) Print to paper and physically carry.
#   (d) iCloud Drive in a folder protected by Advanced Data Protection.
#
# Do NOT email it to yourself. Do NOT drop it in the migration-bundle dir.
```

### On the new Mac, before running restore:

```bash
# 1. Install GPG.
brew install gnupg

# 2. Import the secret key.
gpg --import ~/Downloads/migration-key.asc
# (GPG prompts for the passphrase to unlock it.)

# 3. Set ultimate trust on the imported key.
gpg --edit-key <KEYID>
> trust
> 5
> y
> quit

# 4. Verify.
gpg --list-secret-keys

# 5. Now run restore on the bundle.
~/migration-bundle/scripts/restore.sh
```

Once the secret key is imported, `encrypt_creds.sh unseal` will decrypt the bundle's Lane I.

---

## Worked example

```bash
# OLD MAC — capture
$ cd ~/migration-bundle/
$ ./scripts/encrypt_creds.sh seal
Sealed -> credentials.tar.gz.gpg (47384 bytes)

$ ls -la credentials*
-rw-------  1 hunter staff  47384 May 22 14:23 credentials.tar.gz.gpg

$ ls credentials/
ls: credentials/: No such file or directory   # good — shredded

# Bundle is now safe to AirDrop / USB / iCloud.

# NEW MAC — restore
$ cd ~/migration-bundle/
$ ./scripts/encrypt_creds.sh unseal
gpg: encrypted with 4096-bit RSA key, ID AABBCCDD11223344, created 2024-03-15
      "Hunter Casillas <hunter@example.com>"
Enter passphrase: ********
File 'credentials.tar.gz' exists. Overwrite? (y/N) y

$ ls credentials/
aws-credentials  cloudflared/   gitconfig       npmrc    ssh-config
aws-config       cloudflared-cert.pem  gh-hosts.yml  ssh-id_ed25519  wireguard-tunnels/
...

# Restore lane consumes these, then re-shreds.
```

---

## Edge cases

### Subkey-only setups

Users who follow the "primary key on offline storage, subkeys on the daily-driver Mac" pattern have a subkey for encryption but no primary secret material in the keyring. GPG handles this transparently — `gpg --encrypt --recipient <fpr>` uses the encryption subkey automatically. No special handling needed in the migration scripts.

### Smartcard-backed keys (YubiKey, Nitrokey, OpenPGP card)

If the secret key lives on a hardware token, the user needs:
1. The token physically present on both Macs at the right times.
2. The token's PIN.
3. The public key + stub secret key file imported on the new Mac (`gpg --card-status` populates this).

Seal works as long as the token is plugged in. Unseal works as long as the token is plugged in. Otherwise GPG returns `decryption failed: No secret key`.

### Forgotten passphrase

Unrecoverable. GPG passphrases are not retrievable; the cryptography is the whole point. The user has to:

1. Generate a new GPG key on the old Mac.
2. Re-run `encrypt_creds.sh seal` with `--recipient <new-keyid>`.
3. Ship the new key + new bundle to the new Mac.

This is why the preflight insists on validating the user can decrypt their own test seal before letting the migration proceed.

### Validating the seal before shipping

The skill optionally runs a round-trip test:

```bash
# scripts/encrypt_creds.sh test
echo "test-payload-$(date +%s)" > /tmp/migration-test
gpg --encrypt --recipient "$RECIPIENT" --output /tmp/migration-test.gpg /tmp/migration-test
gpg --decrypt --output /tmp/migration-test-decrypted /tmp/migration-test.gpg
diff -q /tmp/migration-test /tmp/migration-test-decrypted && echo "OK: GPG round-trip works."
rm -P /tmp/migration-test /tmp/migration-test.gpg /tmp/migration-test-decrypted
```

Run this before the real seal. Catches "I can't remember my passphrase" 5 minutes after you wrote it into the keyring.

---

## References

- [GnuPG documentation — Encrypting and decrypting](https://www.gnupg.org/gph/en/manual/x110.html)
- [Apple — `rm` manpage](https://ss64.com/mac/rm.html) — the `-P` flag and its limitations on APFS
- [Yubico — GPG with YubiKey on macOS](https://developers.yubico.com/PGP/SSH_authentication/macOS.html)
- [Drew DeVault — A practical introduction to GPG](https://drewdevault.com/2016/04/26/gpg-and-me.html) — subkey workflow context
