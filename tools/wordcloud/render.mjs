// Renders a word cloud PNG from a JSON array of {word, count} objects.
//
// Deliberately hand-rolled (spiral placement) rather than pulling in a
// wordcloud package, since those either need node-canvas (heavy native
// deps: cairo/pango/etc.) or are browser-only. @napi-rs/canvas ships
// prebuilt binaries and needs no native toolchain, so this is the whole
// dependency.
//
// Usage: node render.mjs <input.json>  — writes the PNG to stdout.
// Diagnostics go to stderr so stdout stays pure image bytes.
import { createCanvas } from "@napi-rs/canvas";
import fs from "node:fs";
import { GlobalFonts } from "@napi-rs/canvas";

// Resolve relative to this script, not the cwd — the bot invokes us from
// the project root, where ./fonts/ does not exist.
GlobalFonts.registerFromPath(
  new URL("./fonts/Peyda-Regular.ttf", import.meta.url).pathname,
  "Peyda"
);
console.error(GlobalFonts.families);

const WIDTH = 800;
const HEIGHT = 600;
const MAX_FONT_SIZE = 88;
const MIN_FONT_SIZE = 16;
const PALETTE = ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#94e2d5", "#89b4fa", "#cba6f7"];

function main() {
  const inputPath = process.argv[2];
  if (!inputPath) {
    process.stderr.write("usage: render.mjs <input.json>\n");
    process.exit(1);
  }

  const words = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  if (!Array.isArray(words) || words.length === 0) {
    process.stderr.write("no words to render\n");
    process.exit(1);
  }

  const canvas = createCanvas(WIDTH, HEIGHT);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#1e1e2e";
  ctx.fillRect(0, 0, WIDTH, HEIGHT);
  ctx.textBaseline = "alphabetic";

  const counts = words.map((w) => w.count);
  const maxCount = Math.max(...counts);
  const minCount = Math.min(...counts);

  function fontSizeFor(count) {
    if (maxCount === minCount) return (MAX_FONT_SIZE + MIN_FONT_SIZE) / 2;
    const t = (count - minCount) / (maxCount - minCount);
    return MIN_FONT_SIZE + t * (MAX_FONT_SIZE - MIN_FONT_SIZE);
  }

  function intersects(a, b) {
    return !(a.x + a.w < b.x || b.x + b.w < a.x || a.y + a.h < b.y || b.y + b.h < a.y);
  }

  const placed = [];
  function tryPlace(w, h) {
    const cx = WIDTH / 2;
    const cy = HEIGHT / 2;
    const maxRadius = Math.sqrt(WIDTH * WIDTH + HEIGHT * HEIGHT);
    // Archimedean spiral outward from center; first non-colliding,
    // in-bounds slot wins. Larger words are placed first (caller sorts by
    // count descending) so the biggest words claim the center.
    for (let angle = 0; angle < 240 * Math.PI; angle += 0.3) {
      const radius = angle * 4.2;
      if (radius > maxRadius) break;
      const x = cx + radius * Math.cos(angle) - w / 2;
      const y = cy + radius * Math.sin(angle) * 0.62 - h / 2;
      if (x < 4 || y < 4 || x + w > WIDTH - 4 || y + h > HEIGHT - 4) continue;
      const box = { x, y, w, h };
      if (placed.some((p) => intersects(box, p))) continue;
      return box;
    }
    return null;
  }

  const sorted = [...words].sort((a, b) => b.count - a.count);
  let colorIdx = 0;
  for (const { word, count } of sorted) {
    const fontSize = fontSizeFor(count);
    ctx.font = `bold ${fontSize}px "Peyda"`;
    const metrics = ctx.measureText(word);
    const w = metrics.width;
    const h = fontSize;
    const box = tryPlace(w, h);
    if (!box) continue; // ran out of room; skip rather than overlap
    placed.push(box);
    ctx.fillStyle = PALETTE[colorIdx % PALETTE.length];
    colorIdx++;
    ctx.fillText(word, box.x, box.y + h * 0.8);
  }

  const buf = canvas.toBuffer("image/png");
  fs.writeSync(1, buf);
}

main();
