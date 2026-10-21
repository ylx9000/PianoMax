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
// Stable asset name: the README links /releases/latest/download/PianoMax.zip,
// which GitHub resolves to the newest release's asset with this exact name,
// so the link never goes stale when a version ships.
fs.writeFileSync(path.join(root, "release", "PianoMax.zip"), blob);
console.log("built " + path.relative(root, out) + " (" + fs.statSync(out).size + " bytes, " + files.length + " entries)");
