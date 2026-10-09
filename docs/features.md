# AI Dictation / Voice-to-Text Feature Comparison Framework

## Voice Input

| Feature | Why it Matters |
|---------|----------------|
| Wake hotkey | Fast access without interrupting workflow |
| Push-to-talk vs toggle | Supports different dictation styles |
| Always listening | Enables hands-free workflows |
| Auto language detection | Useful for multilingual users |
| Offline transcription | Privacy and travel support — Whisper and Apple Speech run on-device |
| Streaming transcription | Low perceived latency — a live transcript in the pill while you speak (stable text bright, still-changing text dim) |
| Choice of speech engine | Trade speed, accuracy, and privacy — Apple Speech (fastest, the default), Whisper, or OpenAI, picked in Settings |
| Cloud speech-to-text | Hosted recognition for users who accept audio leaving the device — OpenAI (opt-in, your own key), with an on-device fallback if the cloud fails |
| Cancel in flight | Drop a bad take before it is inserted — Esc while recording, transcribing, or cleaning up |
| Speaker adaptation | Learns your voice over time |
| Accent support | Better accuracy across regions |

---

## Transcription Quality

| Feature | Why it Matters |
|---------|----------------|
| Punctuation | Produces readable text |
| Grammar correction | Creates polished output |
| Filler removal | Removes "um", "uh", etc. |
| Sentence restructuring | Converts speech into natural writing |
| Custom vocabulary | Handles company names and jargon |
| Acronym expansion | Improves industry-specific accuracy |

---

## Context Awareness

| Feature | Why it Matters |
|---------|----------------|
| Detect current application | Adjusts behavior for email, Slack, docs, etc. |
| Read screen context | Improves output using surrounding information |
| Cursor awareness | Continues paragraphs naturally |
| Selection rewriting | Rewrites selected text intelligently — hold the command chord (default Left Shift + Left Option) and speak what to change |
| Form awareness | Behaves differently in forms vs. documents |

---

## Writing Intelligence

| Feature | Why it Matters |
|---------|----------------|
| Tone control | Professional, casual, concise, etc. |
| Writing modes | Email, notes, messaging, coding |
| Prompt templates | Repeatable workflows |
| AI rewrite after dictation | Improves content rather than simply transcribing |
| Multiple rewrite options | Lets users choose the best version |
| Length control | Expand or shorten output |

---

## Commands & Automation

| Feature | Why it Matters |
|---------|----------------|
| Voice commands | "Delete previous sentence", "Start bullet list", etc. |
| Custom commands | User-defined automations |
| Snippets | Insert common text |
| Variable placeholders | Dynamic templates |
| Workflow automation | Trigger actions from voice |
| Voice edit at the cursor / rewrite in place | Say an instruction to draft or continue at the cursor, or to change just part of the field; the edit lands in place and ⌘Z undoes it |
| Preset edit shortcuts | Select text and press a shortcut (default ⌥1 / ⌥2 / ⌥3) to run a stored instruction with no recording; the table is editable |

---

## Developer Features

| Feature | Why it Matters |
|---------|----------------|
| Code mode | Preserves programming syntax |
| IDE awareness | Understands current language/project |
| Markdown mode | Better documentation workflows |
| Terminal support | Dictate shell commands |
| CamelCase / snake_case handling | Easier coding by voice |

---

## Performance

| Feature | Why it Matters |
|---------|----------------|
| Startup time | Fast launch |
| End-to-end latency | Time from speaking to finished text |
| Accuracy | Core value metric |
| CPU / battery impact | Laptop and mobile usability |

---

## Integrations

- Microsoft Office
- VS Code
- Webex
- Zoom
- Chrome
- Jira

---

## Personalization

| Feature | Why it Matters |
|---------|----------------|
| Learns writing style | Adapts over time |
| Learns corrections | Avoids repeated mistakes |
| Multiple personas | Different styles for work and personal use |
| Team style guides | Consistent organizational voice |

---

## Accessibility

| Feature | Why it Matters |
|---------|----------------|
| Keyboard-free operation | Hands-free usage |
| Voice-only editing | Minimal keyboard dependence |
| Accessibility APIs | Better OS integration |

---

## Reliability

| Feature | Why it Matters |
|---------|----------------|
| Works offline | Reliable without connectivity |
| Automatic retries | Handles network interruptions |
| Manual retry | Recover without re-speaking — Retry in the pill or "Retry last dictation" in the menu bar re-runs cleanup on the saved transcript |
| Version history | Recover previous dictations |
| Undo support | Easy mistake recovery — dictation and command edits land through Accessibility in native apps, so ⌘Z undoes them |

---

# Key Differentiators

These are the capabilities I'd pay the most attention to when evaluating products in this category.

## Context Awareness
Does it understand **what you're doing**, not just **what you're saying**?

## Workflow Automation
Can speech trigger actions instead of simply producing text?

## Personalization
Does it learn your writing style, preferred phrasing, and terminology?

## Developer Experience
Is it genuinely useful for software development?

## Privacy Flexibility
Can users choose between local, cloud, or hybrid processing?

## Enterprise Readiness
Does it support centralized management, compliance, and shared resources?

---

# Next-Generation Opportunities

If I were advising a new entrant, I'd look beyond matching competitors and build capabilities like these:

- **Conversation memory** – Remember recurring names, projects, and terminology across sessions.
- **Intent detection** – Automatically determine whether the user is writing an email, creating a task, taking notes, coding, or chatting.
- **Voice macros** – Turn spoken commands into multi-step workflows.
- **Real-time coaching** – Suggest clearer wording while dictating.
- **Meeting continuity** – Seamlessly move from meeting capture to summaries, action items, and follow-up drafts.
- **Model choice** – Let users select AI models based on speed, quality, privacy, or cost. (voxline: provider and cleanup model, plus a separate command model for edits in Settings → Command.)
- **Knowledge grounding** – Use company documents, CRM data, or project context when rewriting.
- **Cross-device continuity** – Continue dictation sessions across desktop and mobile.
- **Adaptive UI** – Surface controls and suggestions based on the current application and task.

---

# Evaluation Scorecard

| Category | Weight | Score (1–5) | Notes |
|----------|-------:|------------:|------|
| Voice Input | 10% | | |
| Transcription Quality | 20% | | |
| Context Awareness | 15% | | |
| Writing Intelligence | 15% | | |
| Automation | 10% | | |
| Developer Features | 5% | | |
| Integrations | 5% | | |
| Personalization | 10% | | |

**Total Weighted Score:** _____ / 100