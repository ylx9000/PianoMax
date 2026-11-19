#!/usr/bin/env node
// Assemble the release body with the byte count and SHA-256 of the asset.
//
// The numbers are read from the build output at release time rather than
// written by hand, so they describe the archive that is actually uploaded.
// tools/release-check.mjs check 6 parses these two values back out of the
// published body and compares them with the downloaded asset.
//
// 用法：
//   node tools/make-release-body.mjs <tag> [--out <文件>]

import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// 参数：<tag> [--out <文件>] [--asset <zip 路径>]
// --asset 指定「算校验值的那份包」，默认是刚构建的 release/PianoMax-<tag>.zip。
// 手动补发时 CI 会传线上已上传的资产：正文里的数字必须描述线上那一份，
// 而不是本次重新构建出来的那一份，否则 release-check 第 6 项会判为不一致。
const argv = process.argv.slice(2);
const take = (flag) => {
  const i = argv.indexOf(flag);
  if (i < 0) return null;
  const v = argv[i + 1];
  argv.splice(i, 2);
  return v;
};
const outFile = take("--out");
const assetFile = take("--asset");
const tag = argv[0];
if (!tag) { console.error("用法: node tools/make-release-body.mjs <tag> [--out <文件>] [--asset <zip 路径>]"); process.exit(2); }

// ---- 产物事实 ------------------------------------------------------
const assetName = "PianoMax-" + tag + ".zip";
const zipPath = assetFile ? path.resolve(assetFile) : path.join(root, "release", assetName);
if (!existsSync(zipPath)) { console.error("找不到 " + zipPath + (assetFile ? "（--asset 指定的文件）" : "，先跑 node build.mjs")); process.exit(2); }
const blob = readFileSync(zipPath);
const bytes = statSync(zipPath).size;
const sha = createHash("sha256").update(blob).digest("hex").toUpperCase();

// ---- 正文正文：优先用 release/RELEASE-NOTES-<短版本>.md ------------

// 三套命名都认，先命中哪个用哪个：
//   RELEASE-NOTES-beta.7.md          （现有约定，去掉了 1.0.0-）
//   RELEASE-NOTES-1.0.0-beta.7.md    （去 v 前缀的完整版本号）
//   RELEASE-NOTES-v1.0.0-beta.7.md
const noV = tag.replace(/^v/, "");
const short = noV.replace(/^\d+\.\d+\.\d+-/, "");
const candidates = ["RELEASE-NOTES-" + short + ".md", "RELEASE-NOTES-" + noV + ".md", "RELEASE-NOTES-" + tag + ".md"];
let body = null;
let source = null;
for (const f of candidates) {
  const p = path.join(root, "release", f);
  if (existsSync(p)) { body = readFileSync(p, "utf8"); source = f; break; }
}

// ---- 校验段：永远以现场算出来的值为准 ------------------------------
// 说明文档里的数字一旦和包对不上，release-check 会红，但那时已经发出去了。
// 所以这里做两件事：把正文里既有的校验段整段替换掉；没有就补一段。
const block = [
  "## 校验",
  "",
  "- `" + assetName + "` " + bytes.toLocaleString("en-US") + " 字节",
  "- SHA-256: `" + sha + "`",
  "- tag `" + tag + "`",
  "",
  "核验：`curl -sL https://github.com/" + (process.env.GITHUB_REPOSITORY || "ylx9000/PianoMax") + "/releases/download/" + tag + "/" + assetName + " | sha256sum`",
].join("\n");

// 就地替换已有的「## 校验」段，而不是把它摘下来挪到末尾。
// 发布说明是排过版的东西，校验段未必在末尾；统一挪到尾会凭空造出一个
// 内容 diff。没有这一段时才追加到最后。
function withChecksum(text, section) {
  const re = /^##\s*校验\s*$/m;
  const m = text.match(re);
  const t = text.replace(/\s+$/, "");
  if (!m) return t + "\n\n" + section + "\n";
  const start = m.index;
  const rest = t.slice(start + m[0].length);
  const next = rest.search(/^#{1,2}\s/m);
  const end = next >= 0 ? start + m[0].length + next : t.length;
  const tail = t.slice(end).replace(/^\s*\n/, "");
  const head = t.slice(0, start).replace(/\s+$/, "");
  return head + "\n\n" + section + (tail ? "\n\n" + tail : "") + "\n";
}

if (body === null) {
  // 没有说明文件时生成一份最小可用正文；版本与 tag 都从闸门那边带过来。
  const prop = readFileSync(path.join(root, "module/module.prop"), "utf8");
  const code = (prop.match(/^versionCode=(.*)$/m) || [])[1] || "?";
  body = [
    "# PianoMax " + tag,
    "",
    "versionCode " + code + "。本版本没有单独的发布说明文件，正文由 CI 自动生成。",
    "",
    "完整的改动记录见 [CHANGELOG.md](https://github.com/" + (process.env.GITHUB_REPOSITORY || "ylx9000/PianoMax") + "/blob/main/CHANGELOG.md)。",
  ].join("\n");
  source = "<自动生成>";
}

const final = withChecksum(body, block);

if (outFile) {
  writeFileSync(outFile, final);
  console.error("正文来源: " + source);
  console.error("写入: " + outFile + "（" + Buffer.byteLength(final) + " 字节）");
  console.error("资产: " + path.basename(zipPath) + " " + bytes + " 字节 sha256=" + sha);
} else {
  process.stdout.write(final);
}
