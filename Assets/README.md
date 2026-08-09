# Brand assets

| File | Use |
|---|---|
| `aria-lockup-{light,dark}.svg` | README header, docs, slides |
| `aria-mark-{light,dark}.svg` | Avatar, app icon, anywhere ≥ 24 px |
| `aria-mark-solid.svg` | Favicons, 16 px, one-ink print |
| `aria-wordmark-*.svg` | Text-only contexts |
| `aria-{mark,wordmark,lockup}.svg` | `currentColor` — inherits from CSS |
| `social-preview.png` | GitHub Settings → Social preview (1280×640) |
| `social-preview.svg` | Source for the above |

Three squircles stepping inward on even gaps, the outer two held at 38%
and 68% so attention converges on the filled centre. The concentric
frames are the product: a large surface reduced until it fits a small
window.

**Pick the right file for the surface.** The `currentColor` variants
inherit their colour from CSS, which is what you want inside an app or a
docs site — and exactly what fails on GitHub, where README images render
as `<img>` and resolve to black on every theme. Use the explicit
`-light` / `-dark` pair with `<picture>` there.

**The graduation is the one part that does not travel.** It carries the
concept, but at 16 px the outer ring falls under a pixel and a single
ink cannot express 38% at all. `aria-mark-solid.svg` is that fallback,
and it is a fallback rather than a replacement — prefer the graduated
mark wherever opacity survives.


## Social preview

Upload `social-preview.png` by hand at **Settings → Social preview**;
GitHub exposes no API or `gh` command for it.

Regenerate after editing the source:

```sh
rsvg-convert -w 1280 -h 640 Assets/social-preview.svg -o Assets/social-preview.png
```

**Use `rsvg-convert`, not `qlmanage`.** The macOS Quick Look renderer
pads the output to a square canvas and rescales, which silently yields a
cropped, zoomed image at the wrong aspect ratio.

The headline is set at 56px because these cards render around 500px wide
in most feeds — sized for the thumbnail rather than for the file.

**The PNG is the artifact, not a build output.** The source sets type in
the system font stack, so it renders differently on a machine without
those faces. Commit a regenerated PNG alongside any source edit rather
than assuming the SVG reproduces it.
