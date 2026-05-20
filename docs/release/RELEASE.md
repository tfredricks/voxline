# Releasing voxline

## One-time setup (do this before the first release)

These steps create the trust roots and infrastructure the release pipeline depends on. They are external to the repo — the project owner runs them once, on their own machine and on GitHub.

### 1. Install Sparkle's CLI tools

Download Sparkle 2.6.x or later from `https://github.com/sparkle-project/Sparkle/releases` and extract `bin/generate_keys` and `bin/sign_update`. Place them somewhere on PATH (e.g. `/usr/local/bin`) or keep them in a known directory like `~/voxline-sparkle-tools/`.

### 2. Generate the EdDSA keypair

```bash
~/voxline-sparkle-tools/generate_keys
```

This emits the base64 public key on stdout and stores the private key in your login keychain under `https://sparkle-project.org`. Copy the public key string verbatim.

### 3. Export the private key for storage in GitHub Actions secrets

```bash
~/voxline-sparkle-tools/generate_keys -x sparkle_ed_private.pem
```

Keep this file out of git. Store a backup somewhere durable (a password manager or hardware token works). Losing this key means rotating to a new keypair, which forces every existing user to re-download manually — see "Key rotation" below.

### 4. Replace the placeholder `SUPublicEDKey` in `voxline/Info.plist`

Edit `voxline/Info.plist` and replace:
```xml
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_REAL_KEY_IN_TASK_8</string>
```
with the base64 public key from step 2. Then validate:

```bash
plutil -lint voxline/Info.plist
```

Commit the change on `main`.

### 5. Provision GitHub Actions secrets

At `https://github.com/tfredricks/voxline/settings/secrets/actions`, add:

| Secret name | Value |
|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | Contents of `sparkle_ed_private.pem` from step 3 |
| `APPLE_NOTARY_KEY_ID` | Your App Store Connect API Key ID (e.g. `ABCDEF1234`) |
| `APPLE_NOTARY_ISSUER_ID` | Your App Store Connect issuer UUID |
| `APPLE_NOTARY_API_KEY_P8` | Contents of the `AuthKey_XXX.p8` file from App Store Connect |
| `DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` of your Developer ID Application cert: `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | Password used when exporting the `.p12` |

### 6. Create the `gh-pages` branch with an initial empty appcast

```bash
git checkout --orphan gh-pages
git rm -rf .
cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>voxline</title>
    <link>https://tfredricks.github.io/voxline/appcast.xml</link>
    <description>voxline release feed</description>
    <language>en</language>
  </channel>
</rss>
EOF
git add appcast.xml
git commit -m "chore(pages): seed empty appcast"
git push origin gh-pages
git checkout main
```

In `Settings → Pages` on the GitHub repo, set:
- Source: `Deploy from a branch`
- Branch: `gh-pages`, folder: `/ (root)`

Wait ~1 minute, then verify in browser:
`https://tfredricks.github.io/voxline/appcast.xml`

Expected: the empty-channel XML above.

## Per release

1. Bump `MARKETING_VERSION` in `voxline.xcodeproj/project.pbxproj` (Build Settings → Versioning) to the new version, e.g. `1.0.1`. Commit on `main`.
2. Tag the commit with a `v`-prefixed annotated tag whose message is the release notes:
   ```bash
   git tag -a v1.0.1 -m "$(cat <<'EOF'
   ## What's new in 1.0.1

   - ...
   EOF
   )"
   git push origin v1.0.1
   ```
3. GitHub Actions `release.yml` runs automatically:
   - builds the Release config, signs with Developer ID
   - notarizes via `notarytool` and staples
   - packages a DMG, EdDSA-signs it with `sign_update`
   - regenerates `appcast.xml` against the new DMG + tag-annotation notes
   - uploads the DMG to the GitHub Release for the tag
   - commits the updated `appcast.xml` to `gh-pages`
4. Watch the Action run. On success, verify:
   - `https://tfredricks.github.io/voxline/appcast.xml` contains a new `<item>` with the new version.
   - The DMG is attached to the GitHub Release for `v1.0.1`.
5. Run the manual test pass from `docs/release/MANUAL_TESTS.md`.

## Key rotation (only if EdDSA private key is lost or compromised)

This breaks updates for all currently-deployed users — they will reject feed entries signed with the new key. They must download the new version manually from the GitHub Release page. Plan accordingly.

1. Generate a new keypair: `generate_keys` (overwrites the keychain item).
2. Replace `SUPublicEDKey` in `voxline/Info.plist`.
3. Update the `SPARKLE_ED_PRIVATE_KEY` GitHub secret.
4. Cut a new release announcing the rotation in the notes.
