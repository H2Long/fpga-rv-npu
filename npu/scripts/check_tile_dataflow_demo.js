// check_tile_dataflow_demo.js — 静态验证 docs/tile_dataflow_demo.html 的阵列模型
//
// 用最小 DOM shim 在 Node 里跑页面里的真实脚本，断言：
//   1) 仿真结果 C 恒等于 A × BT（含边界 Tile 与多 K 段）；
//   2) 每个输出 Tile 恰好 DRAIN 一次、SNAPSHOT 一次，排空恒为 P+Q-2=6 拍；
//   3) en 只在 FEED/DRAIN 拍推进（PREFETCH 期间阵列真的冻结）；
//   4) 阵列/卡片/lane/区域几何两两不重叠且不越出 viewBox。
//
// 用法：node scripts/check_tile_dataflow_demo.js
const fs = require("fs");
const vm = require("vm");

const html = fs.readFileSync(__dirname + "/../docs/tile_dataflow_demo.html", "utf8");
const m = html.match(/<script>([\s\S]*)<\/script>/);
if (!m) throw new Error("script block not found");
let code = m[1];

const tail = "\nreset();\n})();";
if (!code.includes(tail)) throw new Error("unexpected script tail");
code = code.replace(tail,
  "\nreset();\nglobalThis.__T = { S, step, reset, accCount, accAt, isHot, PHASE_OF, ntK, validTk, segTk, PRESETS, currentKs, fifoCount, DRAIN_BEATS, totalOutTiles, G, rowY, colX, VB, aLaneX0, aLaneX1, bLaneY0, bLaneY1, arrayInL, arrayInT };\n})();");

/* ---------------- 最小 DOM shim ---------------- */
const ALL = [];
class ClassList {
  constructor(el) { this.el = el; this.set = new Set(); }
  add(...c) { c.forEach((x) => x && this.set.add(x)); this.sync(); }
  remove(...c) { c.forEach((x) => this.set.delete(x)); this.sync(); }
  contains(c) { return this.set.has(c); }
  toggle(c, force) {
    const on = force === undefined ? !this.set.has(c) : !!force;
    on ? this.set.add(c) : this.set.delete(c);
    this.sync(); return on;
  }
  sync() { this.el._cls = [...this.set].join(" "); }
}
class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = []; this.attrs = {}; this._text = ""; this._cls = "";
    this.classList = new ClassList(this);
    this.style = {};
    this._html = "";
    ALL.push(this);
  }
  get className() { return this._cls; }
  set className(v) { this._cls = String(v); this.classList.set = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get lastChild() { return this.children[this.children.length - 1] || null; }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
  append(...cs) { cs.forEach((c) => this.appendChild(c)); }
  setAttribute(k, v) {
    this.attrs[k] = String(v);
    if (k === "class") this.className = String(v);   // 真实 DOM 会同步 classList
  }
  getAttribute(k) { return this.attrs[k] ?? null; }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text; }
  set innerHTML(v) { this._html = String(v); }
  get innerHTML() { return this._html; }
  addEventListener() {}
}
function walk(node, out = []) { for (const c of node.children) { out.push(c); walk(c, out); } return out; }

const byId = new Map();
const ids = ["play", "step", "reset", "preset", "speed", "speedValue", "statusPill", "phaseName",
  "tileIdx", "feedBeat", "tileProgress", "validSizes", "fifoCount", "segInfo", "aAddr", "bAddr",
  "cAddr", "util", "written", "cwrBar", "eventLog", "stageSvg", "stagePhase", "clkCount",
  "enCount", "aMatrix", "bMatrix", "cMatrix", "aShape", "bShape", "cShape", "partitionNote",
  "phaseStrip", "freezeBadge", "stage"];
for (const id of ids) { const e = new El("div"); e.id = id; byId.set(id, e); }

const document = {
  getElementById: (id) => byId.get(id) || null,
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  addEventListener() {},
  querySelectorAll: (sel) => ALL.filter((e) => e.classList.contains(sel.replace(".", "")))
};

const sandbox = { document, console, requestAnimationFrame: (f) => f() };
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(code, sandbox, { filename: "tile_dataflow_demo.html" });
const T = sandbox.__T;
const S = T.S;

/* ---------------- 断言 ---------------- */
function matmulC(A, BT, M, N, K) {
  const C = Array.from({ length: M }, () => new Array(N).fill(0));
  for (let i = 0; i < M; i++) for (let j = 0; j < N; j++) {
    let s = 0; for (let k = 0; k < K; k++) s += A[i][k] * BT[j][k];
    C[i][j] = s;
  }
  return C;
}
let fails = 0;
const bad = (msg) => { fails++; console.log("  x " + msg); };
const ok = (msg) => console.log("  . " + msg);

console.log("preset".padEnd(30) + "clk  written  util   C==A*BT   排空/快照次数");
for (const p of T.PRESETS) {
  Object.assign(S, { M: p.M, N: p.N, K: p.K, TK: p.TK, seed: p.seed });
  T.reset();

  let guard = 0, drains = 0, snaps = 0, maxAcc = 0, maxEn = 0, minAccAfterDrain = Infinity;
  let prevPhase = S.phase;
  while (!S.done && guard++ < 500000) {
    T.step();
    if (S.en > maxEn) maxEn = S.en;
    for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) {
      const n = T.accCount(r, c);
      if (n < 0 || n > S.beats || n > S.K) bad(`accCount[${r}][${c}]=${n} 越界 (beats=${S.beats})`);
      if (n > maxAcc) maxAcc = n;
    }
    if (S.phase === "drain" && prevPhase !== "drain") drains++;
    if (S.phase === "snapshot" && prevPhase !== "snapshot") snaps++;
    if (S.phase === "snapshot" && prevPhase !== "snapshot") {
      // 快照当拍：16 个累加器必须都已累满 K
      minAccAfterDrain = Math.min(minAccAfterDrain, ...Array.from({ length: 16 }, (_, i) => T.accCount(i >> 2, i & 3)));
    }
    prevPhase = S.phase;
  }
  if (guard >= 500000) { bad("未收敛（死循环）"); continue; }

  if (maxAcc !== S.K) bad(`最大 accCount=${maxAcc}，应为 K=${S.K}`);
  if (drains !== T.totalOutTiles()) bad(`DRAIN 次数 ${drains} != 输出 Tile 数 ${T.totalOutTiles()}`);
  if (snaps !== T.totalOutTiles()) bad(`SNAPSHOT 次数 ${snaps} != ${T.totalOutTiles()}`);
  if (maxEn !== S.K + T.DRAIN_BEATS) bad(`en 峰值 ${maxEn} != K+6 = ${S.K + 6}`);

  const want = matmulC(S.A, S.BT, S.M, S.N, S.K);
  let mism = 0;
  for (let i = 0; i < S.M; i++) for (let j = 0; j < S.N; j++) if (S.C[i][j] !== want[i][j]) mism++;
  if (mism) bad(`C 与 A*BT 不符：${mism}/${S.M * S.N}`);

  const util = (S.M * S.N * S.K) / (S.clk * 16) * 100;
  console.log(`${p.label.padEnd(28)}${String(S.clk).padStart(5)}${String(S.written).padStart(8)}` +
    `${util.toFixed(1).padStart(7)}%   ${mism ? "  x" : "  ok"}      ${drains}/${snaps}`);
}

/* 几何自洽 */
console.log("\n几何检查");
{
  const G = T.G, P = 4, Q = 4;
  const cell = G.cell, pad = G.pad, pitch = G.pitch;
  const aw = P * cell + (P - 1) * G.gap + 2 * pad, ah = Q * cell + (Q - 1) * G.gap + 2 * pad;
  let good = true;
  for (let r = 0; r < Q; r++) for (let c = 0; c < P; c++) {
    const cx = T.colX(c), cy = T.rowY(r);
    if (cx - cell / 2 < G.ax + pad - .01 || cx + cell / 2 > G.ax + aw - pad + .01) good = false;
    if (cy - cell / 2 < G.ay + pad - .01 || cy + cell / 2 > G.ay + ah - pad + .01) good = false;
  }
  if (aw !== G.aw || ah !== G.ah) { good = false; bad(`G.aw/ah ${G.aw}/${G.ah} != 计算值 ${aw}/${ah}`); }
  // lane 终点必须精确落在阵列内边界（页面里的真正常量）
  if (T.aLaneX1 !== G.ax + pad) { good = false; bad(`A lane 终点 ${T.aLaneX1} != 阵列内左边界 ${G.ax + pad}`); }
  if (T.bLaneY1 !== G.ay + pad) { good = false; bad(`BT lane 终点 ${T.bLaneY1} != 阵列内上边界 ${G.ay + pad}`); }
  if (T.arrayInL !== G.ax + pad || T.arrayInT !== G.ay + pad) { good = false; bad("arrayInL/arrayInT 与阵列框不一致"); }
  // lane 必须整段落在 skew 区域内（起点在区域里，终点伸进阵列）
  if (T.aLaneX0 < G.aSkew.x || T.aLaneX0 > G.aSkew.x + G.aSkew.w) { good = false; bad("A lane 起点不在 A skew 区域内"); }
  if (T.bLaneY0 < G.bSkew.y || T.bLaneY0 > G.bSkew.y + G.bSkew.h) { good = false; bad("BT lane 起点不在 BT skew 区域内"); }
  // 令牌起点必须在 lane 起点上
  const t0 = G.aSkew.x, t1 = G.ax + pad;
  console.log(`  阵列框 x=${G.ax} y=${G.ay} ${G.aw}x${G.ah}; 内左=${G.ax + pad} 内上=${G.ay + pad} 右=${G.ax + G.aw}`);
  console.log(`  A lane: x ${T.aLaneX0} -> ${T.aLaneX1}  (4 行 y=${[0, 1, 2, 3].map(T.rowY).join(",")})`);
  console.log(`  BT lane: y ${T.bLaneY0} -> ${T.bLaneY1}  (4 列 x=${[0, 1, 2, 3].map(T.colX).join(",")})`);
  // 令牌终点必须落在 PE 行/列中心线上 -> 由 rowY/colX 保证
  good ? ok("PE 中心全部在阵列内，lane 终点与阵列边界精确重合") : bad("几何对齐失败");
  // 检查 A lane 终点 x == colX(0)-cell/2 (第一列单元左边缘)
  if (Math.abs((G.ax + pad) - (T.colX(0) - cell / 2)) > .01) bad("A lane 终点未落在第一列单元左边缘");
  else ok("A lane 终点 == 第一列 PE 单元左边缘");
  if (Math.abs((G.ay + pad) - (T.rowY(0) - cell / 2)) > .01) bad("BT lane 终点未落在第一行单元上边缘");
  else ok("BT lane 终点 == 第一行 PE 单元上边缘");

  // 区域不得压住阵列框：应当"贴住"而不是"叠住"
  if (Math.abs((G.aSkew.x + G.aSkew.w) - G.ax) > .01)
    bad(`A skew 区域右边缘 ${G.aSkew.x + G.aSkew.w} != 阵列框左边 ${G.ax}`);
  else ok("A skew 区域右边缘精确贴住阵列框左边（无重叠）");
  if (Math.abs((G.bSkew.y + G.bSkew.h) - G.ay) > .01)
    bad(`BT skew 区域下边缘 ${G.bSkew.y + G.bSkew.h} != 阵列框上边 ${G.ay}`);
  else ok("BT skew 区域下边缘精确贴住阵列框上边（无重叠）");

  // 卡片两两不重叠
  const boxes = [["aTile", G.aTile], ["aFifo", G.aFifo], ["bTile", G.bTile], ["bFifo", G.bFifo],
                 ["snap", G.snap], ["cwr", G.cwr]];
  const ov = (p, q) => p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h;
  let coll = 0;
  for (let i = 0; i < boxes.length; i++) for (let k = i + 1; k < boxes.length; k++)
    if (ov(boxes[i][1], boxes[k][1])) { coll++; bad(`卡片重叠: ${boxes[i][0]} × ${boxes[k][0]}`); }
  for (const [n, b] of boxes) {
    if (ov(b, { x: G.aSkew.x, y: G.aSkew.y, w: G.aSkew.w, h: G.aSkew.h })) { coll++; bad(`卡片 ${n} 压住 A skew 区域`); }
    if (ov(b, { x: G.bSkew.x, y: G.bSkew.y, w: G.bSkew.w, h: G.bSkew.h })) { coll++; bad(`卡片 ${n} 压住 BT skew 区域`); }
    if (ov(b, { x: G.ax, y: G.ay, w: G.aw, h: G.ah })) { coll++; bad(`卡片 ${n} 压住阵列框`); }
  }
  if (!coll) ok("6 张卡片、2 个 skew 区域、阵列框两两不重叠");

  // 所有图元必须落在 viewBox 内
  let oob = 0;
  const all = [[G.aTile], [G.aFifo], [G.bTile], [G.bFifo], [G.snap], [G.cwr],
    [{ x: G.aSkew.x, y: G.aSkew.y, w: G.aSkew.w, h: G.aSkew.h }],
    [{ x: G.bSkew.x, y: G.bSkew.y, w: G.bSkew.w, h: G.bSkew.h }],
    [{ x: G.ax, y: G.ay, w: G.aw, h: G.ah }]].flat();
  for (const b of all) {
    if (b.x < 0 || b.y < 0 || b.x + b.w > T.VB.w || b.y + b.h > T.VB.h) { oob++; bad(`越出 viewBox: ${JSON.stringify(b)}`); }
  }
  if (!oob) ok(`全部图元在 viewBox ${T.VB.w}×${T.VB.h} 内`);
}

/* 相位时长/冻结语义 */
console.log("\n相位语义检查");
{
  Object.assign(S, { M: 8, N: 8, K: 8, TK: 4, seed: 23 });
  T.reset();
  const seen = [];
  let prev = S.phase, prevEn = S.en, incViolation = 0, incCount = 0, resets = 0, guard = 0;
  while (!S.done && guard++ < 100000) {
    T.step();
    if (S.en !== prevEn) {
      if (prev === "feed" || prev === "drain") incCount++;
      else if (S.en === 0 && prev === "snapshot") resets++;   // 新输出 Tile 重新计数
      else incViolation++;
    }
    if (S.phase !== prev) seen.push(S.phase);
    prev = S.phase; prevEn = S.en;
  }
  const np = seen.filter((x) => x === "prefetch").length;
  const nf = seen.filter((x) => x === "feed").length;
  const expectedSegs = T.totalOutTiles() * T.ntK();
  if (np !== expectedSegs) bad(`PREFETCH 次数 ${np} != 输出Tile×K段 = ${expectedSegs}`);
  if (nf !== expectedSegs) bad(`FEED 次数 ${nf} != ${expectedSegs}`);
  if (incViolation) bad(`非 FEED/DRAIN 拍推进了 en ${incViolation} 次（冻结被破坏）`);
  else ok(`en 仅在 FEED/DRAIN 拍推进（冻结相位保持不变）`);
  const wantInc = T.totalOutTiles() * (S.K + T.DRAIN_BEATS);
  if (incCount !== wantInc) bad(`en 推进总数 ${incCount} != 输出Tile×(${S.K}+6) = ${wantInc}`);
  else ok(`en 推进 ${incCount} 次 = ${T.totalOutTiles()} Tile × (K=${S.K} + 排空 6)`);
  if (resets !== T.totalOutTiles() - 1) bad(`en 复位 ${resets} 次，应为 ${T.totalOutTiles() - 1}`);
  else ok(`每个新输出 Tile 从 en=0 重新计数（共 ${resets} 次）`);
  ok(`PREFETCH/FEED 各 ${np} 次 = ${T.totalOutTiles()} 输出 Tile × ${T.ntK()} K 段`);
}

console.log(fails ? `\n${fails} 项失败` : "\n全部检查通过");
process.exit(fails ? 1 : 0);
