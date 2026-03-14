# ssips

A macOS `sips` wrapper that supports ImageMagick-style crop geometry.

## Usage

```text
ssips <WxH+X+Y> <input> [--out <output>]

  WxH+X+Y  crop geometry (width x height + left + top)
  input    path to the input image
  --out    optional output path (default: overwrites input, same as sips)
```

```bash
ssips 200x200+100+50 photo.jpg --out cropped.jpg
```

## Motivation

Cropping with `sips` requires an awkward `--cropOffset` value measured from the image center, e.g.:

```bash
sips -c 240 480 --cropOffset -420 -720 input.jpg --out output.jpg
```

`ssips` lets you specify the crop region the natural way — top-left origin, width, and height:

```bash
ssips 480x240+0+0 input.jpg --out output.jpg
# equivalent to: sips -c 240 480 --cropOffset -420 -720 input.jpg --out output.jpg
```

## Requirements

- macOS (uses the built-in `sips` command)
