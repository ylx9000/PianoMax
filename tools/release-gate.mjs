#!/usr/bin/env node
// 发版前置闸门：tag 与仓库里的版本声明必须完全对齐。
//
// 任何一条不匹配就非零退出，Actions 会停在构建之前 —— 宁可这次不发布，
// 也不要发出一个 update.json 指向 404、或者 module.prop 写着上个版本的包。
//
// 用法：
//   node tools/release-gate.mjs            # tag 取自 GITHUB_REF_NAME 或当前 HEAD 上的 tag
//   node tools/release-gate.mjs v1.0.0-beta.7

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

let fails = 0;
const ok = (m) => console.log("  OK   " + m);
const bad = (m) => { console.log("  FAIL " + m); fails++; };

function git(listArgs) {
  return execFileSync("git", ["-C", root, ...listArgs], { encoding: "utf8" }).trim();
}

// tag 优先级：命令行参数 > GITHUB_REF_NAME > 当前 HEAD 上指的 tag。
function resolveTag() {
  if (process.argv[2]) return process.argv[2].trim();
  if (process.env.GITHUB_REF_NAME) return process.env.GITHUB_REF_NAME.trim();
  try { return git(["describe", "--tags", "--exact-match", "HEAD"]); }
  catch { return ""; }
}

const tag = resolveTag();
console.log("== 发版闸门：tag = " + (tag || "<取不到>") + " ==");
if (!tag) { bad("取不到 tag：传一个参数，或在打 tag 后的提交上运行"); process.exit(1); }
if (!/^v/.test(tag)) bad("tag 不以 v 开头，release.yml 的触发条件是 v*：" + tag);

// module.prop
const prop = readFileSync(path.join(root, "module/module.prop"), "utf8");
const propVer = (prop.match(/^version=(.*)$/m) || [])[1];
const propCode = (prop.match(/^versionCode=(.*)$/m) || [])[1];
if (propVer === tag) ok("module.prop version == tag（" + tag + "）");
else bad("module.prop version 是 " + propVer + "，tag 是 " + tag);
if (!propCode) bad("module.prop 里没有 versionCode=");

// update.json
const upd = JSON.parse(readFileSync(path.join(root, "update.json"), "utf8"));
if (upd.version === tag) ok("update.json version == tag");
else bad("update.json version 是 " + upd.version + "，tag 是 " + tag);
if (String(upd.versionCode) === String(propCode)) ok("update.json versionCode == module.prop（" + propCode + "）");
else bad("update.json versionCode 是 " + upd.versionCode + "，module.prop 是 " + propCode);

// zipUrl 必须正好指向本次会产出的资产名。
// 仓库名优先取 GITHUB_REPOSITORY（Actions 自带），本地跑则从 origin 解析。
function resolveRepo() {
  if (process.env.GITHUB_REPOSITORY) return process.env.GITHUB_REPOSITORY.trim();
  try {
    const url = git(["remote", "get-url", "origin"]);
    const m = url.match(/github\.com[:/]+(.+?)(?:\.git)?$/);
    return m ? m[1] : "";
  } catch { return ""; }
}

const repoSlug = resolveRepo();
const wantZip = "PianoMax-" + tag + ".zip";
const wantUrl = repoSlug
  ? "https://github.com/" + repoSlug + "/releases/download/" + tag + "/" + wantZip
  : null;
if (!wantUrl) bad("取不到仓库名（没有 GITHUB_REPOSITORY，也没有可解析的 origin），无法核对 zipUrl");
else if (upd.zipUrl === wantUrl) ok("update.json zipUrl 指向 " + wantZip);
else bad("update.json zipUrl 是 " + upd.zipUrl + "\n         应为 " + wantUrl);

// 构建出来的资产名由 build.mjs 决定，跟闸门关心的 tag 对上才不白干。
if (propVer && propVer !== tag) bad("build.mjs 会打包出 PianoMax-" + propVer + ".zip，与期望的 " + wantZip + " 不符");

// 正文模板可选存在即可，缺失由 make-release-body.mjs 生成兜底，不算失败。
const short = tag.replace(/^v/, "").replace(/^\d+\.\d+\.\d+-/, "");
const notes = ["RELEASE-NOTES-" + short + ".md", "RELEASE-NOTES-" + tag.replace(/^v/, "") + ".md", "RELEASE-NOTES-" + tag + ".md"];
const found = notes.find((f) => { try { readFileSync(path.join(root, "release", f)); return true; } catch { return false; } });
if (found) ok("找到发布说明 release/" + found);
else console.log("  NOTE 没有 release/" + notes[0] + "，正文将由 make-release-body.mjs 自动生成");

console.log("");
if (fails === 0) { console.log("闸门通过，可以构建。"); process.exit(0); }
console.log(fails + " 项不匹配，中止发布。");
process.exit(1);
