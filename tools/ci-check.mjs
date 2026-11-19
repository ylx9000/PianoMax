#!/usr/bin/env node
// 仓库体检：shell 语法 / 换行 / 打包自洽。
//
// 本地 Windows 与 GitHub Actions 的 Ubuntu runner 跑的是同一段代码，
// CI 失败的每一条都能在本机原样复现。
//
// 用法：
//   node tools/ci-check.mjs          # 三项全跑
//   node tools/ci-check.mjs --sh     # 只查 shell 语法
//   node tools/ci-check.mjs --lf     # 只查换行
//   node tools/ci-check.mjs --build  # 只打包并核对产物
//
// 依赖：git（取文件清单）、sh（语法检查）、node。
// 打包核对不依赖 unzip 命令 —— zip 的 CRC 与长度由本脚本自己解出来验，
// 比 unzip -t 多查一项「条目名有没有反斜杠」。

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { inflateRawSync } from "node:zlib";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const run = (flag) => args.length === 0 || args.includes(flag);

let fails = 0;
const ok = (m) => console.log("  OK   " + m);
const bad = (m) => { console.log("  FAIL " + m); fails++; };
const sha256 = (b) => createHash("sha256").update(b).digest("hex").toUpperCase();

function git(listArgs) {
  return execFileSync("git", ["-C", root, ...listArgs], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}
const tracked = () => git(["ls-files", "-z"]).split("\0").filter(Boolean);

// ---- 1. shell 语法 ------------------------------------------------
// 模块脚本在设备上跑的是 mksh/toybox，这里用 POSIX sh 做语法检查。
// 两者语法重叠度足够高，而 POSIX sh 更严 —— 能过它就基本不会在设备上崩在解析阶段。
function findSh() {
  const cands = [];
  if (process.env.SH) cands.push(process.env.SH);
  if (process.platform === "win32") {
    cands.push("C:\\Program Files\\Git\\usr\\bin\\sh.exe", "C:\\Program Files\\Git\\bin\\bash.exe", "sh");
  } else {
    cands.push("sh", "/bin/sh");
  }
  for (const c of cands) {
    try { execFileSync(c, ["-c", "exit 0"], { stdio: "ignore" }); return c; } catch {}
  }
  return null;
}

function checkShell() {
  console.log("== 1. shell 语法（sh -n）==");
  const sh = findSh();
  if (!sh) { bad("找不到 sh，无法做语法检查（Windows 上装 Git for Windows，或用 SH 环境变量指定）"); return; }
  const scripts = tracked().filter((f) => f.endsWith(".sh"));
  let n = 0;
  for (const f of scripts) {
    if (!existsSync(path.join(root, f))) { bad(f + " 已被 git 跟踪但工作树里不存在"); continue; }
    try {
      execFileSync(sh, ["-n", f], { cwd: root, stdio: ["ignore", "ignore", "pipe"] });
      n++;
    } catch (e) {
      const detail = String(e.stderr || e.message).trim().split(/\r?\n/).filter(Boolean)[0] || "unknown";
      bad(f + " 语法错误: " + detail);
    }
  }
  if (n === scripts.length) ok(n + " 个脚本全部通过 sh -n（" + sh + "）");
}

// ---- 2. 换行 ------------------------------------------------------
// 脚本一旦带 CRLF，落到 Android 上 sh 会在每行末尾多一个 \r，
// 表现为 not found 且行号对不上，是最难现场排查的一类故障。
const TEXT = /\.(sh|prop|txt|json|md|html|mjs|js|yml|yaml|cfg)$/;
function checkLf() {
  console.log("== 2. 换行（全仓 LF）==");
  const files = tracked().filter((f) => TEXT.test(f));
  let n = 0;
  let missing = 0;
  for (const f of files) {
    const p = path.join(root, f);
    if (!existsSync(p)) { bad(f + " 已被 git 跟踪但工作树里不存在"); missing++; continue; }
    const b = readFileSync(p);
    const i = b.indexOf(13);
    if (i >= 0) {
      const line = b.slice(0, i).split(10).length;
      bad(f + ":" + line + " 是 CRLF（本仓库所有文本文件必须是 LF）");
    } else n++;
  }
  if (n + missing === files.length && missing === 0) ok(n + " 个文本文件全部是 LF");
}

// ---- 3. 打包 ------------------------------------------------------
// 复刻 build.mjs 的 skip 规则：新增跳过规则时两处一起改，否则这里会误报。
function walk(dir, rel, out) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith(".") || e.name.startsWith("_")) continue;
    if (rel === "thermal" && e.name === "README.txt") continue;
    if (rel && rel.startsWith("thermal/") && e.name === "README.txt") continue;
    const p = path.join(dir, e.name);
    const r = rel ? rel + "/" + e.name : e.name;
    if (e.isDirectory()) walk(p, r, out);
    else out.push({ name: r, data: readFileSync(p) });
  }
  return out;
}

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(b) {
  let c = -1;
  for (let i = 0; i < b.length; i++) c = CRC_TABLE[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

// 解出中央目录并逐条目验 CRC，等价于 unzip -t 但能拿到条目名做额外检查。
function inspectZip(b) {
  let eocd = -1;
  for (let i = b.length - 22; i >= 0; i--) { if (b.readUInt32LE(i) === 0x06054b50) { eocd = i; break; } }
  if (eocd < 0) throw new Error("找不到 EOCD，zip 尾部不完整");
  const n = b.readUInt16LE(eocd + 10);
  let off = b.readUInt32LE(eocd + 16);
  const out = [];
  for (let k = 0; k < n; k++) {
    const method = b.readUInt16LE(off + 10);
    const crcWant = b.readUInt32LE(off + 16);
    const csize = b.readUInt32LE(off + 20);
    const usize = b.readUInt32LE(off + 24);
    const nlen = b.readUInt16LE(off + 28);
    const elen = b.readUInt16LE(off + 30);
    const clen = b.readUInt16LE(off + 32);
    const lho = b.readUInt32LE(off + 42);
    const name = b.slice(off + 46, off + 46 + nlen).toString("utf8");
    const ds = lho + 30 + b.readUInt16LE(lho + 26) + b.readUInt16LE(lho + 28);
    const raw = b.slice(ds, ds + csize);
    const data = method === 0 ? raw : inflateRawSync(raw);
    out.push({ name, size: data.length, usize, crcWant, crcGot: crc32(data), sha: sha256(data) });
    off += 46 + nlen + elen + clen;
  }
  return out;
}

function checkBuild() {
  console.log("== 3. 打包与产物自洽 ==");
  const prop = readFileSync(path.join(root, "module/module.prop"), "utf8");
  const ver = (prop.match(/^version=(.*)$/m) || [])[1];
  if (!ver) { bad("module.prop 里读不到 version="); return; }
  const zipPath = path.join(root, "release", "PianoMax-" + ver + ".zip");
  try {
    execFileSync(process.execPath, ["build.mjs"], { cwd: root, stdio: "inherit" });
  } catch (e) { bad("node build.mjs 失败"); return; }
  if (!existsSync(zipPath)) { bad("build.mjs 没有产出 " + path.relative(root, zipPath)); return; }

  const blob = readFileSync(zipPath);
  let entries;
  try { entries = inspectZip(blob); }
  catch (e) { bad("zip 结构损坏: " + e.message); return; }

  const broken = entries.filter((e) => e.crcGot !== e.crcWant || e.size !== e.usize);
  if (broken.length) bad("CRC/长度校验失败: " + broken.map((e) => e.name).join(", "));
  else ok(entries.length + " 个条目 CRC 与长度全部校验通过");

  const bs = entries.filter((e) => e.name.includes("\\"));
  if (bs.length) bad("条目名里有反斜杠，Android 上会解成怪文件名: " + bs.map((e) => e.name).join(", "));
  else ok("条目名全部是正斜杠");

  const want = walk(path.join(root, "module"), "", []);
  const wantMap = new Map(want.map((f) => [f.name, sha256(f.data)]));
  const gotMap = new Map(entries.map((e) => [e.name, e.sha]));
  const missing = [...wantMap.keys()].filter((n) => !gotMap.has(n));
  const extra = [...gotMap.keys()].filter((n) => !wantMap.has(n));
  const differ = [...wantMap.keys()].filter((n) => gotMap.has(n) && gotMap.get(n) !== wantMap.get(n));
  if (missing.length) bad("zip 少了文件: " + missing.join(", "));
  if (extra.length) bad("zip 多了文件: " + extra.join(", "));
  if (differ.length) bad("内容不一致: " + differ.join(", "));
  if (!missing.length && !extra.length && !differ.length) ok("zip 内 " + want.length + " 个文件与 module/ 工作树逐字节相同");

  console.log("  产物 " + path.relative(root, zipPath) + "  " + statSync(zipPath).size + " 字节  sha256=" + sha256(blob));

  // 再交给系统 unzip 过一遍。上面的 CRC 校验已经证明了压缩数据完好，
  // 但「别的解压器能不能读」是另一件事，CI 里也有独立的一步做这个。
  // Windows 上通常没有 unzip，只有 Git for Windows 自带一份，找不到就跳过。
  const unz = findUnzip();
  if (!unz) { console.log("  SKIP 本机没有 unzip，跳过 unzip -t（CI 上会跑）"); return; }
  try {
    execFileSync(unz, ["-t", zipPath], { stdio: ["ignore", "pipe", "pipe"] });
    ok("unzip -t 完整性与压缩数据无损（" + unz + "）");
  } catch (e) {
    const detail = String(e.stdout || "") + String(e.stderr || "");
    bad("unzip -t 失败: " + detail.split(/\r?\n/).filter(Boolean).slice(-2).join(" / "));
  }
}

function findUnzip() {
  const cands = process.platform === "win32"
    ? ["C:\\Program Files\\Git\\usr\\bin\\unzip.exe", "unzip"]
    : ["unzip"];
  for (const c of cands) {
    try { execFileSync(c, ["-v"], { stdio: "ignore" }); return c; } catch {}
  }
  return null;
}

if (run("--sh")) checkShell();
if (run("--lf")) checkLf();
if (run("--build")) checkBuild();

console.log("");
if (fails === 0) { console.log("全部通过。"); process.exit(0); }
console.log(fails + " 项不通过。");
process.exit(1);
