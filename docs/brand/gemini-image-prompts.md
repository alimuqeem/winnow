# Winnow — icon & logo prompts for Gemini image generation

_Working name: **Winnow**. To winnow is to separate grain from chaff, which is
exactly what the app does to a photo library: keep the best shot, let the rest
blow away. It also shrinks videos. The brand should feel calm, careful and
trustworthy ("everything stays recoverable"), not like an aggressive "cleaner"._

## How to use these

- Generate **4–8 variations per prompt** and shortlist. Icons are rarely right first time.
- Ask for **1:1, 1024×1024** for icons. For the wordmark, ask for **3:1** or **4:1**.
- Gemini tends to add stray text, so every icon prompt says "no text". If letters still
  appear, follow up with: _"Same image, remove all text and letters."_
- Iterate in the same chat: _"Keep the composition, make the background a deeper teal"_,
  _"simplify: fewer grains"_, _"make it read at 32 px"_.
- When you have a favourite, check it at **16, 32, 128 px**. A macOS icon must still read
  in the Dock and in Finder list view.
- Final macOS icons need a 1024 px master. Xcode generates the smaller sizes; I can wire
  up the asset catalogue once you pick one.

**Palette guidance** (optional, paste into any prompt): deep teal `#1F6F6A`,
warm wheat gold `#E3B661`, soft cream `#F4EFE6`, charcoal `#22272B`.

---

## 1. App icon: primary concepts

### 1A. Wheat stalk + photo frame (literal, warm)
```
A macOS app icon in the modern Apple style: a rounded-square ("squircle") tile with
subtle depth and a soft glass-like sheen. On a deep teal background sits a single
stylised golden wheat stalk whose top grains gently transform into tiny rounded
photo frames, with a few loose chaff flakes drifting away to the upper right and
fading out. Clean vector-like rendering, soft studio lighting, gentle inner shadow,
minimal detail so it reads at small sizes. Calm, premium, trustworthy mood.
No text, no letters, no watermark. 1:1, 1024×1024, centred, generous padding.
```

### 1B. Stacked photos, one kept (concept: best shot wins)
```
A macOS app icon, rounded-square tile with Apple's current layered glass aesthetic.
Three overlapping photo cards fanned slightly, rendered as simple frosted glass
rectangles with rounded corners. The front card is crisp and glowing with a small
warm-gold checkmark badge; the two behind it are softer, slightly translucent and
drifting backwards like they are being blown away. Background gradient from deep
teal to darker teal. Minimal, elegant, no photographic content inside the cards
(use soft abstract gradients). No text. 1:1, 1024×1024.
```

### 1C. Sieve / winnowing basket (craft, distinctive)
```
App icon for macOS: a shallow, round winnowing basket seen from slightly above,
simplified into a clean geometric shape with a woven pattern suggested by a few
curved lines. Golden grains rest in the basket while a few tiny light flakes float
up and away. Warm wheat-gold basket on a soft cream rounded-square tile, with a
teal accent ring. Flat-meets-3D style like Apple's built-in app icons, soft shadows,
no clutter. Must read clearly at 32 pixels. No text, no letters. 1:1, 1024×1024.
```

### 1D. Abstract "W" from grains (monogram)
```
A minimal macOS app icon: a bold, friendly letter-shape "W" formed entirely from
rounded golden grain shapes (like wheat kernels) arranged in a clean pattern, on a
deep teal rounded-square tile with a subtle glass highlight along the top edge.
Two or three grains at the right edge are breaking away and fading, suggesting
sorting and lightness. Geometric, balanced, high contrast, premium. The W is made
of shapes, not typed text; no other letters or words. 1:1, 1024×1024.
```

### 1E. Aperture + leaf (photography forward)
```
macOS app icon: a camera aperture made of six rounded blades, where each blade is
shaped like a slender wheat leaf in gradient gold, slightly overlapping. In the
centre opening, a small glowing point of light. Deep teal rounded-square background
with soft vignette and gentle glass reflection. Elegant, simple, symmetric,
Apple-quality rendering, readable at small sizes. No text. 1:1, 1024×1024.
```

---

## 2. App icon: refinement follow-ups (use after picking a concept)

```
Keep this exact concept and composition, but simplify it for small sizes: fewer
elements, thicker shapes, stronger contrast between foreground and background.
```
```
Produce a dark-mode variant: same icon, background shifted to near-black charcoal
#22272B with the teal as an accent glow, foreground elements unchanged.
```
```
Produce a "tinted / monochrome" variant suitable for macOS tinted icons: the same
shapes in a single colour (white) on a transparent background, no gradients.
```
```
Render the same icon at 16×16 and 32×32 pixel-perfect sizes side by side so I can
judge legibility.
```

---

## 3. Logo & wordmark

### 3A. Horizontal lockup
```
A horizontal logo lockup for a Mac app called "Winnow": on the left, a compact
symbol of a single golden wheat stalk with two grains drifting away; on the right
the word "Winnow" in a clean, rounded geometric sans-serif (similar in spirit to
SF Pro Rounded), charcoal colour, generous letter spacing. White background, lots
of whitespace, vector-flat style, no tagline. Spell the word exactly: W-i-n-n-o-w.
Aspect ratio 4:1.
```

### 3B. Wordmark only
```
Wordmark logo: the single word "Winnow" set in a friendly, modern rounded sans-serif,
deep teal #1F6F6A on cream #F4EFE6. The dot-less design has one subtle detail: the
second "n" ends in a tiny wheat-grain shaped terminal in warm gold. Minimal, premium,
calm. Spell exactly W-i-n-n-o-w, no other text. Aspect ratio 3:1.
```

### 3C. Stacked lockup with tagline (for a README / About window)
```
A stacked logo: centred symbol of a golden wheat stalk whose grains become small
rounded photo frames, below it the word "Winnow" in a rounded sans-serif, and below
that a small tagline "Keep the best. Let the rest go." in a lighter weight. Teal and
gold on a soft cream background, flat vector style, balanced spacing. Spell all words
exactly as given. Aspect ratio 1:1.
```

---

## 4. Supporting artwork

### 4A. Toolbar / sidebar glyph (SF Symbols style)
```
A single monochrome line icon in the style of Apple SF Symbols: a wheat stalk with
three grains and one grain floating away, uniform 2-pt stroke weight, rounded caps,
black on white, no fill, no text. Designed on a 24×24 grid. 1:1.
```

### 4B. "Compress Videos" tool glyph
```
A monochrome SF Symbols-style line icon: a film frame (rounded rectangle with sprocket
dots) with two inward-pointing arrows on the left and right edges, suggesting the
video getting smaller. Uniform stroke, rounded caps, black on white, no text, 24×24
grid. 1:1.
```

### 4C. Empty-state illustration ("All groups reviewed")
```
A calm, minimal spot illustration for an app's empty state: a tidy stack of three
photo cards with a small golden checkmark, a few wheat grains resting beside them and
one light chaff flake drifting off the edge. Soft teal and gold palette on transparent
background, flat vector with gentle shadows, lots of breathing room. No text. 4:3.
```

### 4D. Hero banner (README / personal site)
```
A wide, soft hero illustration: a field of stylised golden wheat at golden hour,
where the wheat heads subtly turn into small floating photo frames that rise and
sort themselves into a neat row, while loose chaff blows gently away to the right.
Calm teal sky gradient, painterly-but-clean vector style, premium and serene.
No text. Aspect ratio 16:9.
```

---

## 5. Things to avoid (add to any prompt if Gemini drifts)

```
Avoid: trash cans, brooms, vacuum cleaners, lightning bolts, shields, padlocks,
red warning colours, cartoon mascots, photorealistic photos of people, stock-photo
look, busy backgrounds, gradients with more than three colours, any text or letters
unless explicitly requested, and any resemblance to existing apps' logos (especially
Apple Photos' flower or other photo-cleaner apps).
```
