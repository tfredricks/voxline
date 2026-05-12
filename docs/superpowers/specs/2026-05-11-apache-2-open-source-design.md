# Apache 2.0 Open-Source Setup — Design

**Date:** 2026-05-11
**Status:** Approved (pending user spec review)
**Scope:** Add the legal, governance, and community-facing files needed for voxline to be a properly open-source Apache 2.0 project.

## Goal

Make voxline an Apache 2.0 open-source project that:

- Has a real license (currently `License TBD`).
- Carries the required Apache 2.0 attribution machinery (`NOTICE`, third-party attributions).
- Reserves the "voxline" name and logo from the permissive grant.
- Gives outside contributors a clear path: how to build, how to submit changes, and how to legally certify their contributions (DCO).
- Avoids ceremony that doesn't yet earn its keep (no CoC, no SECURITY policy, no CLA bot, no per-file source headers, no CI workflow).

## Decisions (locked)

These were settled during brainstorming:

| Decision | Choice |
|---|---|
| License | Apache License, Version 2.0 |
| Copyright holder | Todd Fredricks (personally) |
| Contributor model | DCO (Developer Certificate of Origin), via `git commit -s` |
| Source-file headers | None — Apache 2.0 only requires LICENSE/NOTICE in the distribution |
| Code of Conduct | Skipped for now |
| Security policy | Skipped for now |
| CLA | Not used |
| CI workflow | Not added |
| Trademark | "voxline" name and `logo.png` reserved; forks must rename |
| Distribution | Source-only (existing state); no release automation in this scope |
| Delivery shape | Single bundled commit on `main` |

## File Inventory

### New files (7)

| Path | Purpose |
|---|---|
| `LICENSE` | Verbatim Apache License 2.0 text. |
| `NOTICE` | Apache §4(d) NOTICE file. Carries the project copyright line and a pointer to `THIRD-PARTY-NOTICES.md`. |
| `THIRD-PARTY-NOTICES.md` | One section per direct dependency: name, source URL, license name, copyright line. Manually maintained on dependency bumps. |
| `TRADEMARK.md` | Reserves the "voxline" name and `logo.png` from the Apache grant. |
| `CONTRIBUTING.md` | Build / test / PR instructions, including DCO sign-off requirement. |
| `.github/CODEOWNERS` | Single line: `* @tfredricks` so PRs auto-request the owner's review. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Summary / Test plan / DCO-sign-off checklist. |

### Modified files (1)

| Path | Change |
|---|---|
| `README.md` | Replace the existing "License" section ("License TBD…") with a real license/NOTICE/trademark block. Add a one-line **Contributing** section above License pointing at `CONTRIBUTING.md` and noting DCO sign-off is required. |

### Explicitly out of scope

- No SPDX or Apache header in any `.swift` file.
- No `CODE_OF_CONDUCT.md`.
- No `SECURITY.md`.
- No `.github/workflows/` (no CI).
- No release / notarization / Homebrew automation.
- No changes to `.github/ISSUE_TEMPLATE/{bug,feedback}.yml`.
- No CLA bot wiring.

## File Contents

### `LICENSE`

Verbatim Apache License, Version 2.0, fetched from the canonical source:
`https://www.apache.org/licenses/LICENSE-2.0.txt`

No customization — that is the entire point of using a standard license.

### `NOTICE`

```
voxline
Copyright 2026 Todd Fredricks

This product includes third-party software. See THIRD-PARTY-NOTICES.md
for component attributions and license terms.
```

This is the minimal NOTICE: project name + copyright line + pointer. Adequate per Apache 2.0 §4(d). Rationale for keeping it minimal: NOTICE is propagated into derivative works verbatim, so brevity reduces noise downstream.

### `THIRD-PARTY-NOTICES.md`

One block per direct dependency from
`voxline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
plus the underlying Whisper model. Format per entry:

```
## <Name>
- Source: <upstream URL>
- License: <SPDX identifier>
- Copyright: <copyright line as it appears in upstream LICENSE>
```

**Entries to include (8 SPM deps + 1 model):**

1. WhisperKit — https://github.com/argmaxinc/WhisperKit — MIT
2. swift-transformers — https://github.com/huggingface/swift-transformers — Apache-2.0
3. swift-jinja — https://github.com/huggingface/swift-jinja — Apache-2.0
4. swift-argument-parser — https://github.com/apple/swift-argument-parser — Apache-2.0
5. swift-asn1 — https://github.com/apple/swift-asn1 — Apache-2.0
6. swift-collections — https://github.com/apple/swift-collections — Apache-2.0
7. swift-crypto — https://github.com/apple/swift-crypto — Apache-2.0
8. yyjson — https://github.com/ibireme/yyjson — MIT
9. Whisper (model) — https://github.com/openai/whisper — MIT

**Implementation note:** before writing this file, fetch each upstream `LICENSE` and copy the exact copyright line. Do not rely on memory or summary recollection — license text is not the place to paraphrase.

### `TRADEMARK.md`

Approximately 15 lines. Substance:

- The Apache 2.0 license covers the source code only.
- The names "voxline" and the `logo.png` mark are not licensed under Apache 2.0; all rights reserved.
- Forks and derivative works must use a different name and a different logo.
- Nominative use ("compatible with voxline", "ported from voxline") is fine.
- Modeled loosely on the Apache Software Foundation's trademark policy at https://www.apache.org/foundation/marks/.

### `CONTRIBUTING.md`

Five sections. Approximate length 80 lines.

1. **Welcome.** Two lines acknowledging contributions are appreciated and pointing at the issue tracker for bugs/ideas.
2. **Building locally.** Point at `scripts/build-local.sh` (already exists). Mentions Xcode 15+ and Apple Silicon requirement (mirrors README's existing `Requirements` section — link, don't duplicate).
3. **Running tests.** `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'` (or whatever the existing scheme uses). Verify exact invocation at implementation time.
4. **Submitting changes.** Branch from `main`, follow the existing conventional commit style (`feat(...)`, `fix(...)`, `docs(...)` — visible in `git log`), keep PRs focused, include a test plan.
5. **DCO sign-off.** Every commit must include `Signed-off-by: Your Name <your.email@example.com>`. Use `git commit -s` (or `git commit -s --amend` to add it after the fact). Explain that the trailer asserts the contributor has the right to submit the work under the project's license. Link to https://developercertificate.org for the exact text.

### `.github/CODEOWNERS`

```
* @tfredricks
```

### `.github/PULL_REQUEST_TEMPLATE.md`

```markdown
## Summary

<what changed and why>

## Test plan

- [ ] ...

## Checklist

- [ ] Commits are signed off (DCO): `git commit -s`
- [ ] Tests pass locally
```

### `README.md` changes

Two surgical edits:

**1. Replace the existing "License" section** (currently ~3 lines reading "License TBD. Until one is added to this repository, no rights are granted beyond reading the source on GitHub.") with:

```markdown
## License

voxline is licensed under the [Apache License, Version 2.0](LICENSE).

See [NOTICE](NOTICE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for
required attributions. The "voxline" name and logo are reserved — see
[TRADEMARK.md](TRADEMARK.md).
```

**2. Insert a `## Contributing` section immediately above `## License`:**

```markdown
## Contributing

Bug reports, feature ideas, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, testing, and the
DCO sign-off requirement.
```

## Dependency License Audit

All direct dependencies pulled from `Package.resolved` are licensed under
Apache 2.0 or MIT. Both are compatible with outbound Apache 2.0 (no copyleft,
no incompatible patent terms). No license collisions; no special handling
required.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Wrong copyright year/holder string in `THIRD-PARTY-NOTICES.md` | Fetch each upstream `LICENSE` at implementation time and copy the exact line. |
| Dependency bumps drift `THIRD-PARTY-NOTICES.md` out of date | Manual review on every `Package.resolved` change. (No tooling proposed in this scope; consider later if churn warrants.) |
| GitHub rendering of the new files (line breaks, links) | Preview via `gh` or a local renderer before the commit. |
| Existing commits not DCO-signed | Don't retroactively rewrite history. DCO applies prospectively from the moment `CONTRIBUTING.md` lands. |

## Definition of Done

- All seven new files exist with their content as specified above.
- `README.md` "License TBD" sentence is gone; new License + Contributing sections render correctly on GitHub.
- A single commit on `main` introduces the change; commit message reflects "voxline is now Apache 2.0 open source."
- The repository's GitHub "About" sidebar will auto-detect the license as `Apache-2.0` after the push (no manual setting required).
- `git log` of the repo shows a clear "this is the moment voxline became open source" point.

## Future Work (Not in This Spec)

Listed for completeness so they don't get lost; explicitly deferred:

- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1) — add when there's an external contributor community.
- `SECURITY.md` — add when there's a real reporting process (e.g., GitHub Security Advisories enabled, or a dedicated email).
- CI workflow (`.github/workflows/ci.yml`) — build + test on PR. Worth doing once outside contributors arrive.
- Release automation (signed/notarized `.dmg` on GitHub Releases, optional Homebrew cask).
- SPDX headers on source files — only if/when downstream consumers ask.
- Tooling to keep `THIRD-PARTY-NOTICES.md` in sync with `Package.resolved`.
