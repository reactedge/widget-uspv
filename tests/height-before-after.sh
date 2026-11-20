#!/usr/bin/env bash
# Compare USPV slide clipping before and after the min-height fix.
#
# Usage (from the platform root):
#   widgets/uspv/tests/height-before-after.sh [before-ref]
#
#   before-ref  Git ref whose uspv.item.css is used for the "before" run.
#               Defaults to e981dc5 (fixed `height: 45px`).
#
# Environment:
#   PW_CONFIG   Playwright config (default: tests/playwright.dev.config.ts).
#
# The "after" run uses the working tree. For the "before" run the script
# temporarily writes the CSS file from <before-ref>, then always restores
# the working-tree file. Results (JSON + screenshots) and a side-by-side
# report.html are written to test-results/uspv-height/.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
BEFORE_REF="${1:-e981dc5}"
CSS="widgets/uspv/src/styles/uspv.item.css"
SPEC="widgets/uspv/tests/uspv.height.spec.ts"
PW_CONFIG="${PW_CONFIG:-tests/playwright.dev.config.ts}"
OUT="$ROOT/test-results/uspv-height"

cd "$ROOT"

BEFORE_CSS="$(git show "$BEFORE_REF:./$CSS")"
BACKUP="$(mktemp)"
cp "$CSS" "$BACKUP"

rm -rf "$OUT"
mkdir -p "$OUT"

(cd widgets/uspv && setsid npm run dev -- --port 5173 --strictPort > "$OUT/vite.log" 2>&1) &
DEV_PID=$!

cleanup() {
    cp "$BACKUP" "$CSS"
    rm -f "$BACKUP"
    kill -- -"$DEV_PID" 2>/dev/null || kill "$DEV_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
    curl -s -o /dev/null http://localhost:5173/ && break
    sleep 0.5
done

run() {
    local label="$1"
    echo "== Running '$label'"
    USPV_HEIGHT_LABEL="$label" USPV_HEIGHT_OUT="$OUT" \
        ./node_modules/.bin/playwright test --config="$PW_CONFIG" "$SPEC" \
        --reporter=line > "$OUT/$label.log" 2>&1 \
        && echo "   all scenarios pass" \
        || echo "   some scenarios fail (see $OUT/$label.log)"
}

run after

printf '%s\n' "$BEFORE_CSS" > "$CSS"
sleep 1
run before

cp "$BACKUP" "$CSS"

node --input-type=module - "$OUT" <<'EOF'
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const out = process.argv[2];
const results = readdirSync(out)
    .filter((file) => file.endsWith(".json"))
    .map((file) => JSON.parse(readFileSync(join(out, file), "utf8")));

const key = (r) => `${r.contract} @ ${r.scenario}`;
const rows = new Map();
for (const r of results) {
    const row = rows.get(key(r)) ?? {};
    row[r.label] = r;
    rows.set(key(r), row);
}

const cell = (r) => r
    ? `panel ${r.panelHeight}px, clipped ${r.slides.map((s) => s.clippedPx).join("/")}px`
    : "n/a";

console.log("\nScenario".padEnd(38) + "Before".padEnd(36) + "After");
const html = [];
for (const [name, row] of [...rows].sort()) {
    console.log(name.padEnd(37) + cell(row.before).padEnd(36) + cell(row.after));
    const img = (r) => r ? `<img src="${r.label}-${r.contract}-${r.scenario}.png" alt="${r.label} ${name}">` : "n/a";
    html.push(`<tr><th>${name}</th><td>${cell(row.before)}<br>${img(row.before)}</td><td>${cell(row.after)}<br>${img(row.after)}</td></tr>`);
}

writeFileSync(join(out, "report.html"), `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>USPV slide height: before / after</title>
<style>body{font-family:sans-serif}td,th{border:1px solid #ccc;padding:6px;vertical-align:top;text-align:left}img{max-width:640px;display:block;margin-top:4px}</style>
</head><body><h1>USPV slide height: before / after</h1>
<table><thead><tr><th>Scenario</th><th>Before</th><th>After</th></tr></thead><tbody>${html.join("")}</tbody></table></body></html>`);
console.log(`\nReport: ${join(out, "report.html")}`);
EOF
