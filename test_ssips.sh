#!/bin/bash
# test_ssips.sh – unit/integration tests for ssips
#
# Uses a Python-based mock "sips" so tests run on any OS with Python 3.
# The mock handles the same two call patterns that ssips uses:
#   sips -g pixelWidth -g pixelHeight <file>
#   sips -c <h> <w> --cropOffset <oH> <oW> <file> [--out <out>]
#
# Pre-built PNG fixtures live in the tests/ directory next to this script.

set -euo pipefail

SSIPS="$(cd "$(dirname "$0")" && pwd)/ssips"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)/tests"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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
    ! "$SSIPS" "not_a_geometry" "$TESTS_DIR/bicolor_50x100.png" \
        --out "$WORK/dummy_out.png" 2>/dev/null
}
run "bad_geometry_exits_nonzero" test_bad_geometry

# 4. Exit non-zero when the crop region is entirely outside the image
test_out_of_bounds() {
    ! "$SSIPS" "10x10+200+200" "$TESTS_DIR/bicolor_50x100.png" \
        --out "$WORK/oob_out.png" 2>/dev/null
}
run "out_of_bounds_exits_nonzero" test_out_of_bounds

# 5. Crop the white top half from the bicolor fixture
#    Source : tests/bicolor_50x100.png (50×100, rows 0–49 white, rows 50–99 black)
#    Crop   : 50×50+0+0  (top-left 50×50 region)
#    Expect : byte-for-byte identical to tests/white_50x50.png
test_crop_white_top_half() {
    "$SSIPS" "50x50+0+0" "$TESTS_DIR/bicolor_50x100.png" \
        --out "$WORK/cropped_white.png" 2>/dev/null
    cmp "$WORK/cropped_white.png" "$TESTS_DIR/white_50x50.png"
}
run "crop_top_half_matches_white_reference" test_crop_white_top_half

# 6. Crop the black bottom half from the bicolor fixture
#    Source : tests/bicolor_50x100.png
#    Crop   : 50×50+0+50  (bottom 50×50 region)
#    Expect : byte-for-byte identical to tests/black_50x50.png
test_crop_black_bottom_half() {
    "$SSIPS" "50x50+0+50" "$TESTS_DIR/bicolor_50x100.png" \
        --out "$WORK/cropped_black.png" 2>/dev/null
    cmp "$WORK/cropped_black.png" "$TESTS_DIR/black_50x50.png"
}
run "crop_bottom_half_matches_black_reference" test_crop_black_bottom_half

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
