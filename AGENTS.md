# AGENTS.md

This is a Clan-managed NixOS homelab. Machines are defined under `machines/`,
shared services under `modules/`, and secrets are managed by Clan vars backed by
SOPS/age.

Useful commands:

```bash
nix develop --command clan machines list
nix develop --command clan machines build
nix develop --command clan vars check
```

The PR build workflow (`.forgejo/workflows/build-machines.yml`) runs
`clan vars check` before building. If a generator is new or its invalidation
hash changed, the PR fails until the generated files under `vars/` are committed.

## Generating clan vars without the admin private key

You normally generate secrets with the admin private key:

```bash
nix develop --command clan vars generate elserver
```

For a generator that has **no secret inputs**, you do not need the private key.
Clan only needs the admin public key to identify which `sops/users/<user>` entry
to encrypt for; encryption itself only needs recipients' public keys.

1. Find your admin public key:

   ```bash
   jq -r .publickey sops/users/lucas/key.json
   ```

   It must match an entry in `sops/users/<user>/key.json`, otherwise Clan cannot
   determine which user you are.

2. Put only that public key in an age key file, and point Clan at it:

   ```bash
   export SOPS_AGE_KEY_FILE="$PWD/age-public-key.txt"
   printf '%s\n' 'age1...' > "$SOPS_AGE_KEY_FILE"
   ```

   Do not commit `age-public-key.txt`. You can also place the public key at the
   default location (`~/.config/sops/age/keys.txt`) or use `SOPS_AGE_KEY`.

3. Generate the missing vars:

   ```bash
   nix develop --command clan vars generate elserver
   # or a single generator:
   nix develop --command clan vars generate elserver \
     --generator dawarich-admin-password
   ```

   `clan vars generate` commits the generated files automatically.

4. Verify and push:

   ```bash
   nix develop --command clan vars check
   git log --oneline -3
   git status
   git push
   ```

   The new secret directories contain `secret` plus `machines/` and `users/`
   symlinks; commit all of them.

### Why this works

- `clan vars check` and `clan vars generate` read age files through
  `get_public_age_keys()`, which accepts both real identities
  (`AGE-SECRET-KEY-...`) and plain `age1...` recipients.
- For an input-free generator, Clan runs the generator script and encrypts the
  output to the admin and machine public keys. Nothing is decrypted.
- The resulting secret is decryptable by the admin private key later, even
  though that key was never present during generation.

### When the private key is still required

- The generator consumes another secret var (Clan must decrypt that input).
- Re-encrypting existing secrets, e.g. `clan vars fix`, `clan secrets key update`,
  or adding new recipients.
- Reading a value with `clan vars get`.
- Deploying: the deploy workflow uses `CLAN_SOPS_AGE_KEY` to decrypt and upload
  secrets.

Example: after deploying Dawarich, read its generated admin password with the
private key present:

```bash
nix develop --command clan vars get elserver dawarich-admin-password/password
```
