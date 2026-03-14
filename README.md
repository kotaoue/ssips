# ssips

A macOS `sips` wrapper that supports ImageMagick-style crop geometry.

## Motivation

Cropping with `sips` requires an awkward `--cropOffset` value measured from the image center, e.g.:

```bash
sips -c 240 480 --cropOffset -420 -720 input.jpg --out output.jpg
```

`ssips` lets you specify the crop region the natural way — top-left origin, width, and height:

```
ssips WxH+X+Y input [--out output]
```

## Usage

```
ssips <WxH+X+Y> <input> [--out <output>]

  WxH+X+Y  crop geometry (width x height + left + top)
  input    path to the input image
  --out    optional output path (default: overwrites input, same as sips)
```

## Examples

Crop a 480×240 region from the top-left corner of a 1920×1080 image:

```bash
ssips 480x240+0+0 input.jpg --out output.jpg
# equivalent to: sips -c 240 480 --cropOffset -420 -720 input.jpg --out output.jpg
```

Crop a 200×200 region starting at (100, 50):

```bash
ssips 200x200+100+50 photo.jpg --out cropped.jpg
```

## Requirements

- macOS (uses the built-in `sips` command)
