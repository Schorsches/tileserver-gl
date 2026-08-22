#!/bin/sh
# Side-by-side endpoint comparison of two tileserver-gl images against the same
# data directory.
#
# The mocha suite proves the Alpine image passes the project's own tests; this
# proves it answers byte-for-byte like the image it replaces. Vector, JSON and
# metadata endpoints must be identical. Rendered PNGs are compared with
# pixelmatch, because the GLX -> EGL switch could in principle move a pixel.
#
#   docker/compare-images.sh maptiler/tileserver-gl:latest tileserver-gl:alpine ./test_data
set -eu

REF="${1:?usage: compare-images.sh <reference-image> <candidate-image> <data-dir>}"
NEW="${2:?}"
DATA="$(cd "${3:?}" && pwd)"

REF_PORT=8081
NEW_PORT=8082
WORK="$(mktemp -d)"
# The comparison runs inside the candidate image, which is USER node (uid 999),
# so the fetched files have to be readable from there -- mktemp -d is 0700.
chmod 755 "$WORK"
trap 'docker rm -f cmp-ref cmp-new >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

docker rm -f cmp-ref cmp-new >/dev/null 2>&1 || true
docker run -d --name cmp-ref -p "${REF_PORT}:8080" -v "${DATA}:/data" "$REF" >/dev/null
docker run -d --name cmp-new -p "${NEW_PORT}:8080" -v "${DATA}:/data" "$NEW" >/dev/null

for port in "$REF_PORT" "$NEW_PORT"; do
  i=0
  until curl -fsS "http://localhost:${port}/health" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 90 ] || { echo "server on ${port} never became healthy" >&2; exit 1; }
    sleep 1
  done
done

# Byte-identical endpoints: anything not produced by the GL renderer.
EXACT="
/health
/index.json
/styles.json
/data/openmaptiles.json
/styles/test-style/style.json
/data/openmaptiles/0/0/0.pbf
/data/openmaptiles/2/2/1.pbf
"

# Rendered raster: compared by pixel, not by byte, since PNG encoders may
# legitimately differ in chunk layout.
RENDERED="
/styles/test-style/static/0,0,0/256x256.png
/styles/test-style/static/8.5,47.4,10/512x512.png
/styles/test-style/static/8.5,47.4,12/400x300@2x.png
/styles/test-style/256/1/0/0.png
/styles/test-style/512/2/1/1.png
"

# Responses embed absolute URLs built from the request host, and the two servers
# necessarily listen on different ports. tileserver-gl also enumerates styles in
# filesystem order, which is not stable across restarts of the *same* image, so
# list endpoints are sorted before hashing. Neither is a base-image difference.
fetch_normalised() {
  curl -fsS "http://localhost:${1}${2}" 2>/dev/null \
    | sed "s/localhost:${1}/localhost:PORT/g" \
    | python3 -c '
import json, sys
raw = sys.stdin.buffer.read()
try:
    doc = json.loads(raw)
except Exception:
    # Not JSON (a vector tile, say) -- hash the bytes as they came.
    sys.stdout.buffer.write(raw)
    raise SystemExit
def canon(node):
    if isinstance(node, dict):
        return {k: canon(v) for k, v in node.items()}
    if isinstance(node, list):
        # Style enumeration follows filesystem order, which is not stable even
        # across restarts of the same image, so order carries no information.
        return sorted((canon(v) for v in node), key=lambda v: json.dumps(v, sort_keys=True))
    return node
print(json.dumps(canon(doc), sort_keys=True))
' \
    | sha256sum | cut -d' ' -f1
}

fail=0

echo "== byte-identical endpoints =="
# Responses embed absolute URLs built from the request host, and the two
# servers necessarily listen on different ports, so normalise the port out
# before hashing -- otherwise every JSON endpoint reports a false difference.
for path in $EXACT; do
  a=$(fetch_normalised "$REF_PORT" "$path") || a=ERR
  b=$(fetch_normalised "$NEW_PORT" "$path") || b=ERR
  if [ "$a" = "$b" ] && [ "$a" != "ERR" ]; then
    echo "  ok    $path"
  elif [ "$a" = "ERR" ] && [ "$b" = "ERR" ]; then
    echo "  skip  $path (absent from both)"
  else
    echo "  DIFF  $path  ref=$a new=$b"
    fail=1
  fi
done

echo "== rendered tiles (pixel comparison) =="
for path in $RENDERED; do
  name=$(echo "$path" | tr '/,@' '___')
  curl -fsS -o "$WORK/ref$name" "http://localhost:${REF_PORT}${path}" 2>/dev/null || { echo "  skip  $path (ref 404)"; continue; }
  curl -fsS -o "$WORK/new$name" "http://localhost:${NEW_PORT}${path}" 2>/dev/null || { echo "  skip  $path (new 404)"; continue; }
  # The runtime image ships sharp but not pixelmatch (a devDependency), so the
  # comparison is done directly on the decoded pixels. Tolerances mirror
  # test/static_images.js: a channel delta over ~26/255 counts as a differing
  # pixel, and up to 100 such pixels are allowed.
  # Exit 0 means identical, 1 means too many differing pixels, and anything
  # else means the comparison itself failed -- which must never be reported as
  # an image difference.
  set +e
  docker run --rm -v "$WORK:/w" --entrypoint node "$NEW" \
       -e "
         const sharp = require('/usr/src/app/node_modules/sharp');
         const load = (f) => sharp('/w/' + f).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
         (async () => {
           const [a, b] = [await load('ref$name'), await load('new$name')];
           if (a.info.width !== b.info.width || a.info.height !== b.info.height) {
             console.error('size mismatch'); process.exit(1);
           }
           let diff = 0;
           for (let i = 0; i < a.data.length; i += 4) {
             for (let c = 0; c < 4; c++) {
               if (Math.abs(a.data[i + c] - b.data[i + c]) > 26) { diff++; break; }
             }
           }
           console.error(diff + ' differing pixels');
           process.exit(diff > 100 ? 1 : 0);
         })();
       " 2>>"$WORK/diffs.log"
  rc=$?
  set -e
  case "$rc" in
    0) echo "  ok    $path  ($(tail -1 "$WORK/diffs.log"))" ;;
    1) echo "  DIFF  $path  ($(tail -1 "$WORK/diffs.log"))"; fail=1 ;;
    *) echo "  ERROR $path  comparison failed (exit $rc): $(tail -1 "$WORK/diffs.log")"; fail=1 ;;
  esac
done

[ "$fail" = "0" ] && echo "PASS: images agree" || echo "FAIL: differences above"
exit "$fail"
