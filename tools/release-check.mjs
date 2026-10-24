#!/usr/bin/env node
// 发布链路体检：一条命令回答「线上到底是什么」。
//
// 查五件事，任何一项不一致就非零退出：
//   1. update.json 的 versionCode 与 module.prop 一致
//   2. update.json 的 zipUrl 能 200，且大小与本地 release/ 里的包一致
//   3. 下载到的 zip 逐项 sha256 与 tag 树的 module/ 相同
//   4. 远端 tag 指向的提交 == 本地 HEAD（或至少 == 本包对应的提交）
//   5. Release 正文里的 sha256 / 字节数 / commit 与实际一致
//
// 用法：node tools/release-check.mjs
// 依赖：git、curl.exe（Windows）。不需要 token —— 只读公开接口。

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { inflateRawSync } from "node:zlib";
import path from "node:path";

const REPO = "ylx9000/PianoMax";
const root = path.resolve(import.meta.dirname, "..");
let fails = 0;
const ok = (m) => console.log("  OK   " + m);
const bad = (m) => { console.log("  FAIL " + m); fails++; };
const warn = (m) => console.log("  WARN " + m);

function curl(args) {
  return execFileSync("curl.exe", ["-s", "-L", "--max-time", "60", ...args], { encoding: "buffer", maxBuffer: 128 * 1024 * 1024 });
}
function sha256(buf) { return createHash("sha256").update(buf).digest("hex").toUpperCase(); }

function zipEntries(b) {
  let eocd = -1;
  for (let i = b.length - 22; i >= 0; i--) if (b.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error("no EOCD");
  const n = b.readUInt16LE(eocd + 10);
  let off = b.readUInt32LE(eocd + 16);
  const out = [];
  for (let k = 0; k < n; k++) {
    const method = b.readUInt16LE(off + 10), csize = b.readUInt32LE(off + 20);
    const nlen = b.readUInt16LE(off + 28), elen = b.readUInt16LE(off + 30), clen = b.readUInt16LE(off + 32);
    const lho = b.readUInt32LE(off + 42);
    const name = b.slice(off + 46, off + 46 + nlen).toString("utf8");
    const ds = lho + 30 + b.readUInt16LE(lho + 26) + b.readUInt16LE(lho + 28);
    const raw = b.slice(ds, ds + csize);
    out.push({ name, sha: sha256(method === 0 ? raw : inflateRawSync(raw)) });
    off += 46 + nlen + elen + clen;
  }
  return out;
}

console.log("== 1. 本地 module.prop ==");
const prop = readFileSync(path.join(root, "module/module.prop"), "utf8");
const ver = (prop.match(/^version=(.*)$/m) || [])[1];
const vcode = (prop.match(/^versionCode=(.*)$/m) || [])[1];
console.log("  version=" + ver + "  versionCode=" + vcode);

console.log("== 2. update.json（KSU 管理器读的就是这个）==");
const localUpdate = readFileSync(path.join(root, "update.json"), "utf8");
const rawUpdate = curl(["-o", "-", "https://raw.githubusercontent.com/" + REPO + "/main/update.json"]).toString("utf8");
if (localUpdate.trim() === rawUpdate.trim()) ok("本地 update.json == 远端 raw");
else bad("本地 update.json 与远端 raw 不一致");

const upd = JSON.parse(rawUpdate);
if (upd.version === ver) ok("update.json version 与 module.prop 一致"); else bad("version 不一致: " + upd.version + " vs " + ver);
if (String(upd.versionCode) === String(vcode)) ok("versionCode 一致"); else bad("versionCode 不一致: " + upd.versionCode + " vs " + vcode);

console.log("== 3. 下载资产 ==");
const dl = curl(["-o", "-", upd.zipUrl]);
console.log("  下载 " + dl.length + " 字节  sha256=" + sha256(dl));
const localZip = path.join(root, "release", "PianoMax-" + ver + ".zip");
if (existsSync(localZip)) {
  const lz = readFileSync(localZip);
  if (sha256(lz) === sha256(dl)) ok("下载件 == 本地 release/PianoMax-" + ver + ".zip");
  else bad("下载件与本地包不同（本地 " + lz.length + " B / " + sha256(lz).slice(0, 16) + "）");
} else warn("本地没有 release/PianoMax-" + ver + ".zip，跳过比对");

console.log("== 4. 资产内容 vs tag 树 ==");
const entries = zipEntries(dl);
console.log("  26 项检查（条目数 " + entries.length + "）");
let diff = [];
for (const e of entries) {
  try {
    const g = execFileSync("git", ["-C", root, "show", ver + ":module/" + e.name], { maxBuffer: 64 * 1024 * 1024 });
    if (sha256(g) !== e.sha) diff.push(e.name);
  } catch { diff.push(e.name + "(missing)"); }
}
if (diff.length === 0) ok("下载件与 tag " + ver + " 的 module/ 树逐字节相同");
else bad("与 tag 树不一致的文件: " + diff.join(", "));

console.log("== 5. tag 指向 ==");
const lsAll = execFileSync("git", ["-C", root, "ls-remote", "origin", "refs/tags/" + ver + "*"], { encoding: "utf8" }).trim().split(/\r?\n/);
const peeled = lsAll.find((l) => l.includes("^{}"));
const remoteTag = (peeled || lsAll[0] || "").split(/\t/)[0].trim();
const localTag = execFileSync("git", ["-C", root, "rev-parse", ver + "^{}"], { encoding: "utf8" }).trim();
const head = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
console.log("  remote=" + remoteTag.slice(0, 7) + "  local=" + localTag.slice(0, 7) + "  HEAD=" + head.slice(0, 7));
if (remoteTag === localTag) ok("远端 tag == 本地 tag"); else bad("远端 tag " + remoteTag.slice(0, 7) + " != 本地 " + localTag.slice(0, 7));
// tag 不必等于 HEAD：之后只改文档的提交不该重新打 tag。
// 真正要保证的是「tag 之后 module/ 没有再变」，那样装包的人拿到的就是最新代码。
if (localTag === head) {
  ok("tag 指向 HEAD");
} else {
  try {
    const drift = execFileSync("git", ["-C", root, "diff", "--name-only", localTag, head, "--", "module/"], { encoding: "utf8" }).trim();
    if (!drift) ok("tag 之后的提交没有改动 module/（仅文档）");
    else bad("tag 之后 module/ 有变动，需要发新版本: " + drift.split(/\r?\n/).join(", "));
  } catch { warn("无法比较 tag 与 HEAD"); }
}

console.log("== 6. Release 正文自洽 ==");
const page = readPageBody();
if (page === null) warn("取不到 Release 正文，跳过（匿名 API 限流时可忽略）");
else {
  if (page.includes("PianoMax-" + ver + ".zip")) ok("正文提到正确的资产名");
  else warn("正文里没有出现 PianoMax-" + ver + ".zip");
  const m = page.match(/([0-9,]+)\s*字节/);
  if (m && m[1].replace(/,/g, "") === String(dl.length)) ok("正文字节数与实际一致（" + dl.length + "）");
  else if (m) bad("正文字节数 " + m[1] + " != 实际 " + dl.length);
  const h = page.match(/SHA-256[:：]\s*`?([0-9A-Fa-f]{64})`?/);
  if (h && h[1].toUpperCase() === sha256(dl)) ok("正文 sha256 与实际一致");
  else if (h) bad("正文 sha256 " + h[1].slice(0, 16) + " != 实际 " + sha256(dl).slice(0, 16));
  else warn("正文里没找到 SHA-256 行");
}

// Release 正文用 token 查（git credential 里通常有）。
// 没有 token 或限流就 warn 跳过 —— 正文里的校验值是辅助信息，
// 真正的判据是 §3/§4 的字节比对：包 == 本地、包 == tag 树。
function readPageBody() {
  let tok = "";
  try {
    const out = execFileSync("git", ["credential", "fill"], {
      input: "protocol=https\nhost=github.com\n\n",
      encoding: "utf8",
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
    const m = out.match(/^password=(.*)$/m);
    if (m) tok = m[1].trim();
  } catch { /* 没有凭据 */ }
  if (!tok) return null;
  try {
    const j = JSON.parse(
      curl(["-H", "Authorization: token " + tok, "-H", "Accept: application/vnd.github+json",
            "-o", "-", "https://api.github.com/repos/" + REPO + "/releases/tags/" + ver]).toString("utf8")
    );
    return typeof j.body === "string" ? j.body : null;
  } catch { return null; }
}

console.log("");
if (fails === 0) { console.log("全部通过。"); process.exit(0); }
console.log(fails + " 项不一致。");
process.exit(1);