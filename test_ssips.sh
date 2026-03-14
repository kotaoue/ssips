#!/bin/bash
# test_ssips.sh – unit/integration tests for ssips
#
# Uses a Python-based mock "sips" so tests run on any OS with Python 3.
# The mock handles the same two call patterns that ssips uses:
#   sips -g pixelWidth -g pixelHeight <file>
#   sips -c <h> <w> --cropOffset <oH> <oW> <file> [--out <out>]

set -euo pipefail

SSIPS="$(cd "$(dirname "$0")" && pwd)/ssips"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# PNG helpers (Python stdlib only – no Pillow required)
# ---------------------------------------------------------------------------

# make_png <width> <height> <r> <g> <b> <outfile>
make_png() {
    python3 - "$@" <<'PY'
import sys, struct, zlib
w, h, r, g, b, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
def ck(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
raw = b''.join(b'\x00' + bytes([r, g, b]) * w for _ in range(h))
with open(out, 'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n'
            + ck(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + ck(b'IDAT', zlib.compress(raw))
            + ck(b'IEND', b''))
PY
}

# make_bicolor_png <outfile>
# Creates a 50×100 PNG: rows 0–49 solid white, rows 50–99 solid black.
make_bicolor_png() {
    python3 - "$1" <<'PY'
import sys, struct, zlib
out = sys.argv[1]
w, h = 50, 100
def ck(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
raw = b''
for y in range(h):
    raw += b'\x00'
    raw += bytes((255, 255, 255) if y < 50 else (0, 0, 0)) * w
with open(out, 'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n'
            + ck(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + ck(b'IDAT', zlib.compress(raw))
            + ck(b'IEND', b''))
PY
}

# get_png_dims <file>  → prints "<W>x<H>"
get_png_dims() {
    python3 - "$1" <<'PY'
import sys, struct
with open(sys.argv[1], 'rb') as f:
    f.read(8)        # PNG signature
    f.read(4)        # IHDR length
    f.read(4)        # "IHDR"
    w = struct.unpack('>I', f.read(4))[0]
    h = struct.unpack('>I', f.read(4))[0]
print(f"{w}x{h}")
PY
}

# check_all_pixels <file> <r> <g> <b>  → exits 0 if every pixel matches
check_all_pixels() {
    python3 - "$@" <<'PY'
import sys, struct, zlib
path, r2, g2, b2 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
with open(path, 'rb') as f:
    data = f.read()
pos, w, h, idat = 8, 0, 0, b''
while pos < len(data):
    n = struct.unpack('>I', data[pos:pos+4])[0]
    t = data[pos+4:pos+8]
    d = data[pos+8:pos+8+n]
    pos += 12 + n
    if t == b'IHDR':
        w, h = struct.unpack('>II', d[:8])
    elif t == b'IDAT':
        idat += d
    elif t == b'IEND':
        break
raw = zlib.decompress(idat)
stride = w * 3 + 1
for y in range(h):
    for x in range(w):
        off = y * stride + 1 + x * 3
        r, g, b = raw[off], raw[off+1], raw[off+2]
        if (r, g, b) != (r2, g2, b2):
            print(f"MISMATCH at ({x},{y}): got ({r},{g},{b}), expected ({r2},{g2},{b2})")
            sys.exit(1)
PY
}

# pixels_equal <file1> <file2>  → exits 0 if identical pixel-by-pixel
pixels_equal() {
    python3 - "$@" <<'PY'
import sys, struct, zlib
def read_pixels(path):
    with open(path, 'rb') as f:
        data = f.read()
    pos, w, h, idat = 8, 0, 0, b''
    while pos < len(data):
        n = struct.unpack('>I', data[pos:pos+4])[0]
        t = data[pos+4:pos+8]
        d = data[pos+8:pos+8+n]
        pos += 12 + n
        if t == b'IHDR':
            w, h = struct.unpack('>II', d[:8])
        elif t == b'IDAT':
            idat += d
    raw = zlib.decompress(idat)
    stride = w * 3 + 1
    pixels = [(raw[y*stride+1+x*3], raw[y*stride+1+x*3+1], raw[y*stride+1+x*3+2])
              for y in range(h) for x in range(w)]
    return w, h, pixels
w1, h1, p1 = read_pixels(sys.argv[1])
w2, h2, p2 = read_pixels(sys.argv[2])
if (w1, h1) != (w2, h2):
    print(f"Size mismatch: {w1}x{h1} vs {w2}x{h2}")
    sys.exit(1)
bad = [(i, a, b) for i, (a, b) in enumerate(zip(p1, p2)) if a != b]
if bad:
    print(f"{len(bad)} pixel(s) differ")
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# Mock sips
# ---------------------------------------------------------------------------
# Handles the two call forms ssips uses:
#   -g pixelWidth -g pixelHeight <file>
#   -c <h> <w> --cropOffset <oH> <oW> <file> [--out <out>]
#
# cropOffset → start coordinates:
#   ssips emits (1,1) when the requested origin is (0,0); for all other
#   origins offset_w == crop_x and offset_h == crop_y.
#   The mock therefore maps (oW=1, oH=1) → start (0,0) and all other
#   (oW, oH) → start (oW, oH), mirroring ssips's intent.

cat > "$WORK/sips" << 'MOCK_SIPS'
#!/usr/bin/env python3
import sys, struct, zlib

def read_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    pos, w, h, idat = 8, 0, 0, b''
    while pos < len(data):
        n = struct.unpack('>I', data[pos:pos+4])[0]
        t = data[pos+4:pos+8]
        d = data[pos+8:pos+8+n]
        pos += 12 + n
        if t == b'IHDR':
            w, h = struct.unpack('>II', d[:8])
        elif t == b'IDAT':
            idat += d
        elif t == b'IEND':
            break
    raw = zlib.decompress(idat)
    stride = w * 3 + 1
    pixels = [[(raw[y*stride+1+x*3], raw[y*stride+1+x*3+1], raw[y*stride+1+x*3+2])
               for x in range(w)] for y in range(h)]
    return w, h, pixels

def write_png(path, pixels):
    h = len(pixels)
    w = len(pixels[0]) if h else 0
    def ck(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b''.join(b'\x00' + b''.join(bytes(p) for p in row) for row in pixels)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n'
                + ck(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + ck(b'IDAT', zlib.compress(raw))
                + ck(b'IEND', b''))

args = sys.argv[1:]

if '-g' in args:
    i, img = 0, None
    while i < len(args):
        if args[i] == '-g':
            i += 2
        else:
            img = args[i]
            i += 1
    w, h, _ = read_png(img)
    print(img + ':')
    if 'pixelWidth' in args:
        print('  pixelWidth: ' + str(w))
    if 'pixelHeight' in args:
        print('  pixelHeight: ' + str(h))
    sys.exit(0)

if '-c' in args:
    i = 0
    crop_h = crop_w = offset_h = offset_w = 0
    img = out = None
    while i < len(args):
        if args[i] == '-c':
            crop_h, crop_w = int(args[i+1]), int(args[i+2])
            i += 3
        elif args[i] == '--cropOffset':
            offset_h, offset_w = int(args[i+1]), int(args[i+2])
            i += 3
        elif args[i] == '--out':
            out = args[i+1]
            i += 2
        elif not args[i].startswith('-'):
            img = args[i]
            i += 1
        else:
            i += 1
    if out is None:
        out = img
    _, _, pixels = read_png(img)
    # ssips uses (1,1) to represent the top-left origin (0,0); all other
    # offset values equal the requested crop_x / crop_y directly.
    if offset_w == 1 and offset_h == 1:
        start_x, start_y = 0, 0
    else:
        start_x, start_y = offset_w, offset_h
    cropped = [pixels[y][start_x:start_x + crop_w]
               for y in range(start_y, start_y + crop_h)]
    write_png(out, cropped)
    sys.exit(0)
MOCK_SIPS
chmod +x "$WORK/sips"
export PATH="$WORK:$PATH"

# ---------------------------------------------------------------------------
# Tiny test runner
# ---------------------------------------------------------------------------
ok()   { echo "ok:   $1"; (( PASS++ )) || true; }
fail() { echo "FAIL: $1"; (( FAIL++ )) || true; }

run() {
    local name="$1"; shift
    if "$@"; then
        ok "$name"
    else
        fail "$name"
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# 1. Exit non-zero when called with no arguments
test_no_args() { ! "$SSIPS" 2>/dev/null; }
run "no_args_exits_nonzero" test_no_args

# 2. Exit non-zero when called with only one argument
test_one_arg() { ! "$SSIPS" "50x50+0+0" 2>/dev/null; }
run "one_arg_exits_nonzero" test_one_arg

# 3. Exit non-zero for an invalid geometry string
test_bad_geometry() {
    make_png 50 100 255 255 255 "$WORK/dummy.png"
    ! "$SSIPS" "not_a_geometry" "$WORK/dummy.png" --out "$WORK/dummy_out.png" 2>/dev/null
}
run "bad_geometry_exits_nonzero" test_bad_geometry

# 4. Exit non-zero when the crop region is entirely outside the image
test_out_of_bounds() {
    make_png 50 100 255 255 255 "$WORK/small.png"
    ! "$SSIPS" "10x10+200+200" "$WORK/small.png" --out "$WORK/oob_out.png" 2>/dev/null
}
run "out_of_bounds_exits_nonzero" test_out_of_bounds

# 5. Crop the white top half from a bicolor image
#    Source : 50×100, rows 0–49 white, rows 50–99 black
#    Crop   : 50×50+0+0  (top-left 50×50 region)
#    Expect : 50×50, all white
test_crop_white_top_half() {
    make_bicolor_png "$WORK/bicolor.png"
    "$SSIPS" "50x50+0+0" "$WORK/bicolor.png" --out "$WORK/cropped_white.png" 2>/dev/null
    local dims
    dims=$(get_png_dims "$WORK/cropped_white.png")
    [[ "$dims" == "50x50" ]] || { echo "  Expected 50x50, got $dims" >&2; return 1; }
    check_all_pixels "$WORK/cropped_white.png" 255 255 255
}
run "crop_top_half_is_white" test_crop_white_top_half

# 6. Crop the black bottom half from a bicolor image
#    Source : 50×100, rows 0–49 white, rows 50–99 black
#    Crop   : 50×50+0+50  (bottom 50×50 region)
#    Expect : 50×50, all black
test_crop_black_bottom_half() {
    make_bicolor_png "$WORK/bicolor2.png"
    "$SSIPS" "50x50+0+50" "$WORK/bicolor2.png" --out "$WORK/cropped_black.png" 2>/dev/null
    local dims
    dims=$(get_png_dims "$WORK/cropped_black.png")
    [[ "$dims" == "50x50" ]] || { echo "  Expected 50x50, got $dims" >&2; return 1; }
    check_all_pixels "$WORK/cropped_black.png" 0 0 0
}
run "crop_bottom_half_is_black" test_crop_black_bottom_half

# 7. Crop result matches a separately-constructed reference image
#    Reference: a plain 50×50 white PNG built independently.
test_crop_matches_reference() {
    make_bicolor_png "$WORK/src.png"
    make_png 50 50 255 255 255 "$WORK/ref_white.png"
    "$SSIPS" "50x50+0+0" "$WORK/src.png" --out "$WORK/result.png" 2>/dev/null
    pixels_equal "$WORK/result.png" "$WORK/ref_white.png"
}
run "crop_result_matches_reference_image" test_crop_matches_reference

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
