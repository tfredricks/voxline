# Changelog

All notable changes to voxline are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches its first tagged release.

## [Unreleased]

## [0.2.5] - 2026-07-10

### Added

- **Transform selected text by voice.** Highlight text in any app, press the
  dictation hotkey, and speak a rewrite/restructure command — "make this a
  bullet list", "make this cleaner", "make this shorter". voxline rewrites the
  selection in place and leaves it as a normal ⌘Z-undoable edit. When no text
  is selected, the hotkey dictates as before. Transforms open the same
  post-dictation refinement pill for quick follow-ups.

### Fixed

- Text insertion now prefers ⌘V clipboard paste over synthetic typing, so
  dictation and transforms land reliably in apps (such as Notes) that ignore
  synthetic keystrokes. Under the App Sandbox the previous AX-based
  paste-eligibility check always failed and forced the unreliable typing path.

[Unreleased]: https://github.com/tfredricks/voxline/compare/v0.2.5...HEAD
[0.2.5]: https://github.com/tfredricks/voxline/releases/tag/v0.2.5
