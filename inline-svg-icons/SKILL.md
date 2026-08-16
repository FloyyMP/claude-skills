---
name: inline-svg-icons
description: Write all icons as hand-authored inline SVG with one fixed house spec, and never import a third-party icon package. Use whenever a UI needs an icon, glyph, logo mark, empty-state illustration, or any other vector graphic.
---

# Inline SVG Icons

Two jobs: keep icon packages out of the tree, and keep every hand-drawn icon on one spec so a set of forty looks drawn by one hand.

## Rule 1: No icon packages. Ever.

Never `import` from `lucide-react`, `react-icons`, `@heroicons/react`, `@radix-ui/react-icons`, `phosphor-react`, `feather-icons`, `@fortawesome/*`, or any equivalent. Never add one to `package.json`. Never load an icon sprite or font from a CDN.

This rule holds all the way through a long build. The pull toward `import { Plus } from 'lucide-react'` is strongest around file 30, when the icon is incidental to the component you actually care about — that is exactly the moment to write the twelve characters of path data instead.

If an icon is genuinely too complex to hand-author, simplify the icon. Do not reach for a package.

## Rule 2: One house spec

Every icon is authored as this element, varying only the paths inside:

```jsx
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"
     strokeLinecap="round" strokeLinejoin="round" className="w-5 h-5" aria-hidden="true">
  {/* paths */}
</svg>
```

Fixed across the whole app, no exceptions:

- **`viewBox="0 0 24 24"`** — always. Author on the 24-grid even for a 16px render; scale with classes, never by changing the viewBox.
- **`fill="none"` + `stroke="currentColor"`** — outline style, inheriting text color. Never a hardcoded `stroke="#fff"` or a Tailwind color on the `<svg>`; color it by setting `text-*` on the icon or its parent.
- **`strokeWidth="1.5"`** — one weight, app-wide. Not 2 on the "important" icons. Varying stroke weight is the same tell as varying blur.
- **round caps and joins** — always both.
- **Size via classes only** — `w-4 h-4` (inline with text) · `w-5 h-5` (default, buttons and nav) · `w-6 h-6` (headers, empty states). Never a `width`/`height` attribute.
- **`aria-hidden="true"`** when the icon sits beside a text label. If it's alone in a button, the *button* gets the `aria-label` — not the svg.

Geometry: snap to the 24-grid, keep a ~2px margin inside the viewBox so icons optically match, and build from as few subpaths as the shape allows.

## Rule 3: Define once, reuse

Each icon is one named component in a single `icons.jsx` module, never pasted inline at call sites:

```jsx
export const PlusIcon = (props) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"
       strokeLinecap="round" strokeLinejoin="round" className="w-5 h-5" aria-hidden="true" {...props}>
    <path d="M12 5v14M5 12h14" />
  </svg>
)
```

Spread `{...props}` last so a call site can override `className` for size. Two components drawing the same glyph is the bug this rule prevents — they will drift.

## Larger graphics

Empty-state and decorative illustrations relax the 24-grid but keep the rest: `currentColor`, no hardcoded palette, `viewBox` + class sizing, no external assets. Set opacity with `text-white/40` on a wrapper rather than baking `opacity` into paths.

## Validation

```powershell
rg -n "from '(lucide-react|react-icons|@heroicons|@radix-ui/react-icons|phosphor-react|feather-icons)" src
rg -o 'strokeWidth="[\d.]+"' -N src | Sort-Object -Unique
rg -o 'viewBox="[^"]+"' -N src | Sort-Object -Unique
rg -n '<svg[^>]*(width|height)=' src
```

Expect: no package hits, exactly one stroke width, `0 0 24 24` as the only icon viewBox, and no `width`/`height` attributes.
