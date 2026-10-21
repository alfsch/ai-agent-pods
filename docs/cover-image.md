# Cover image

The README has no cover image yet. The one of copilot-pod was made with Bing Image Creator; this is the prompt for
the picture of both pods, and how to add the result.

Reference look (copilot-pod): a black matte cylindrical base with a small light label, a clear glass dome, a glass
sphere inside with softly glowing eyes, dark charcoal background, a soft reflective floor, studio product shot.

## Prompt

> Studio product photograph of two identical minimalist desk gadgets side by side on a dark reflective surface, dark
> charcoal background with soft vignette. Each gadget has a black matte cylindrical base and a tall clear glass dome.
> Inside each dome floats a transparent glass sphere shaped like a head, with a delicate glowing artificial brain of
> fine luminous circuitry and neural filaments visible inside the sphere, and two softly glowing round eyes. The left
> gadget: eyes and brain glow warm terracotta orange (#D97757). The right gadget: eyes and brain glow violet purple
> (#8534F3). The base of the left gadget has the small light-grey engraved text "claude-pod", the base of the right one
> "copilot-pod". Minimal, premium, symmetrical composition, centered, soft rim lighting, shallow depth of field, 3:2
> landscape, photorealistic render.

## Notes

- Colors: terracotta orange for Claude, purple for Copilot. copilot-pod's picture used blue; change the second color
  in the prompt to keep that.
- Generators often garble text. If the labels come out wrong, generate the picture without the label text and add
  the two labels afterwards.
- To make the spheres differ in shape as well, add: "left sphere with a rounder, friendlier face, right sphere with a
  more angular, technical look".

## Adding the result

1. Save it as `assets/cover.jpeg` (3:2, about 1250 px wide is enough).
2. Put `![claude-pod and copilot-pod](assets/cover.jpeg)` below the title line of `README.md`.
3. In the README's license section, say that the cover image was generated with AI (Microsoft Bing Image Creator).
