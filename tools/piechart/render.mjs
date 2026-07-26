// Renders a pie chart PNG from a JSON array of {label, count} objects —
// used for the /menu Statistics module's "top participants" chart. Same
// dependency (@napi-rs/canvas: prebuilt binaries, no native toolchain) and
// overall shape as ../wordcloud/render.mjs.
//
// Usage: node render.mjs <input.json>  — writes the PNG to stdout.
// Diagnostics go to stderr so stdout stays pure image bytes.
import { createCanvas } from "@napi-rs/canvas";
import fs from "node:fs";

const WIDTH = 800;
const HEIGHT = 600;
const RADIUS = 200;
const CENTER_X = 260;
const CENTER_Y = HEIGHT / 2;
const MAX_SLICES = 8; // beyond this, group the rest into "Other" so the legend stays readable
const PALETTE = ["#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#94e2d5", "#89b4fa", "#cba6f7", "#eba0ac"];

function main() {
  const inputPath = process.argv[2];
  if (!inputPath) {
    process.stderr.write("usage: render.mjs <input.json>\n");
    process.exit(1);
  }

  const raw = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  if (!Array.isArray(raw) || raw.length === 0) {
    process.stderr.write("no slices to render\n");
    process.exit(1);
  }

  const sorted = [...raw].sort((a, b) => b.count - a.count);
  let slices = sorted;
  if (sorted.length > MAX_SLICES) {
    const head = sorted.slice(0, MAX_SLICES - 1);
    const otherCount = sorted.slice(MAX_SLICES - 1).reduce((sum, s) => sum + s.count, 0);
    slices = [...head, { label: "Other", count: otherCount }];
  }

  const total = slices.reduce((sum, s) => sum + s.count, 0);

  const canvas = createCanvas(WIDTH, HEIGHT);
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#1e1e2e";
  ctx.fillRect(0, 0, WIDTH, HEIGHT);

  let angle = -Math.PI / 2; // start at 12 o'clock
  const legendX = 500;
  let legendY = HEIGHT / 2 - (slices.length * 34) / 2;

  slices.forEach((s, i) => {
    const fraction = total > 0 ? s.count / total : 0;
    const sweep = fraction * Math.PI * 2;
    const color = PALETTE[i % PALETTE.length];

    ctx.beginPath();
    ctx.moveTo(CENTER_X, CENTER_Y);
    ctx.arc(CENTER_X, CENTER_Y, RADIUS, angle, angle + sweep);
    ctx.closePath();
    ctx.fillStyle = color;
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = "#1e1e2e";
    ctx.stroke();
    angle += sweep;

    ctx.fillStyle = color;
    ctx.fillRect(legendX, legendY, 22, 22);
    ctx.fillStyle = "#cdd6f4";
    ctx.font = "18px sans-serif";
    const pct = Math.round(fraction * 100);
    ctx.fillText(`${s.label} (${pct}%)`, legendX + 32, legendY + 17);
    legendY += 34;
  });

  const buf = canvas.toBuffer("image/png");
  fs.writeSync(1, buf);
}

main();
