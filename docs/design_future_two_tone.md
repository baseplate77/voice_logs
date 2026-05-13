# VoxSynth — Future Visual Design (Two-Tone)

Forward-looking visual design spec for a future VoxSynth release. Not in scope for the current implementation phase — captured here so the direction is documented before we touch UI code.

The aesthetic is inspired by a reference set of three screens (start / recording / detail) that share a high-contrast, two-tone, editorial feel. The defining move is the **split black/white home screen**: top half is a light "preview" surface, bottom half is a heavy black slab carrying the primary call-to-action. We want that energy throughout the app.

---

## 1. Design principles

1. **Two-tone as the system.** Every primary screen is composed from two horizontal zones — a light "content" zone and a dark "action" zone. The split is structural, not decorative. Users always know where the primary action lives: in the black.
2. **Editorial typography.** Oversized, tightly-tracked display text. The product feels like a magazine cover, not a settings panel. Labels in ALL CAPS, body in mixed case, numerals in a near-display weight.
3. **One red.** A single saturated red (`#FF3B30` family) is the only accent. It marks the live state (recording, playhead, destructive confirm). Nothing else competes.
4. **Honest controls.** Big square buttons with generous corner radius. No floating shadows, no gradients, no glassmorphism. Surfaces are flat; weight comes from value contrast, not blur.
5. **Waveforms are first-class.** The waveform is not a decoration — it is the primary navigational surface for any recorded log. Time scrubbing, segment highlight, and playhead all live on it.
6. **Calm motion.** Transitions slide along the two-tone seam. The dark slab grows or contracts to take over the screen during recording. No bouncy springs.

---

## 2. Color tokens

| Token              | Light mode | Dark mode  | Use |
|--------------------|-----------|-----------|-----|
| `bg.canvas`        | `#FFFFFF` | `#0A0A0A` | Top zone (content). |
| `bg.slab`          | `#0A0A0A` | `#0A0A0A` | Bottom zone (action). Always near-black, both modes. |
| `bg.slab.onLight`  | `#F2F1EE` | `#1A1A1A` | Inactive square buttons, highlight chips. |
| `fg.primary`       | `#0A0A0A` | `#F5F5F4` | Body text on canvas. |
| `fg.onSlab`        | `#FFFFFF` | `#FFFFFF` | Text on the black slab. |
| `fg.muted`         | `#B8B5B0` | `#5E5C58` | Pre-record placeholder transcript, secondary metadata. |
| `accent.red`       | `#FF3B30` | `#FF453A` | Live indicator, playhead, destructive primary. |
| `accent.red.soft`  | `#FFE5E2` | `#3A1410` | Red button pressed state. |
| `highlight.cream`  | `#EFEAE0` | `#2A2722` | Active transcript segment background. |

No other palette entries. If a UI need can't be solved with these eight tokens, the design isn't ready yet.

---

## 3. Typography

Single typeface, two roles. Target stack: **Inter Display** (or **General Sans**) for everything. If a serif is introduced later, it is only for the timer numerals.

| Role             | Size / weight             | Tracking | Use |
|------------------|---------------------------|----------|-----|
| `display.xl`     | 96 / 700, optical-size on | -2%      | "Start" CTA, timer `00:32:91`. |
| `display.l`      | 56 / 700                  | -1.5%    | Screen titles in dark slab ("Recording", "Editing"). |
| `headline`       | 28 / 600                  | -1%      | Transcript active segment. |
| `body`           | 20 / 500                  | 0        | Transcript body, log content. |
| `label.caps`     | 12 / 600, uppercase       | +8%      | "TALK", "TRANSCRIBE", "RECORDING", date headers. |
| `mono.timestamp` | 13 / 500, tabular         | 0        | `00:00:18` / `00:00:25` waveform bookends. |

Display sizes scale down one step on devices under 380 pt wide. Dynamic Type respected up to XXL; beyond that, the slab grows vertically rather than wrapping the CTA.

---

## 4. Spatial system

- **Grid:** 4 pt base. All paddings are multiples of 8.
- **Safe gutters:** 20 pt horizontal on phone, 32 pt on tablet.
- **The seam:** the line between canvas and slab sits at ~55% of the viewport on the home screen, ~0% (full slab) during active recording, and ~65% on the detail view. The seam is the only horizontal divider in the entire app — no other rules, no other dividers.
- **Square button:** 88 × 88 pt, corner radius 20 pt. Three of these fit across the safe area with 12 pt gaps.
- **Pill primary (Pause):** 200 × 64 pt, corner radius 18 pt, centered.

---

## 5. Screen specs

### 5.1 Home — split start screen

```
┌─────────────────────────────┐
│ 9:41                     ●  │  ← status bar, fg.primary on canvas
│                             │
│   TALK                      │  ← label.caps, scattered as editorial labels
│         TRANSCRIBE          │     over the waveform sample
│   EASY                      │
│                  FAST       │
│                             │
│   ▁▃▅▂▆▁▄▇▂▅▃▆▁▂▄▅▃▆▁▄    │  ← decorative ambient waveform
│ ───────────────────────────│  ← the seam
│                             │
│ Recording                   │  ← display.l on slab
│ Editing                     │
│                             │
│                             │
│                             │
│  ●                          │  ← tiny red dot, top-left of CTA row
│  Start              ◯─→     │  ← display.xl + red circular arrow
│                             │
└─────────────────────────────┘
```

- Tap target for "Start" spans the entire bottom slab — the whole black area is the button.
- The decorative waveform on top is generated from a deterministic seed per install so the screen feels personal but stable.
- The four editorial labels (`TALK`, `TRANSCRIBE`, `EASY`, `FAST`) rotate from a curated list of 8–12 each app launch.

### 5.2 Recording — single-zone, slab retreats

When the user taps Start, the slab animates upward off-screen and the recording surface takes over the full canvas. The two-tone discipline is preserved by the bottom control row: a horizontal strip of three "tiles" replaces the slab.

```
┌─────────────────────────────┐
│ ←        RECORDING        🗑│  ← label.caps title
│                             │
│        00:32:91             │  ← display.xl, tabular numerals
│        Recorded time        │  ← label.caps, fg.muted
│                             │
│  ▁▃▅▂▆▁▄▇▂▅▃▆▁▂▄┃▃▆▁▄      │  ← live waveform, red playhead bar
│ ───────────────────────────│  ← seam shown only when scrolled
│                             │
│  Today I'm going to talk    │  ← body, fg.muted (already-spoken
│  about new marketing        │     transcript, ghosted)
│  strategies for business    │
│  owners.                    │
│                             │
│  First, let's get to know…  │  ← headline, fg.primary (live partial)
│                             │
│ ┌────┐  ┌──────────┐  ┌────┐│
│ │ ✎  │  │  Pause   │  │ ✓  ││  ← edit | pause (pill) | confirm
│ └────┘  └──────────┘  └────┘│
└─────────────────────────────┘
```

- The playhead is `accent.red`, 2 pt wide, with a 6 pt circular cap at the top.
- Partial transcripts fade from `fg.muted` (older) to `fg.primary` (most recent sentence). This is the "two-tone" rendered in *time* instead of *space*.
- Pause is the pill; edit and confirm are square tiles on `bg.slab.onLight`.

### 5.3 Detail — read & scrub

```
┌─────────────────────────────┐
│ ←     FEB 01, 2025 2:46 PM 🗑│
│                             │
│  Today I'm going to talk    │  ← body, fg.muted
│  about new marketing        │
│  strategies for business    │
│  owners.                    │
│                             │
│ ╭─────────────────────────╮│  ← active segment chip on highlight.cream
│ │ First, let's get to     ││
│ │ know… My name is David  ││
│ │ Crowie and I am current ││
│ │ hmm…                    ││
│ ╰─────────────────────────╯│
│                             │
│  Financial consultant with… │  ← upcoming, fg.muted
│ ───────────────────────────│  ← seam
│  ▁▃▅▂▆▁▄┃▂▅▃▆▁▂▄▅▃▆▁▄     │  ← scrub waveform with red playhead
│  00:00:18         00:00:25  │  ← mono.timestamp
│                             │
│ ┌────┐ ┌────┐ ┌────┐        │
│ │ ⟲  │ │ ⏺  │ │ ✓  │        │  ← rewind 15s | re-record segment | done
│ └────┘ └────┘ └────┘        │
└─────────────────────────────┘
```

- The active transcript segment is wrapped in a `highlight.cream` rounded rectangle (radius 14, padding 16/20). Tapping a segment scrubs the playhead to its start.
- Tiles at the bottom: rewind (`bg.slab.onLight`), re-record segment (`bg.slab`, the only fully-black tile), confirm/done (`accent.red`). This is the canonical "three-tile" pattern.

---

## 6. The three-tile pattern

The trio at the bottom of recording and detail screens is the app's most repeated motif. It encodes a consistent grammar:

| Slot   | Tone               | Meaning                                  |
|--------|--------------------|------------------------------------------|
| Left   | `bg.slab.onLight`  | Soft / reversible action. Edit, rewind.  |
| Center | `bg.slab` (black)  | Stateful / primary toggle. Pause, record.|
| Right  | `accent.red`       | Commit / destructive confirm.            |

Users learn this once. Every subsequent screen using a tile row reads instantly.

---

## 7. Motion

- **Slab transition (home → recording):** slab translates up over 320 ms, ease-out cubic. The decorative waveform on top fades to 0 over the first 120 ms.
- **Tile press:** scale 0.96 over 80 ms, no shadow, no color change.
- **Playhead:** linear, snaps to segment boundaries within 8 ms.
- **Transcript fade-in (live):** new tokens enter at `fg.primary`, drift to `fg.muted` over 1.2 s as they age off the active line.

No spring physics anywhere. No parallax. The design wants to feel printed, not bouncy.

---

## 8. Iconography

- Custom 24 pt line set, 1.75 pt stroke, rounded caps.
- Icons we need on day one: back chevron, trash, edit (pencil), confirm (check), rewind (counter-clockwise arc), record (filled circle), pause (two bars), play (triangle).
- No filled icon variants. Active state is expressed by tile color, not glyph weight.

---

## 9. Accessibility

- Minimum contrast 7:1 for body text on canvas, 4.5:1 for muted ghosted transcripts (still legible because they're typographically large).
- Tile targets are 88 pt — already above 44 pt minimum.
- The "Start" slab is announced as a single button (`Start recording`) by VoiceOver/TalkBack, not as a region.
- Red is never the only signal. The live state is also indicated by the timer running, the playhead moving, and the recording indicator in the status bar.
- Dynamic Type tested at every step from XS to AX5; layout reflows by expanding the slab vertically rather than shrinking the CTA.

---

## 10. What this design is *not*

- Not a redesign of the data model, pipeline, or settings UI. Those continue to follow the locked architecture in `CLAUDE.md`.
- Not multi-themed. There is one visual system. Dark mode is a value inversion of the same system, nothing more.
- Not a marketing site aesthetic ported into product. The editorial labels (`TALK`, `EASY`) only appear on the home screen as ambient texture — they are never functional controls.
- Not animated. Static-feeling on purpose. Motion is only used to translate the two-tone seam.

---

## 11. Open questions (to resolve before implementation)

1. Does the home-screen ambient waveform draw from a real prior recording, or is it always synthetic? Real recordings feel more personal but raise a small privacy surface (a glance reveals you've journaled).
2. Should the three-tile pattern's center black tile invert to red while *actively recording* a re-take, or stay black and rely on the playhead alone?
3. Timer numerals — keep them in Inter Display, or introduce a serif (e.g. *Tiempos Headline*) only for `display.xl` numerals? The reference leans neutral sans; a serif would push harder on the editorial feel.
4. Detail view: do we keep the seam visible at rest, or only render it when the waveform is in view? Hidden-by-default reads cleaner; always-visible enforces the system more strictly.

These are visual-only decisions. Resolve before sketching any Flutter widgets.
