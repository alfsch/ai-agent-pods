# Cover image

The cover image `assets/cover.jpeg` was made with Bing Image Creator from the prompt below. `docs/cover-image.webp`
is the file as Bing delivered it; the JPEG is converted from it, which is what the README shows. The picture of
copilot-pod was made the same way.

Reference look (copilot-pod): a black matte cylindrical base with a small light label, a clear glass dome, a glass
sphere inside with softly glowing eyes, dark charcoal background, a soft reflective floor, studio product shot.

## Prompt

> Studio product photograph of two identical minimalist desk gadgets side by side on a dark reflective surface, dark
> charcoal background with soft vignette. Each gadget has a black matte cylindrical base and a tall clear glass dome.
> Inside each dome floats a transparent glass sphere shaped like a head, with a delicate glowing artificial brain of
> fine luminous circuitry and neural filaments visible inside the sphere, and two large, soft, rounded glowing eyes with
> a gentle highlight, slightly tilted upward at the outer corners like a friendly smile, plus a tiny curved glowing
> smile below them, warm and approachable expression, cute and friendly character, not menacing. The left
> gadget: eyes and brain glow warm terracotta orange (#D97757). The right gadget: eyes and brain glow violet purple
> (#8534F3). The base of the left gadget has the small light-grey engraved text "claude-pod", the base of the right one
> "copilot-pod". Minimal, premium, symmetrical composition, centered, soft rim lighting, shallow depth of field, 3:2
> landscape, photorealistic render.

## Notes

- Colors: terracotta orange for Claude, purple for Copilot. copilot-pod's picture used blue; change the second color
  in the prompt to keep that.
- Generators often garble text. If the labels come out wrong, generate the picture without the label text and add
  the two labels afterwards.
- Friendlier eyes: a first picture with plain round glowing dots looked blank. The eye description above adds
  highlights, upturned corners and a small smile, which gave the current picture. If the eyes turn into cartoon faces over the brain, add "eyes
  embedded in the brain, no face outline"; if the brain disappears, add "the brain stays clearly visible".
- To make the spheres differ in shape as well, add: "left sphere with a rounder, friendlier face, right sphere with a
  more angular, technical look".

## Social preview

The picture GitHub shows when a link to the repository is shared is 1280×640 (2:1), a PNG, JPEG or GIF under 1 MB. It is
uploaded by hand (repository Settings, Social preview); GitHub has no API for it. Both files in `assets/` are made from
`docs/cover-image.webp`, which is 3:2, so they are not simply scaled. A 2:1 crop of the cover would leave about 30 px
around the pods, which sites that trim link cards (LinkedIn does) would cut, so the whole picture is kept:

- `assets/social-preview.png`: the picture only, scaled to 640 px high and centred, the sides filled with a blurred,
  darkened copy of the cover (Gaussian blur 40, brightness 0.85) and the edges of the picture feathered over 90 px.
- `assets/social-preview-title.png`: the same picture moved to the right, with the name and "Docker sandbox for AI coding
  agents" on the left (Inter Bold 60 px and Regular 30 px, and a bar in the two pod colours, #D97757 to #8534F3). It reads
  better as a small thumbnail, so upload this one. Its background is the cover's own left and right edge colours as a
  gradient: a blurred copy of the whole scene showed the pods' reflections as glows next to the text.

Both were made with Pillow in a pinned Python container (Inter from the Debian package `fonts-inter`, SIL Open Font
License). They are derived from the AI-generated cover, so the README's statement about that applies to them as well.
To change the text, redo the second file with the same sizes and keep the text clear of the left pod (it starts at about
x = 590).

## Replacing the image

Save the new picture as `docs/cover-image.webp` and convert it to `assets/cover.jpeg` (3:2, about 1250 px wide is
enough; keep the names, or change the link in the README). Redo the two social previews from the new picture as well. The README's license section says that the image was generated with AI; keep that line.
