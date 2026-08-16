---
name: glassmorphic-validator
description: Enforce a consistent glassmorphic design system across every nested layout section — fixed backdrop-blur, border, and surface-tint tokens with no per-component drift. Use when building or reviewing any Tailwind UI that uses frosted-glass surfaces.
---

# Glassmorphic Validator

Goal: every glass surface in the app looks like it came from the same design system, because the values are fixed rather than re-invented per component.

Glassmorphism fails in one specific way: each new panel gets slightly different blur, border opacity, and tint, so the UI reads as sloppy rather than as a system. The fix is a small closed set of tokens and the discipline not to add to it.

---

## The canonical tokens

These are the values. Do not substitute near-misses.

| Role | Classes |
|---|---|
| **Glass surface** | `bg-white/5 backdrop-blur-xl border border-white/10` |
| **Raised / hover** | `bg-white/10 border-white/20` |
| **Recessed (inset well)** | `bg-black/20 border-white/5` |
| **Radius** | `rounded-2xl` (panels) · `rounded-xl` (cards, inputs) · `rounded-lg` (buttons, chips) |
| **Divider** | `border-white/10` — never a solid gray |
| **Primary text** | `text-white` |
| **Secondary text** | `text-white/60` |
| **Muted / meta text** | `text-white/40` |
| **Panel padding** | `p-6` (panels) · `p-4` (cards) · `px-3 py-2` (controls) |
| **Section gap** | `gap-6` (major) · `gap-4` (within a panel) · `gap-2` (tight rows) |

Full glass surface, as written every time:

```jsx
<div className="bg-white/5 backdrop-blur-xl border border-white/10 rounded-2xl p-6">
```

## Rules

**1. Blur is always `backdrop-blur-xl`.** One blur value for the whole app. Not `-sm`, not `-md`, not `-2xl` on the "important" panel. Varying blur is the single strongest tell that a UI was assembled rather than designed.

**2. Borders are always white at low opacity.** `border-white/10` at rest, `border-white/20` when raised or hovered. Never `border-gray-700`, never `border-slate-800`, never a solid hex. The border is a highlight catching light on a glass edge, not an outline.

**3. Surfaces are white at low opacity, never opaque.** `bg-white/5`. If a panel needs to feel heavier, go to `bg-white/10` — do not reach for `bg-slate-900`. An opaque background inside a glass layout is a hole in the glass.

**4. Nested glass steps up, never down.** A card inside a panel goes `bg-white/5` → `bg-white/10`. It never repeats its parent's exact value (the boundary disappears) and never goes darker than its parent (reads as a hole).

**5. Stop nesting at two levels.** Panel → card. A third blurred layer inside that is mud — no depth cue survives it. If the design seems to need a third level, use spacing, a `border-white/10` divider, or a text-weight change instead.

**6. Backdrop blur needs something behind it.** `backdrop-blur-xl` over a flat solid background does literally nothing. The page must have a gradient, mesh, or image behind the glass, e.g.:

```jsx
<div className="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900/40 to-slate-900">
```

If you find blur classes with no textured backdrop, either add the backdrop or drop the blur — keeping a no-op class is worse, because it looks correct in review and does nothing on screen.

**7. One accent color, used sparingly.** Pick a single hue for interactive/active state and use it only there — active nav item, primary button, focus ring. Everything else is white-on-transparent. Two accent colors in a glass UI reads as unfinished.

**8. Text contrast is the three-step ramp.** `text-white` / `text-white/60` / `text-white/40`. Nothing below `/40` — it fails contrast over a light patch of the gradient backdrop. Never put body text directly on `bg-white/5` without the glass surface behind it.

**9. Transitions are uniform.** `transition-colors duration-200` on anything with a hover state. Do not vary the duration per component.

**10. Shadows are optional and uniform.** If used at all, `shadow-2xl shadow-black/20` on top-level panels only. Never on nested cards — stacked shadows destroy the sense of translucency.

---

## Validation pass

Before calling a glassmorphic UI done, grep the source and confirm each of these. Report the count per check, and fix rather than justify any that fail.

1. Every `backdrop-blur-*` is `backdrop-blur-xl` — no other blur step appears.
2. Every `backdrop-blur-xl` is accompanied by a `bg-white/…` and a `border-white/…` on the same element.
3. No opaque `bg-` utility (`bg-slate-800`, `bg-gray-900`, `bg-[#…]`) on any element inside the glass tree. The page-level gradient is the sole exception.
4. No `border-gray-*` / `border-slate-*` / hex borders anywhere.
5. Text opacities are only `text-white`, `/60`, `/40`.
6. Radii come only from the table above.
7. No third level of nested blur.
8. Exactly one accent hue across the file set.
9. The page root has a gradient or textured backdrop.

Useful sweep on Windows/PowerShell:

```powershell
rg -o 'backdrop-blur-\w+' -N src | Sort-Object -Unique
rg -n 'bg-(slate|gray|zinc|neutral)-\d{3}' src
rg -n 'border-(slate|gray|zinc)-\d{3}' src
rg -o 'text-white/\d+' -N src | Sort-Object -Unique
```

Each should return exactly one blur value, no opaque-background hits, no non-white borders, and only the sanctioned text ramp.
