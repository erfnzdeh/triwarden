#!/bin/bash
# Measures how fast Triwarden starts, how little memory it holds, and how long an unlock takes, and writes the
# results to docs/benchmarks.md. `make bench` runs it; `make bench RUNS=10` takes more samples.
#
#   scripts/bench.sh [--runs N] [--idle SECONDS] [--no-build] [--interactive N] [--out FILE]
#
# What it measures (all with the 200-item demo vault, `--demo-full`; nothing touches your saved accounts):
#   • launch to first frame   — kernel process start → the window's first frame committed (Core Animation)
#   • launch to vault ready   — process start → the item list's first frame with items in it
#   • memory at idle          — phys_footprint (Activity Monitor's "Memory") after sitting idle, via footprint(1)
#   • master-password unlock  — derive key, stretch, decrypt the user key, for Bitwarden's default PBKDF2 and Argon2id
# Each launch is a fresh process (macOS keeps the binary in the file cache, so this is a "warm" cold start: the
# usual case when you open an app). The app prints its own timing marks when TRIWARDEN_BENCH=1 (App/Sources/Bench.swift).
#
# --interactive N also times N real unlocks (Touch ID or master password) on this Mac's own accounts: the app opens
# normally, you lock (⇧⌘L or the lock button) and unlock N times, and the script reads the app's marks.
#
# Build: the Release configuration used for shipping, with DEBUG enabled only to compile the isolated demo fixtures,
# in its own folder, build/bench. --no-build reuses it. Release optimisation settings come from project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=5
IDLE=10
BUILD=1
INTERACTIVE=0
OUT=docs/benchmarks.md
while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS=$2; shift 2 ;;
        --idle) IDLE=$2; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --interactive) INTERACTIVE=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 64 ;;
    esac
done

APP=build/bench/Build/Products/Release/Triwarden.app
BIN=$APP/Contents/MacOS/Triwarden
if [ "$BUILD" = 1 ]; then
    echo "Building (Release with isolated benchmark fixtures) into build/bench…"
    xcodegen generate -q
    xcodebuild -project Triwarden.xcodeproj -scheme Triwarden -configuration Release -derivedDataPath build/bench \
        -allowProvisioningUpdates ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG build 2>&1 \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
fi
test -x "$BIN" || { echo "No build at $BIN" >&2; exit 1; }
if pgrep -fq "$BIN"; then echo "Quit the bench build of Triwarden first." >&2; exit 1; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The value of mark $2 in log $1, or empty.
mark() { awk -v m="$2" '$1 == "BENCH" && $2 == m { print $3; exit }' "$1"; }
# median / min / max of numbers on stdin
stats() { sort -n | awk '{ v[NR] = $1 } END { if (NR == 0) { print "– – –"; exit } m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2; printf "%.0f %.0f %.0f\n", m, v[1], v[NR] }'; }

: > "$TMP/first"; : > "$TMP/ready"; : > "$TMP/mem"
for i in $(seq 1 "$RUNS"); do
    log=$TMP/run$i.log
    TRIWARDEN_BENCH=1 "$BIN" --demo-full 2> "$log" > /dev/null &
    pid=$!
    for _ in $(seq 1 300); do # up to 30 s
        [ -n "$(mark "$log" vault-ready)" ] && break
        sleep 0.1
    done
    first=$(mark "$log" first-frame); ready=$(mark "$log" vault-ready)
    if [ -z "$ready" ]; then echo "run $i: the vault never came up:" >&2; tail -20 "$log" >&2; kill "$pid" 2>/dev/null; exit 1; fi
    echo "$first" >> "$TMP/first"; echo "$ready" >> "$TMP/ready"
    # Icon loading and framework caches settle at slightly different times. Sample every run rather than trusting
    # the first launch, and store MiB so the same stats helper can report a median and range.
    sleep "$IDLE"
    footprint -p "$pid" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") {
        v = $(i+1); u = $(i+2); if (u == "KB") v /= 1024; if (u == "GB") v *= 1024; print v; exit
    } }' >> "$TMP/mem"
    kill "$pid"; wait "$pid" 2>/dev/null || true
    printf "run %d: first frame %s ms, vault ready %s ms\n" "$i" "$first" "$ready"
    sleep 1
done
read -r first_med first_min first_max < <(stats < "$TMP/first")
read -r ready_med ready_min ready_max < <(stats < "$TMP/ready")
read -r mem_med mem_min mem_max < <(stats < "$TMP/mem")
echo "memory at idle: ${mem_med} MB (${mem_min}–${mem_max} MB)"

echo "Timing master-password unlocks…"
"$BIN" --bench-unlock 2>/dev/null > "$TMP/unlock"
pbkdf2=$(awk '$2 == "unlock-pbkdf2-600k" { printf "%.0f", $3 }' "$TMP/unlock")
argon=$(awk '$2 == "unlock-argon2id-64m-3-4" { printf "%.0f", $3 }' "$TMP/unlock")
echo "PBKDF2 ${pbkdf2} ms, Argon2id ${argon} ms"

touch_rows=""
if [ "$INTERACTIVE" -gt 0 ]; then
    log=$TMP/interactive.log
    echo "Opening Triwarden with your own accounts. Lock and unlock it $INTERACTIVE times (Touch ID or password)."
    TRIWARDEN_BENCH=1 "$BIN" 2> "$log" > /dev/null &
    pid=$!
    while [ "$(grep -cE 'BENCH unlock-(touchid|password)-open' "$log" || true)" -lt "$INTERACTIVE" ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    for kind in touchid password; do
        n=$(awk -v m="unlock-$kind-open" '$2 == m' "$log" | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] || continue
        read -r med min max < <(awk -v m="unlock-$kind-open" '$2 == m { print $3 }' "$log" | stats)
        label=$([ $kind = touchid ] && echo "Touch ID unlock: approved → vault on screen" || echo "Master-password unlock: Return → vault on screen")
        touch_rows+="| $label | $med ms | $min–$max ms | $n unlocks, this Mac's accounts (includes the unlock animation unless Reduce Motion is on) |"$'\n'
    done
fi

chip=$(sysctl -n machdep.cpu.brand_string)
model=$(sysctl -n hw.model)
ram=$(( $(sysctl -n hw.memsize) / 1073741824 ))
os=$(sw_vers -productVersion)
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
commit=$(git rev-parse --short HEAD)

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
# Benchmarks

How quickly Triwarden opens, how little memory it keeps, and how long an unlock takes, measured on one Mac by
\`make bench\` (\`scripts/bench.sh\`). Re-run it on yours: numbers depend on the machine, and on what else it's doing.

## Triwarden $version ($commit)

$(date +%Y-%m-%d) · $chip ($model), ${ram} GB · macOS $os · Release configuration with isolated benchmark fixtures · demo vault of 200+ items

| Measure | Median | Range | Notes |
| --- | ---: | ---: | --- |
| Launch to first frame | $first_med ms | ${first_min}–${first_max} ms | $RUNS fresh launches; from the kernel starting the process |
| Launch to vault ready | $ready_med ms | ${ready_min}–${ready_max} ms | the item list on screen with items in it |
| Memory at idle | ${mem_med} MB | ${mem_min}–${mem_max} MB | phys_footprint (Activity Monitor's “Memory”) after ${IDLE} s idle, vault open; $RUNS fresh launches |
| Master-password unlock, PBKDF2 600,000 | $pbkdf2 ms | | key derivation + user key decryption, median of 5 |
| Master-password unlock, Argon2id 64 MiB · 3 · 4 | $argon ms | | Bitwarden's default Argon2id settings, median of 5 |
${touch_rows}
Touch ID can't be timed without a finger: \`scripts/bench.sh --interactive 5\` opens the app on your own accounts and
times five real unlocks (from the moment Touch ID approves, or Return is pressed, to the vault on screen).

## Measuring the Bitwarden desktop app by hand

We can't script someone else's app, so these steps give comparable numbers by hand. Use the same Mac, quit other
apps, and take the median of five tries. Please don't publish numbers you didn't measure.

1. **Launch to window.** Quit Bitwarden (⌘Q). Start a screen recording (⇧⌘5), click Bitwarden in the Dock, and
   count frames from the click to the window's first frame (QuickTime Player steps a frame at a time with ← →).
   Do the same for Triwarden for a like-for-like number.
2. **Launch to vault ready.** With the vault unlocked at quit (or "Never lock"), count frames until the item list is
   filled.
3. **Memory at idle.** Unlock, leave it 10 seconds, then add up every Bitwarden process — Electron runs a main
   process, a GPU process and one or more renderers:
   \`\`\`bash
   for p in \$(pgrep -f Bitwarden); do footprint -p \$p | awk '/Footprint:/'; done
   \`\`\`
   Activity Monitor's Memory column shows the same figure per process; sum the Bitwarden ones.
4. **Unlock.** Lock the vault, then time from pressing Return on the master password (or touching the sensor) to the vault
   on screen, again by counting video frames. Note the account's KDF (Settings › Security › Keys in the web vault):
   PBKDF2 and Argon2id take very different times, in any app.

Record the app version, the Mac and macOS version with your numbers.
EOF
echo "Wrote $OUT"
