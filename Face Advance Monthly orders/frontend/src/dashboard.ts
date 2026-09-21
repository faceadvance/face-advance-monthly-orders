// หน้า "ยอดขาย" — การ์ดสรุป (สิทธิ์ Adm + Vm/Vw)
//
// เจ้านายเคาะรอบ 2 (2026-09-18): โละกราฟเทียบช่วง + รายทีม/รายคนออก เอาแค่การ์ด 4 ใบ
//   1. ยอดขายรวม (แยก ชำระแล้ว / รอชำระ)   2. ยอดแยกตามแบรนด์
//   3. ยอดตีกลับ                            4. จำนวนออเดอร์ (ทั้งหมด / ส่งสำเร็จ / ตีกลับ)
// ดีไซน์: ยกโครงการ์ด KPI หน้าออเดอร์มาทั้งชุด (.kcard + .khead/.kicon สี + .wm ลายน้ำสี + .kbig)
// ปฏิทินเลือกช่วง: คลาส .ed-cal* ชุดเดียวกับ audit log ใน EDITH
// คณิตล้วนอยู่ dashboard_calc.ts (เทสด้วย npm test)

import { el, icon, nf, THAI_MONTHS_FULL } from "./util";
import { fetchDashboard, fetchDashboardTeams, type DashGran, type DashResp } from "./api";
import { rangeLabel, growth, brandSplit, defaultRange, clampRange } from "./dashboard_calc";

const money = (n: number) => "฿" + nf(n);
const pct = (part: number, whole: number) => (whole > 0 ? (part / whole) * 100 : 0);

let toastFn: (m: string, ok?: boolean) => void = () => {};
let root: HTMLElement;
let teams: { id: number; name: string }[] = [];
let busy = false;
let firstDraw = true;
let globalsBound = false;

let calOpen = false;
let calDragging = false;
const cal = { view: new Date(), start: "", end: "" };

const st = {
  gran: "month" as DashGran,
  from: "", to: "",
  brand: null as string | null,
  team: null as number | null,
  bounds: { min: "", max: "" },
  data: null as DashResp | null,
};

// ───────── entry ─────────
export function renderDashboard(container: HTMLElement, opts: { toast: (m: string, ok?: boolean) => void }) {
  toastFn = opts.toast;
  root = container;
  firstDraw = true;
  if (!globalsBound) {
    globalsBound = true;
    document.addEventListener("mouseup", () => { calDragging = false; });
    document.addEventListener("click", (e) => {
      if (!calOpen) return;
      if ((e.target as HTMLElement | null)?.closest(".dbrangewrap")) return;
      calOpen = false;
      root.querySelector(".dbcal")?.setAttribute("hidden", "");
      root.querySelector(".dbrangefield")?.classList.remove("open");
    });
  }
  root.replaceChildren(skeleton());
  void boot();
}

async function boot() {
  try {
    if (!teams.length) {
      const t = await fetchDashboardTeams();
      if (t.authorized && t.ok) teams = t.teams ?? [];
    }
    await load();
  } catch {
    root.replaceChildren(errorBox("เชื่อมต่อไม่ได้ ลองรีเฟรชอีกครั้ง"));
  }
}

async function load() {
  if (busy) return;
  busy = true;
  try {
    const r = await fetchDashboard({ gran: st.gran, from: st.from || undefined, to: st.to || undefined, brand: st.brand, team: st.team });
    if (!r.authorized) { root.replaceChildren(errorBox("เซสชันหมดอายุ — เข้าระบบใหม่")); return; }
    if (!r.ok) { root.replaceChildren(errorBox(r.error === "forbidden" ? "บัญชีนี้ไม่มีสิทธิ์ดูหน้านี้" : "โหลดข้อมูลไม่สำเร็จ")); return; }
    if (r.empty) { root.replaceChildren(errorBox("ยังไม่มีข้อมูลยอดขายในระบบ")); return; }
    st.data = r;
    if (r.bounds) st.bounds = r.bounds;
    st.from = r.from ?? st.from; st.to = r.to ?? st.to;
    draw();
  } finally { busy = false; }
}

// ───────── แถบตัวกรอง ─────────
function controls(): HTMLElement {
  const bar = el("div", { class: "dbbar" });
  const seg = el("div", { class: "rlseg" });
  ([["year", "รายปี"], ["month", "รายเดือน"], ["day", "รายวัน"]] as [DashGran, string][]).forEach(([g, label]) => {
    const b = el("button", { class: "rlsegbtn" + (st.gran === g ? " on" : "") }, label) as HTMLButtonElement;
    b.addEventListener("click", () => {
      if (st.gran === g || busy) return;
      st.gran = g;
      const d = defaultRange(g, st.bounds.min, st.bounds.max);
      st.from = d.from; st.to = d.to;
      void load();
    });
    seg.append(b);
  });
  bar.append(el("span", { class: "dblab" }, "ช่วงเวลา"), seg, rangePicker());
  bar.append(el("span", { class: "dbsep" }));
  bar.append(pickPill("แบรนด์", st.brand ?? "ทุกแบรนด์",
    [["", "ทุกแบรนด์"], ["HOPEFUL", "HOPEFUL"], ["แบรนด์อื่นๆ", "แบรนด์อื่นๆ"]],
    (v) => { st.brand = v || null; void load(); }));
  const teamOpts: [string, string][] = [["", "ทุกทีม"], ...teams.map((t) => [String(t.id), t.name] as [string, string]), ["-1", "— ไม่มีทีม —"]];
  const curTeam = st.team == null ? "ทุกทีม" : st.team === -1 ? "— ไม่มีทีม —" : (teams.find((t) => t.id === st.team)?.name ?? "ทุกทีม");
  bar.append(pickPill("ทีม", curTeam, teamOpts, (v) => { st.team = v ? Number(v) : null; void load(); }));

  const reset = el("button", { class: "dbreset", type: "button" }, "กลับค่าเริ่มต้น") as HTMLButtonElement;
  reset.addEventListener("click", () => {
    st.brand = null; st.team = null;
    const d = defaultRange(st.gran, st.bounds.min, st.bounds.max);
    st.from = d.from; st.to = d.to;
    void load();
  });
  bar.append(el("span", { class: "dbgrow" }), reset);
  return bar;
}

/** ปฏิทินลากเลือกช่วง — คลาส .ed-cal* ชุดเดียวกับ audit log ของ EDITH */
function rangePicker(): HTMLElement {
  const TH_DOW = ["อา", "จ", "อ", "พ", "พฤ", "ศ", "ส"];
  const lo = () => (cal.start && cal.end && cal.start > cal.end ? cal.end : cal.start);
  const hi = () => (cal.start && cal.end && cal.start > cal.end ? cal.start : cal.end);
  const fmtTh = (ds: string) => { const [, m, d] = ds.split("-"); return `${+d} ${THAI_MONTHS_FULL[+m - 1]}`; };

  const panel = el("div", { class: "ed-cal dbcal" });
  const title = el("span", { class: "ed-cal-title" });
  const prev = el("button", { class: "ed-cal-nav", type: "button", "aria-label": "เดือนก่อน" }, icon("i-chev-l")) as HTMLButtonElement;
  const next = el("button", { class: "ed-cal-nav", type: "button", "aria-label": "เดือนถัดไป" }, icon("i-chev-r")) as HTMLButtonElement;
  const grid = el("div", { class: "ed-cal-grid" });
  const lbl = el("div", { class: "ed-cal-range" });
  const cells = new Map<string, HTMLElement>();

  function paint() {
    const a = lo(), b = hi();
    for (const [ds, c] of cells) {
      c.classList.toggle("sel", !!a && (ds === a || ds === b));
      c.classList.toggle("inrange", !!a && !!b && a !== b && ds > a && ds < b);
    }
    lbl.textContent = a && b ? (a === b ? fmtTh(a) : `${fmtTh(a)} – ${fmtTh(b)}`) : "ลากเลือกช่วงวันบนปฏิทิน";
  }
  function build() {
    title.textContent = `${THAI_MONTHS_FULL[cal.view.getMonth()]} ${cal.view.getFullYear()}`;
    grid.textContent = ""; cells.clear();
    const y = cal.view.getFullYear(), mo = cal.view.getMonth();
    for (let i = 0; i < new Date(y, mo, 1).getDay(); i++) grid.append(el("span", { class: "ed-cal-empty" }));
    const days = new Date(y, mo + 1, 0).getDate();
    for (let d = 1; d <= days; d++) {
      const ds = `${y}-${String(mo + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
      const off = ds < st.bounds.min || ds > st.bounds.max;   // วันที่ไม่มีข้อมูล = กดไม่ได้
      const c = el("span", { class: "ed-cal-day" + (off ? " ed-cal-off" : "") }, String(d));
      if (!off) {
        c.addEventListener("mousedown", (e) => { e.preventDefault(); calDragging = true; cal.start = ds; cal.end = ds; paint(); });
        c.addEventListener("mouseenter", () => { if (calDragging) { cal.end = ds; paint(); } });
      }
      cells.set(ds, c); grid.append(c);
    }
    paint();
  }
  prev.addEventListener("click", (e) => { e.stopPropagation(); cal.view = new Date(cal.view.getFullYear(), cal.view.getMonth() - 1, 1); build(); });
  next.addEventListener("click", (e) => { e.stopPropagation(); cal.view = new Date(cal.view.getFullYear(), cal.view.getMonth() + 1, 1); build(); });

  const dow = el("div", { class: "ed-cal-dow" });
  for (const d of TH_DOW) dow.append(el("span", {}, d));

  const quick = el("div", { class: "dbquick" });
  ([["7 วันล่าสุด", 7], ["30 วันล่าสุด", 30]] as [string, number][]).forEach(([t, n]) => {
    const b = el("button", { class: "dbquickbtn", type: "button" }, t) as HTMLButtonElement;
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      const end = new Date(st.bounds.max + "T00:00:00");
      const s0 = new Date(end); s0.setDate(s0.getDate() - (n - 1));
      const iso = (x: Date) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}`;
      const c = clampRange(iso(s0), st.bounds.max, st.bounds.min, st.bounds.max);
      st.from = c.from; st.to = c.to; calOpen = false;
      void load();
    });
    quick.append(b);
  });

  const apply = el("button", { class: "btn dbcalapply", type: "button" }, "ใช้ช่วงนี้") as HTMLButtonElement;
  apply.addEventListener("click", (e) => {
    e.stopPropagation();
    if (!cal.start || !cal.end) { toastFn("ลากเลือกช่วงวันบนปฏิทินก่อน", false); return; }
    const c = clampRange(lo(), hi(), st.bounds.min, st.bounds.max);
    st.from = c.from; st.to = c.to; calOpen = false;
    void load();
  });

  panel.append(el("div", { class: "ed-cal-head" }, prev, title, next), dow, grid, lbl, quick, apply);

  const field = el("button", { class: "pill dbrangefield", type: "button" },
    icon("i-cal"), el("span", {}, rangeLabel(st.from, st.to, st.gran)), icon("i-caret")) as HTMLButtonElement;
  const setOpen = (o: boolean) => {
    calOpen = o; panel.hidden = !o; field.classList.toggle("open", o);
    if (o) { cal.start = st.from; cal.end = st.to; cal.view = new Date(st.to + "T00:00:00"); build(); }
  };
  field.addEventListener("click", (e) => { e.stopPropagation(); setOpen(!calOpen); });
  setOpen(calOpen);
  return el("div", { class: "dbrangewrap" }, field, panel);
}

function pickPill(label: string, cur: string, opts: [string, string][], onPick: (v: string) => void): HTMLElement {
  const wrap = el("label", { class: "pill dbsel" }, el("span", { class: "dbsellab" }, label), el("span", {}, cur), icon("i-chev"));
  const sel = el("select", { class: "dbselinput" }) as HTMLSelectElement;
  for (const [v, t] of opts) {
    const o = el("option", { value: v }, t) as HTMLOptionElement;
    if (t === cur) o.selected = true;
    sel.append(o);
  }
  sel.addEventListener("change", () => onPick(sel.value));
  wrap.append(sel);
  return wrap;
}

// ───────── การ์ด ─────────
/** โครงการ์ด = เหมือนการ์ด KPI หน้าออเดอร์: ลายน้ำสี + ชิปไอคอนสี + หัวข้อ + เนื้อ */
function card(color: "blue" | "green" | "red" | "amber", ic: string, title: string, ...body: Node[]): HTMLElement {
  const c = el("div", { class: `kcard t${color} dbcard` });
  const wm = icon(ic); wm.setAttribute("class", `wm ${color}`);
  c.append(wm, el("div", { class: "khead" },
    el("div", { class: `kicon ${color}` }, icon(ic)),
    el("div", { class: "ktitle" }, title)));
  c.append(...body);
  return c;
}

/** แถวย่อยในการ์ด: ป้าย · ตัวเลข · แถบสัดส่วน · หมายเหตุ */
function statRow(label: string, value: string, ratio: number, color: string, note?: string): HTMLElement {
  const r = el("div", { class: "dbsr" });
  r.append(el("div", { class: "dbsrh" },
    el("i", { class: "dbdot", style: `background:${color}` }),
    el("span", { class: "dbsrl" }, label), el("b", { class: "dbsrv num" }, value)));
  r.append(el("div", { class: "dbsrb" }, el("i", { style: `--w:${Math.max(1.2, Math.max(0, Math.min(1, ratio)) * 100).toFixed(1)}%;background:${color}` })));
  if (note) r.append(el("div", { class: "dbsrn" }, note));
  return r;
}

/**
 * แถวแบรนด์ — แถบเดียวยาวตามสัดส่วนของแบรนด์ แล้วในแถบแบ่งสี ชำระแล้ว(เขียว)/รอชำระ(เหลือง)
 * อ่านได้ 2 ชั้นในที่เดียว: แบรนด์ไหนใหญ่กว่า · แบรนด์นั้นเก็บเงินครบแค่ไหน
 */
function brandRow(o: {
  name: string; dot: string; sales: number; paid: number; waiting: number;
  orders: number; shareOfAll: number;
}): HTMLElement {
  const r = el("div", { class: "dbbr" });
  r.append(el("div", { class: "dbbrh" },
    el("i", { class: "dbdot", style: `background:${o.dot}` }),
    el("span", { class: "dbbrn" }, o.name),
    el("b", { class: "dbbrv num" }, money(o.sales)),
    el("span", { class: "dbbrp num" }, (o.shareOfAll * 100).toFixed(1) + "%")));

  const track = el("div", { class: "dbbrb" });
  const fill = el("div", { class: "dbbrbf", style: `--w:${(o.shareOfAll * 100).toFixed(1)}%` });
  const pPaid = pct(o.paid, o.sales), pWait = pct(o.waiting, o.sales);
  if (pPaid > 0) fill.append(el("i", { class: "seg paid", style: `width:${pPaid.toFixed(2)}%` }));
  if (pWait > 0) fill.append(el("i", { class: "seg wait", style: `width:${Math.max(1.2, pWait).toFixed(2)}%` }));
  track.append(fill);
  r.append(track);

  r.append(el("div", { class: "dbbrf" },
    el("span", {}, el("i", { class: "dbdot sm", style: "background:var(--ok)" }),
      "ชำระแล้ว ", el("b", { class: "num" }, money(o.paid))),
    el("span", {}, el("i", { class: "dbdot sm", style: "background:var(--warn)" }),
      "รอชำระ ", el("b", { class: "num" }, money(o.waiting))),
    el("span", { class: "dbbrn2" }, `${nf(o.orders)} รายการ`)));
  return r;
}

function cards(d: DashResp): HTMLElement {
  const wrap = el("div", { class: "dbcards" });
  const s = d.sales ?? { total: 0, paid: 0, waiting: 0, orders: 0, orders_paid: 0, orders_waiting: 0 };
  const ret = d.returns ?? { amount: 0, orders: 0 };
  const cnt = d.counts ?? { all: 0, done: 0, returned: 0 };
  const g = growth(s.total, d.prev?.total ?? 0);
  const bs = d.brands ?? [];
  const hope = bs.find((b) => b.name === "HOPEFUL");
  const other = bs.find((b) => b.name === "แบรนด์อื่นๆ");

  // ── 1) ยอดขายรวม (แยก ชำระแล้ว / รอชำระ) ──
  const big = el("div", { class: "kbig num dbbig" }, money(s.total));
  big.append(g != null
    ? el("span", { class: "dbdelta " + (g >= 0 ? "up" : "dn") }, (g >= 0 ? "▲ " : "▼ ") + Math.abs(g).toFixed(1) + "%")
    : el("span", { class: "dbdelta flat", title: "ช่วงก่อนหน้าไม่มีข้อมูลให้เทียบ" }, "เทียบไม่ได้"));
  wrap.append(card("blue", "i-coin", "ยอดขายรวม", big,
    el("div", { class: "dbcs" }, `${nf(s.orders)} รายการ · ${rangeLabel(st.from, st.to, st.gran)}`),
    el("div", { class: "dbsplit" },
      statRow("ชำระแล้ว", money(s.paid), pct(s.paid, s.total) / 100, "var(--ok)",
        `${nf(s.orders_paid)} รายการ · ${pct(s.paid, s.total).toFixed(1)}% ของยอดขาย`),
      statRow("รอชำระ", money(s.waiting), pct(s.waiting, s.total) / 100, "var(--warn)",
        `${nf(s.orders_waiting)} รายการ · ${pct(s.waiting, s.total).toFixed(1)}% ของยอดขาย`))));

  // ── 2) ยอดแยกตามแบรนด์ (มี ชำระแล้ว / รอชำระ ในแต่ละแบรนด์) ──
  const sp = brandSplit(hope?.sales ?? 0, other?.sales ?? 0);
  wrap.append(card("green", "i-donut", "ยอดแยกตามแบรนด์",
    el("div", { class: "dbbrwrap" },
      brandRow({ name: "HOPEFUL", dot: "var(--primary)", sales: hope?.sales ?? 0,
        paid: hope?.paid ?? 0, waiting: hope?.waiting ?? 0, orders: hope?.orders ?? 0, shareOfAll: sp.h }),
      brandRow({ name: "แบรนด์อื่นๆ", dot: "var(--db-other)", sales: other?.sales ?? 0,
        paid: other?.paid ?? 0, waiting: other?.waiting ?? 0, orders: other?.orders ?? 0, shareOfAll: sp.o })),
    el("div", { class: "dbcs dbfootnote" }, "ความยาวแถบ = สัดส่วนของยอดขายรวม · สีในแถบ = ชำระแล้ว / รอชำระ")));

  // ── 3) ยอดตีกลับ ──
  wrap.append(card("red", "i-return", "ยอดตีกลับ",
    el("div", { class: "kbig num dbbig dbneg" }, "−" + money(ret.amount)),
    el("div", { class: "dbcs" }, `${nf(ret.orders)} รายการ · ${pct(ret.amount, s.total).toFixed(2)}% ของยอดขาย`),
    el("div", { class: "dbsplit" },
      statRow("HOPEFUL", money(hope?.ret_amount ?? 0), pct(hope?.ret_amount ?? 0, ret.amount) / 100, "var(--primary)", `${nf(hope?.ret_orders ?? 0)} รายการ`),
      statRow("แบรนด์อื่นๆ", money(other?.ret_amount ?? 0), pct(other?.ret_amount ?? 0, ret.amount) / 100, "var(--db-other)", `${nf(other?.ret_orders ?? 0)} รายการ`))));

  // ── 4) จำนวนออเดอร์ (ทั้งหมด / ส่งสำเร็จ / ตีกลับ) ──
  const rest = Math.max(0, cnt.all - cnt.done - cnt.returned);
  const list = el("div", { class: "dbcntlist" },
    el("div", { class: "kbig num dbbig-sm" }, nf(cnt.all) + " รายการ"),
    el("div", { class: "dbcs" }, "ออเดอร์ทั้งหมดในช่วงนี้"),
    countLine("var(--ok)", "ส่งสำเร็จ", cnt.done, cnt.all),
    countLine("var(--bad)", "ตีกลับ", cnt.returned, cnt.all));
  if (rest > 0) list.append(countLine("#CBD5E1", "อื่นๆ", rest, cnt.all, "กำลังส่ง · มีปัญหา · ยกเลิก"));
  wrap.append(card("amber", "i-truck", "จำนวนออเดอร์",
    el("div", { class: "dbcntrow" },
      donut([{ v: cnt.done, c: "var(--ok)" }, { v: cnt.returned, c: "var(--bad)" }, { v: rest, c: "#CBD5E1" }], cnt.all),
      list)));
  return wrap;
}

function countLine(color: string, label: string, v: number, all: number, note?: string): HTMLElement {
  const line = el("div", { class: "dbcnti" },
    el("i", { class: "dbdot", style: `background:${color}` }),
    el("span", { class: "dbcntl" }, label),
    el("b", { class: "num" }, nf(v)),
    el("span", { class: "dbcntp num" }, pct(v, all).toFixed(1) + "%"));
  if (note) line.append(el("span", { class: "dbcntn" }, note));
  return line;
}

/** โดนัทวาดด้วย conic-gradient — ไม่ต้องใช้ SVG หรือ library */
function donut(parts: { v: number; c: string }[], total: number): HTMLElement {
  if (!(total > 0)) return el("div", { class: "dbringwrap" }, el("div", { class: "dbring empty" }));
  let acc = 0;
  const stops: string[] = [];
  for (const p of parts) {
    if (p.v <= 0) continue;
    const from = (acc / total) * 100;
    acc += p.v;
    stops.push(`${p.c} ${from.toFixed(2)}% ${((acc / total) * 100).toFixed(2)}%`);
  }
  // วงแหวนถูก mask → ต้องวางตัวเลขเป็นพี่น้อง ไม่ใช่ลูก ไม่งั้นถูกตัดหายไปด้วย
  return el("div", { class: "dbringwrap" },
    el("div", { class: "dbring", style: `background:conic-gradient(${stops.join(",")})` }),
    el("span", { class: "dbringmid" },
      el("b", { class: "num" }, pct(parts[0].v, total).toFixed(0) + "%"),
      el("small", {}, "ส่งสำเร็จ")));
}

// ───────── วาดหน้า ─────────
function draw() {
  if (!st.data) return;
  const page = el("div", { class: "dbwrap" + (firstDraw ? "" : " nofx") });
  page.append(controls(), cards(st.data));
  root.replaceChildren(page);
  firstDraw = false;
}

function skeleton(): HTMLElement {
  return el("div", { class: "dbwrap" },
    el("div", { class: "dbcards" }, ...[0, 1, 2, 3].map(() => el("div", { class: "kcard dbcard dbskel" }))));
}

function errorBox(msg: string): HTMLElement {
  return el("div", { class: "dberr" }, icon("i-alert"), el("span", {}, msg));
}
