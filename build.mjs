#!/usr/bin/env node
// Build release/PianoMax-<version>.zip from module/.
//
// Written by hand rather than with Compress-Archive or .NET's
// CreateFromDirectory: both write Windows separators into entry names, and
// Android's unzip then materialises them as single files literally called
// "lib\apply.sh".  Entries here always use forward slashes and carry a unix
// 0755 mode, which is what KernelSU expects for a module root.

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const root = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const modDir = path.join(root, "module");

const prop = fs.readFileSync(path.join(modDir, "module.prop"), "utf8");
const ver = (prop.match(/^version=(.*)$/m) || [])[1];
if (!ver) { console.error("version not found in module.prop"); process.exit(1); }

function walk(dir, rel) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith(".") || e.name.startsWith("_")) continue;
    // Production notes stay out of the shipped module: the thermal variant
    // directories carry a README for whoever rebuilds the tables.
    if (rel === "thermal" && e.name === "README.txt") continue;
    if (rel && rel.startsWith("thermal/") && e.name === "README.txt") continue;
    const p = path.join(dir, e.name);
    const r = rel ? rel + "/" + e.name : e.name;
    if (e.isDirectory()) out.push(...walk(p, r));
    else out.push({ name: r, data: fs.readFileSync(p) });
  }
  return out;
}

// The preset table is the single source of truth for every number the module
// writes.  A malformed row would end up in sysfs on a user's device, so the
// build refuses to ship rather than packaging data nobody has read.
{
  const KEYS = ["powersave", "balanced", "performance", "extreme"];
  const raw = fs.readFileSync(path.join(modDir, "presets.txt"), "utf8");
  const rows = raw.split(/\r?\n/).filter(l => l && !l.startsWith("#"));
  if (rows.length !== KEYS.length) throw new Error("presets.txt: expected " + KEYS.length + " rows, got " + rows.length);
  for (const [i, k] of KEYS.entries()) {
    const cols = rows[i].split("\t");
    if (cols[0] !== k) throw new Error("presets.txt row " + i + ": key " + cols[0] + " != " + k);
    if (cols.length !== 10) throw new Error("presets.txt row " + k + ": " + cols.length + " columns, expected 10");
    const [name, c0, c6, gpu, ddr, llcc, tc, ts, zones] = cols.slice(1);
    for (const [label, v] of [["cpu0", c0], ["cpu6", c6], ["gpu", gpu], ["ddr", ddr], ["llcc", llcc], ["tripC", tc], ["tripS", ts]]) {
      if (!/^\d+$/.test(v)) throw new Error("presets.txt row " + k + ": " + label + " is not an integer");
    }
    if (Number(c0) >= Number(c6)) throw new Error("presets.txt row " + k + ": cpu0 >= cpu6");
    if (!(Number(tc) >= 80000 && Number(tc) <= 110000)) throw new Error("presets.txt row " + k + ": tripC out of range");
    if (!(Number(ts) >= 40000 && Number(ts) <= 80000)) throw new Error("presets.txt row " + k + ": tripS out of range");
    if (!["kernel", "module"].includes(zones)) throw new Error("presets.txt row " + k + ": zones must be kernel|module");
    if (!name) throw new Error("presets.txt row " + k + ": empty display name");
  }
  console.log("presets.txt: " + rows.length + " rows verified");
}

const files = walk(modDir, "");

// Regression lint.  A doubled dollar in a shell source is load-bearing
// ($$ is the pid), and more than one editor pipeline has silently folded it
// into a single dollar while saving -- which turns /proc/$$/cgroup into
// /proc/$/cgroup, a path that does not exist, reads empty, and switches a
// guard branch off without any visible symptom.  That exact corruption
// shipped twice.  Fail the build instead of trusting the editor.
{
  const SHELL = /\.sh$/;
  const bad = [];
  for (const f of files) {
    if (!SHELL.test(f.name)) continue;
    const text = f.data.toString("utf8");
    text.split(/\r?\n/).forEach((line, i) => {
      // /proc/$/... is never valid: the pid expansion needs either a literal
      // $$ or a named variable.  Same for "$/".
      if (/\/proc\/\$\//.test(line)) bad.push(f.name + ":" + (i + 1) + ": " + line.trim());
    });
  }
  if (bad.length) {
    console.error("FATAL: a doubled dollar was folded to a single dollar (\$\$ -> \$) in:");
    for (const b of bad) console.error("  " + b);
    process.exit(1);
  }
}

// Single-source lint.  The zone family has to come from PM_SILICON_ZONES and
// the thresholds from PM_TRIP, or the copies drift: the silicon tripwire was
// hardcoded in two places and covered 36 of the 57 zones the module disables,
// leaving 22 sensors (ddr, camera, video, the DSP clusters) with their
// governor switched off and nothing reading them.  A new hardcoded zone list
// in a runtime script is the same bug waiting to happen.
// Note on scope: a "no hardcoded zone family" lint was written here and
// removed.  Three attempts in a row misread ordinary numeric lines -- CPU
// index loops, u16 padding, bitfield rows -- and a check that cries wolf is
// worse than no check.  The gap it was meant to catch is closed structurally
// instead: the family lives in lib/common.sh and every consumer reads it from
// there, including status.sh's cluster maxima.

const table = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
const crc32 = (b) => {
  let c = -1;
  for (let i = 0; i < b.length; i++) c = table[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
};

const chunks = [];
const central = [];
let offset = 0;
const MODE = (0o100755 * 65536) >>> 0;

for (const f of files) {
  const comp = zlib.deflateRawSync(f.data, { level: 9 });
  const crc = crc32(f.data);
  const nb = Buffer.from(f.name, "utf8");

  const lh = Buffer.alloc(30);
  lh.writeUInt32LE(0x04034b50, 0);
  lh.writeUInt16LE(20, 4);
  lh.writeUInt16LE(0x0800, 6);
  lh.writeUInt16LE(8, 8);
  lh.writeUInt32LE(crc, 14);
  lh.writeUInt32LE(comp.length, 18);
  lh.writeUInt32LE(f.data.length, 22);
  lh.writeUInt16LE(nb.length, 26);
  chunks.push(lh, nb, comp);

  const ch = Buffer.alloc(46);
  ch.writeUInt32LE(0x02014b50, 0);
  ch.writeUInt16LE(0x031e, 4);
  ch.writeUInt16LE(20, 6);
  ch.writeUInt16LE(0x0800, 8);
  ch.writeUInt16LE(8, 10);
  ch.writeUInt32LE(crc, 16);
  ch.writeUInt32LE(comp.length, 20);
  ch.writeUInt32LE(f.data.length, 24);
  ch.writeUInt16LE(nb.length, 28);
  ch.writeUInt32LE(MODE, 38);
  ch.writeUInt32LE(offset, 42);
  central.push(ch, nb);

  offset += lh.length + nb.length + comp.length;
}

const cd = Buffer.concat(central);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0);
end.writeUInt16LE(files.length, 8);
end.writeUInt16LE(files.length, 10);
end.writeUInt32LE(cd.length, 12);
end.writeUInt32LE(offset, 16);

fs.mkdirSync(path.join(root, "release"), { recursive: true });
const blob = Buffer.concat([...chunks, cd, end]);
const out = path.join(root, "release", "PianoMax-" + ver + ".zip");
fs.writeFileSync(out, blob);
// Local convenience copy with a version-free name.  No link on GitHub uses
// it: update.json and the README badge both point at the versioned asset,
// because /releases/latest/download/PianoMax.zip only resolves while the
// *latest* release happens to carry an asset with that exact name -- the
// beta.5 release does not, so that URL 404s.
fs.writeFileSync(path.join(root, "release", "PianoMax.zip"), blob);
console.log("built " + path.relative(root, out) + " (" + fs.statSync(out).size + " bytes, " + files.length + " entries)");
