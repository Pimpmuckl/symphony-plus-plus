---
name: Symphony++
description: A calm, dense, trustworthy control room for human-supervised agent delivery.
colors:
  control-teal: "#00647a"
  canvas: "#f9fafb"
  surface: "#ffffff"
  ink: "#161b27"
  muted-surface: "#edf0f3"
  muted-ink: "#646d7d"
  border: "#d6dbe1"
  active-signal: "#0da2e7"
  ready-signal: "#2c64dd"
  waiting-signal: "#778192"
  complete-signal: "#25a777"
  blocked-signal: "#e3264c"
  dark-canvas: "#0c1018"
  dark-surface: "#121721"
  dark-ink: "#eceff3"
  dark-control-teal: "#13b7d8"
  dark-border: "#2f3846"
typography:
  body:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
  title:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 720
    lineHeight: 1.2
    letterSpacing: "-0.006em"
  label:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 650
    lineHeight: 1
  mono:
    fontFamily: "Geist Mono Variable, ui-monospace, monospace"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.2
rounded:
  sm: "4px"
  md: "6px"
  lg: "8px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
components:
  button-primary:
    backgroundColor: "{colors.control-teal}"
    textColor: "{colors.surface}"
    rounded: "{rounded.md}"
    height: "36px"
    padding: "8px 16px"
  input:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    height: "36px"
    padding: "4px 12px"
  execution-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "8px 10px"
  status-chip:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.muted-ink}"
    rounded: "{rounded.pill}"
    padding: "4px 8px"
---

# Design System: Symphony++

## Overview

**Creative North Star: "The Live Control Room"**

Symphony++ is a calm operational surface for supervising live agent work. It is information-dense without becoming visually loud: inactive structure recedes, active work carries motion, and meaningful state changes are visible immediately.

The interface rejects nested-card labyrinths, oversized execution records, beige neutral states, and decorative workflow graphics. Geometry must stay stable while status changes. Complex work may reveal more structure, but the operator's mental map always wins.

**Key Characteristics:**

- Compact, state-first information hierarchy.
- Cool neutral surfaces with restrained semantic signals.
- Stable spatial organization from overview to detail.
- Motion only for activity, topology changes, and direct feedback.
- Familiar product controls with explicit keyboard and focus behavior.

### WorkRequest Reveal Motion Contract

The WorkRequest transition has three explicit keyframes in each direction. The
Focus Board shell, its header, and the selected category label stay mounted and
visible throughout. Later sibling categories stay mounted but leave and return
as whole sections, so their labels never become stranded from their cards.

#### Reveal

1. **The space.** WorkRequests above the selected WorkRequest stay fixed.
   WorkRequests to its left slide through the left viewport edge, those to its
   right through the right edge, and those below through the bottom edge. The
   selected WorkRequest slides horizontally to the left edge of its current
   category while remaining in the same grid row. Only cards in that category
   participate. Travel scales with the measured execution-board height: compact
   boards use a short slide and fade, while large boards keep the full push. The
   camera stays put.
2. **The group.** Everything below the selected WorkRequest's progress divider
   slides quickly upward behind that divider, like a drawer closing into the
   progress bar. The execution graph or empty-state body is already mounted at
   zero height so its natural expanded height is known before the next keyframe.
3. **The expanse.** The full-width execution graph reserves its natural height,
   paints one fully clipped frame, then reveals through a clipping window from the selected WorkRequest's
   bottom edge. The
   compact title block keeps its width while the graph surface extends across
   the category, sharing one continuous outline rather than appearing as a
   second card. As the page regains height, the camera aligns the selected
   WorkRequest near the top with a thin margin. The graph is revealed in place
   and does not translate or redraw.

Before the sequence starts, measure unused height beneath the selected card in
its current grid row and subtract the frontier that keyframe two will close. The
attached graph consumes that resulting slack first, so short empty-state cards
and cards with only one or two WorkPackages meet the graph at the same one-pixel
seam as taller grouped cards.

#### Collapse

1. **The unexpanse.** The still-mounted execution graph closes through the same
   clipping window before its reserved space is removed.
2. **The group.** The compact group summary slides back out beneath the progress
   divider only after the graph has fully contracted.
3. **The return.** The selected WorkRequest and every displaced WorkRequest
   retrace their paths to their exact original grid positions while the camera
   returns to its original position.

Do not replace these keyframes with `display: none`, a fullscreen card, or a
different grid placement. Keep the selected card in its original grid cell and
move it only with a horizontal transform. Reduced motion performs the equivalent
state change immediately.

Focus Board category disclosures use the same drawer principle without replaying
the WorkRequest choreography. Their content stays mounted and spatially fixed;
only an outer clipping window changes height beneath the category heading. No
card translation, opacity, or stagger animation runs when a category opens or
closes.

All Repositories uses the same reserved-space clipping pattern. Opening and
closing reveal or hide the mounted board without animating intrinsic height;
the opening camera movement remains synchronized with that clipping window.

## Colors

The palette is an operational signal system. Cool neutrals carry the interface; saturation is reserved for identity, focus, and real lifecycle state.

### Primary

- **Control Teal** (#00647a): Primary actions, focus identity, selected controls, and the Symphony++ brand anchor.

### Secondary

- **Active Blue** (#0da2e7): Work executing now and animated dependency flow.
- **Ready Blue** (#2c64dd): Work available for its next actor without implying activity.
- **Waiting Violet-Gray** (#778192): Ready-adjacent work whose prerequisites are not yet satisfied.
- **Complete Green** (#25a777): Terminal success and satisfied dependency gates.
- **Blocked Red** (#e3264c): Explicit failure or intervention state, never a blanket tint for downstream waiting work.

### Neutral

- **Canvas** (#f9fafb): Main light-mode working surface.
- **Surface** (#ffffff): Cards, controls, and focused content.
- **Ink** (#161b27): Primary text and high-confidence labels.
- **Muted Surface** (#edf0f3): Secondary controls and quiet grouping.
- **Muted Ink** (#646d7d): Supporting metadata that still meets contrast requirements.
- **Border** (#d6dbe1): Structural separation without faux elevation.
- **Dark Canvas** (#0c1018), **Dark Surface** (#121721), **Dark Ink** (#eceff3), **Dark Control Teal** (#13b7d8), and **Dark Border** (#2f3846): Equivalent cool-neutral roles in dark mode.

### Named Rules

**The Operational Signal Rule.** Semantic color describes current state; it is never decoration.

**The No Beige Rule.** Planned, waiting, and inactive states use cool neutral or violet-neutral tones. Cream, parchment, tan, and beige are prohibited.

## Typography

**Display Font:** Geist Variable with system sans-serif fallbacks  
**Body Font:** Geist Variable with system sans-serif fallbacks  
**Label/Mono Font:** Geist Mono Variable with system monospace fallbacks

**Character:** One compact sans-serif family carries the product hierarchy. Monospace appears only where repository, branch, identifier, or machine-oriented context benefits from it.

### Hierarchy

- **Headline** (600–700, 16–20px, 1.2): Page and major section identity.
- **Title** (720, 13px, 1.2): Execution cards and dense row headings.
- **Body** (400, 14–16px, 1.5): Explanations, forms, and detail content; prose stays within 75 characters per line.
- **Label** (650, 11px, 1): Lifecycle chips, counters, and compact state.
- **Mono** (500, 11px, 1.2): Repository, branch, package identifiers, and gate progress.

### Named Rules

**The Hierarchy Before Size Rule.** Weight, alignment, and spacing establish importance before larger text does.

## Elevation

Symphony++ uses state-based layering. Cards and groups stay visually still at rest and during focus. Borders, tonal shifts, focus outlines, and shine communicate interaction; cards never lift or translate. Shadows are restrained and structural, reserved for floating panels or subtle separation from a busy surface.

### Shadow Vocabulary

- **Card Separation** (`0 3px 10px rgb(22 27 39 / 0.06)`): Low light-mode separation for execution entities.
- **Dark Card Separation** (`0 7px 20px rgb(0 0 0 / 0.22)`): Dark-mode compensation for reduced tonal contrast.
- **Dashboard Float** (`0 18px 50px rgb(15 23 42 / 0.08)`): Dialogs and truly floating dashboard surfaces only.

### Named Rules

**The No Lift Rule.** Hover, focus, and selection never move cards. Use outline, border, shadow, or shine instead.

## Components

### Buttons

- **Shape:** Compact rounded rectangle (6px radius).
- **Primary:** Control Teal with white text; default height is 36px and compact height is 32px.
- **Hover / Focus:** Tonal darkening on hover and a 2px focus ring. No positional movement.
- **Secondary / Ghost:** Quiet neutral surfaces; use only when hierarchy requires a lower-priority action.

### Chips

- **Style:** Fully rounded, compact, and single-line; 11px semibold labels with 4px by 8px padding.
- **State:** Border, text, and faint background all express the same semantic state. Text remains the non-color cue.

### Cards / Containers

- **Corner Style:** Gently curved (8px radius).
- **Background:** White or the appropriate semantic tint over the cool canvas.
- **Shadow Strategy:** Flat by default with low structural separation; focus uses outline and glow, never lift.
- **Border:** One-pixel cool-neutral or semantic border.
- **Internal Padding:** 8–12px for dense operational cards; larger detail cards may use 20px.

### Inputs / Fields

- **Style:** 36px high, 6px radius, one-pixel border, and 12px horizontal padding.
- **Focus:** Explicit 2px Control Teal ring.
- **Error / Disabled:** Error uses Blocked Red plus text; disabled controls reduce contrast and interaction together.

### Navigation

- **Style:** Familiar tabs and toolbar controls with compact 14px labels. Selection uses surface contrast, border, and state—not novel navigation mechanics.
- **Mobile:** Structure becomes vertical; labels and controls remain keyboard and touch accessible.

### Execution Graph

- Root groups and standalone WorkPackages occupy dependency-ranked columns. Entities in the same rank stack vertically; every three ranks continue in a new top-to-bottom band.
- A deterministic predecessor sweep orders otherwise equivalent entities to reduce crossings without changing their dependency rank.
- Status-only updates and group expansion never reshuffle root entities.
- Desktop routes always leave the source on the right and enter the target on the left. Direct neighbors use the column gap; skipped ranks and band jumps use reserved node-free corridors, gutters, and an outer bus.
- Independent routes reserve six-pixel clearance and never share a segment. A bounded reroute pass moves avoidable crossings into free corridors; genuinely non-planar dense graphs may still cross rather than hide or invent dependencies. Route geometry is state-neutral; color and dashes communicate state after layout is fixed.
- Dependency gates receive inputs from the left on desktop and from the top on mobile. Corridor inputs take the corresponding upper or leading gate slot.
- A small source dot establishes direction without arrowheads or decorative markers.
- Groups use the same visual grammar as WorkPackages. Expansion reveals children inside the existing group boundary and preserves external connections.

## Do's and Don'ts

### Do:

- **Do** keep title, lifecycle state, progress, and PR presence as the primary execution-card content.
- **Do** preserve stable geometry during lifecycle updates and group expansion.
- **Do** route dependencies around cards through explicit gutters and corridors.
- **Do** use shine and animated dashes only for genuinely active state.
- **Do** preserve keyboard focus, reduced motion, and non-color state labels.

### Don't:

- **Don't** create nested-card labyrinths that make hierarchy harder to read.
- **Don't** use oversized execution cards filled with bookkeeping details.
- **Don't** use beige, cream, parchment, or tan for neutral, planned, or waiting states.
- **Don't** draw decorative workflow lines that cross cards, overlap unpredictably, or imply false sequencing.
- **Don't** elevate internal execution records above product-facing work.
- **Don't** encode guardrails and lifecycle copy that make ordinary recovery harder than the work itself.
- **Don't** move cards on hover, focus, selection, or status change.
