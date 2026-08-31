import "./style.css";
import { fetchMonths, fetchOrders, authLogout } from "./api";
import { renderLogin } from "./auth";
import { getToken, clearSession, displayName } from "./session";
import type { Order, OrdersResponse, Kpi, Daily } from "./types";
import {
  el, icon, nf, dmy, monthLabel, splitNameCode, deliveryBadge, paymentBadge,
  cellValue, searchBlob, paymentMethodLabel, THAI_MONTHS_SHORT, THAI_MONTHS_FULL, type ColKey,
} from "./util";

const MAX_SELECT = 30;

interface Column { key: ColKey; label: string; align?: "right" | "center"; thClass?: string; }
const COLUMNS: Column[] = [
  { key: "date", label: "วันที่", thClass: "datehead" },
  { key: "phone", label: "เบอร์โทร" },
  { key: "customer_name", label: "ชื่อลูกค้า" },
  { key: "address", label: "ที่อยู่" },
  { key: "carrier", label: "ขนส่ง" },
  { key: "tracking_no", label: "เลขแทร็ค" },
  { key: "payment_method", label: "ช่องทางชำระ", align: "right" },
  { key: "total_sales", label: "ยอดขาย", align: "right" },
  { key: "delivery_status", label: "สถานะจัดส่ง", align: "center" },
  { key: "payment_status", label: "สถานะชำระ", align: "center" },
  { key: "note", label: "หมายเหตุ" },
];

// ---------- state ----------
const state = {
  month: "",
  data: null as OrdersResponse | null,
  monthsWithData: new Set<string>(),
  pickerYear: new Date().getFullYear(),
  search: "",
  sort: null as { col: ColKey; dir: "asc" | "desc" } | null,
  filters: new Map<ColKey, Set<string>>(),
  selected: new Set<number>(),
};

let currentVisible: Order[] = [];
const tickEls = new Map<number, HTMLElement>();
let copyBarEl: HTMLElement | null = null;
let headHHEl: HTMLElement | null = null;

// ---------- helpers ----------
const $ = <T extends HTMLElement>(sel: string) => document.querySelector(sel) as T;

function toast(msg: string, ok = true) {
  const t = $("#toast");
  t.textContent = "";
  t.append(icon(ok ? "i-check" : "i-x"), msg);
  t.className = "toast" + (ok ? " ok" : "");
  t.hidden = false;
  window.clearTimeout((toast as any)._t);
  (toast as any)._t = window.setTimeout(() => (t.hidden = true), 1800);
}

// today (เวลาไทย) → วันปัจจุบันของเดือนที่กำลังดู (ถ้าไม่ใช่เดือนนี้ = ครบทั้งเดือน)
function currentDayOfMonth(d: OrdersResponse): number {
  if (d.month === d.today.slice(0, 7)) return Number(d.today.slice(8, 10));
  return d.days_in_month; // เดือนอดีต = ทุกวันผ่านไปแล้ว
}

// ======================================================
//  KPI
// ======================================================
// get_orders คืนแค่ orders → คำนวณ KPI + กราฟรายวันที่ frontend
function computeKpiDaily(d: OrdersResponse) {
  const days = d.days_in_month;
  const daily: Daily = {
    exported: new Array(days).fill(0),
    sales_paid: new Array(days).fill(0),
    sales_unpaid: new Array(days).fill(0),
    returned: new Array(days).fill(0),
  };
  const kpi: Kpi = { exported_count: 0, sales_total: 0, sales_paid: 0, sales_unpaid: 0, returned_count: 0, returned_amount: 0 };
  for (const o of d.orders) {
    const idx = Number(o.date.slice(8, 10)) - 1;
    const amt = o.total_sales || 0;
    const inRange = idx >= 0 && idx < days;
    kpi.exported_count++;
    kpi.sales_total += amt;
    if (inRange) daily.exported[idx]++;
    if (o.payment_status === "ชำระแล้ว") { kpi.sales_paid += amt; if (inRange) daily.sales_paid[idx] += amt; }
    else if (o.payment_status === "รอชำระ") { kpi.sales_unpaid += amt; if (inRange) daily.sales_unpaid[idx] += amt; }
    if (o.delivery_status === "ตีกลับ") { kpi.returned_count++; kpi.returned_amount += amt; if (inRange) daily.returned[idx]++; }
  }
  d.kpi = kpi;
  d.daily = daily;
}

function renderKpi(d: OrdersResponse) {
  const root = $("#kpi");
  root.textContent = "";
  const days = d.days_in_month;
  const curDay = currentDayOfMonth(d);
  const isFuture = (i: number) => i + 1 > curDay;

  // --- การ์ด 1: จำนวนส่งออก ---
  const exp = d.daily.exported;
  const maxExp = Math.max(1, ...exp);
  const maxIdx = exp.indexOf(Math.max(...exp));
  const daysWithData = exp.filter((v) => v > 0).length;
  const avgExp = daysWithData ? Math.round(d.kpi.exported_count / daysWithData) : 0;
  const spark = el("div", { class: "spark" });
  for (let i = 0; i < days; i++) {
    // วันอนาคต หรือวันที่ไม่มีรายการ = ไม่มีแท่ง
    if (isFuture(i) || exp[i] === 0) { spark.append(el("span", { class: "empty" })); continue; }
    const h = Math.round((exp[i] / maxExp) * 100);
    spark.append(el("span", {
      class: exp[i] === Math.max(...exp) ? "hi" : "",
      style: `height:${h}%`,
    }));
  }
  const c1cap = d.kpi.exported_count
    ? `เฉลี่ย ${avgExp}/วัน · สูงสุด ${exp[maxIdx]} (${maxIdx + 1} ${THAI_MONTHS_SHORT[Number(d.month.slice(5, 7)) - 1]})`
    : "ยังไม่มีข้อมูลเดือนนี้";
  root.append(kcard("blue", "i-truck", "จำนวนส่งออก",
    el("div", {}, el("div", { class: "kbig num" }, nf(d.kpi.exported_count)),
      el("div", { class: "kunit" }, "ออเดอร์ที่ส่งจริงเดือนนี้")),
    spark, c1cap));

  // --- การ์ด 2: ยอดขาย ---
  const totalByDay = d.daily.sales_paid.map((p, i) => p + d.daily.sales_unpaid[i]);
  const maxTotal = Math.max(1, ...totalByDay);
  const chart2 = el("div", { class: "chart" });
  for (let i = 0; i < days; i++) {
    const tot = totalByDay[i];
    // วันอนาคต หรือวันที่ไม่มียอด = ไม่มีแท่ง
    if (isFuture(i) || tot === 0) { chart2.append(el("span", { class: "dbar empty" })); continue; }
    const h = Math.round((tot / maxTotal) * 100);
    const upH = Math.round((d.daily.sales_unpaid[i] / tot) * 100);
    const bar = el("span", { class: "dbar", style: `height:${Math.max(h, 3)}%` });
    if (upH > 0) bar.append(el("i", { class: "up", style: `height:${upH}%` }));
    chart2.append(bar);
  }
  const avgSales = Math.round(d.kpi.sales_total / days);
  // hero = ยอดที่ชำระแล้ว (เขียว) · ยอดขายรวม + รอชำระ ไปอยู่ขวาล่าง
  const mainPaid = el("div", { class: "kmain" });
  const bigPaid = el("div", { class: "kbig num", style: "color:#059669" });
  bigPaid.append(el("small", {}, "฿"), " " + nf(d.kpi.sales_paid));
  mainPaid.append(bigPaid, el("div", { class: "kunit" }, "ยอดที่ชำระแล้วเดือนนี้"));

  // รอชำระ + ยอดขายรวม = 2 คอลัมน์ (ตัวเลขบน/ป้ายล่าง) เหมือน detail การ์ดตีกลับ
  const detail2 = el("div", { class: "kdetail" },
    el("div", { class: "ksub" },
      el("div", {}, el("div", { class: "sv num", style: "color:#EA580C" }, `฿${nf(d.kpi.sales_unpaid)}`), el("div", { class: "l" }, "รอชำระ")),
      el("div", {}, el("div", { class: "sv num" }, `฿${nf(d.kpi.sales_total)}`), el("div", { class: "l" }, "ยอดขายรวม"))));

  const cap2 = el("div", { class: "kcap" });
  cap2.append("ยอดขายเฉลี่ยต่อวัน ", el("b", {}, `฿${nf(avgSales)}`), " (รวมยอดที่ยังไม่ชำระ)");
  root.append(kcardSplit("green", "i-wallet", "ยอดขาย", mainPaid, detail2, chart2, cap2));

  // --- การ์ด 3: ตีกลับ ---
  const ret = d.daily.returned;
  const maxRet = Math.max(1, ...ret);
  const chart3 = el("div", { class: "chart red" });
  for (let i = 0; i < days; i++) {
    // วันอนาคต หรือวันที่ไม่มีตีกลับ = ไม่มีแท่ง
    if (isFuture(i) || ret[i] === 0) { chart3.append(el("span", { class: "dbar empty" })); continue; }
    const h = Math.round((ret[i] / maxRet) * 100);
    chart3.append(el("span", { class: "dbar", style: `height:${Math.max(h, 3)}%` }));
  }
  const rate = d.kpi.exported_count ? (d.kpi.returned_count / d.kpi.exported_count) * 100 : 0;
  const ksub = el("div", { class: "ksub" },
    el("div", {}, el("div", { class: "sv num" }, nf(d.kpi.returned_count)), el("div", { class: "l" }, "จำนวนออเดอร์")),
    el("div", {}, el("div", { class: "sv num", style: "color:#DC2626" }, `${rate.toFixed(1)}%`), el("div", { class: "l" }, "อัตราตีกลับ")));
  const mainRed = el("div", { class: "kmain" },
    (() => { const b = el("div", { class: "kbig num", style: "color:#DC2626" }); b.append(el("small", {}, "฿"), " " + nf(d.kpi.returned_amount)); return b; })(),
    el("div", { class: "kunit" }, "ยอดตีกลับเดือนนี้"));
  root.append(kcardSplit("red", "i-return", "ตีกลับ", mainRed,
    el("div", { class: "kdetail" }, ksub), chart3, el("div", { class: "kcap", "aria-hidden": "true" }, " ")));
}

function kcard(color: string, ic: string, title: string, body: Node, chart: Node, caption: string): HTMLElement {
  const card = el("div", { class: `kcard t${color}` });
  const wm = icon(ic); wm.setAttribute("class", `wm ${color}`);
  card.append(wm,
    el("div", { class: "khead" }, el("div", { class: `kicon ${color}` }, icon(ic)), el("div", { class: "ktitle" }, title)),
    body,
    el("div", { class: "cbot" }, chart, el("div", { class: "kcap" }, caption)));
  return card;
}
function kcardSplit(color: string, ic: string, title: string, main: Node, detail: Node, chart: Node, caption: Node): HTMLElement {
  const card = el("div", { class: `kcard t${color}` });
  const wm = icon(ic); wm.setAttribute("class", `wm ${color}`);
  card.append(wm,
    el("div", { class: "khead" }, el("div", { class: `kicon ${color}` }, icon(ic)), el("div", { class: "ktitle" }, title)),
    el("div", { class: "krow2" }, main, detail),
    el("div", { class: "cbot" }, chart, caption));
  return card;
}
function salesMain(cur: string, val: string, unit: string): HTMLElement {
  const big = el("div", { class: "kbig num" }); big.append(el("small", {}, cur), " " + val);
  return el("div", { class: "kmain" }, big, el("div", { class: "kunit" }, unit));
}
function dot(color: string, label: string, val: string): HTMLElement {
  const s = el("span", {});
  s.append(el("span", { class: "ldot", style: `background:${color}` }), `${label} `, el("b", {}, val));
  return s;
}

// ======================================================
//  ตาราง
// ======================================================
function computeVisible(): Order[] {
  const d = state.data!;
  let rows = d.orders.slice();
  for (const [col, set] of state.filters) rows = rows.filter((o) => set.has(cellValue(o, col)));
  if (state.search.trim()) {
    const q = state.search.trim().toLowerCase();
    rows = rows.filter((o) => searchBlob(o).includes(q));
  }
  if (state.sort) {
    const { col, dir } = state.sort;
    rows.sort((a, b) => {
      let r: number;
      if (col === "total_sales") r = a.total_sales - b.total_sales;
      else if (col === "date") r = a.date < b.date ? -1 : a.date > b.date ? 1 : 0;
      else r = cellValue(a, col).localeCompare(cellValue(b, col), "th");
      return dir === "asc" ? r : -r;
    });
  }
  return rows;
}

function renderTable() {
  const d = state.data!;
  const rows = computeVisible();
  currentVisible = rows;
  tickEls.clear();

  const wrap = $("#tableWrap");
  wrap.textContent = "";
  const table = el("table");
  const thead = el("thead");
  const tr = el("tr");
  for (const col of COLUMNS) tr.append(buildTh(col));
  thead.append(tr);

  const tbody = el("tbody");
  if (rows.length === 0) {
    const td = el("td", { colspan: String(COLUMNS.length) });
    td.append(el("div", { class: "state" }, d.orders.length ? "ไม่มีรายการตรงกับตัวกรอง" : "ยังไม่มีออเดอร์ในเดือนนี้"));
    tbody.append(el("tr", {}, td));
  } else {
    for (const o of rows) tbody.append(buildRow(o));
  }
  table.append(thead, tbody);
  wrap.append(table);

  $("#tableMeta").textContent =
    `${nf(rows.length)} / ${nf(d.orders.length)} รายการ · คลิกกรวยที่หัวคอลัมน์เพื่อกรอง`;

  renderActiveFilters();
  updateSelectionUI();
}

function buildTh(col: Column): HTMLElement {
  const th = el("th", {});
  if (col.thClass) th.classList.add(col.thClass);
  if (col.align === "center") th.classList.add("c");
  if (col.align === "right") th.classList.add("rcol");
  const active = state.filters.has(col.key);
  if (active) th.classList.add("filtered");

  const hh = el("div", { class: "hh" });
  hh.append(col.label);
  const funnel = el("span", { class: "funnel" + (active ? " on" : "") }, icon("i-funnel"));
  funnel.addEventListener("click", (e) => { e.stopPropagation(); openFilter(th, col); });
  hh.append(funnel);
  th.append(hh);

  // คอลัมน์เลขแทร็ค: แถบก๊อป (โผล่เมื่อเลือก ≥1)
  if (col.key === "tracking_no") {
    headHHEl = hh;
    const bar = el("div", { class: "copybar" });
    bar.hidden = true;
    copyBarEl = bar;
    th.append(bar);
  }
  return th;
}

function buildRow(o: Order): HTMLElement {
  const tr = el("tr");
  // วันที่
  tr.append(el("td", { class: "datecell" }, dmy(o.date)));
  // เบอร์โทร
  tr.append(el("td", { class: "mono" }, o.phone || "—"));
  // ชื่อลูกค้า (+code)
  const { name, code } = splitNameCode(o.customer_name);
  const tdName = el("td", { class: "name" }, name || "—");
  if (code) tdName.append(" ", el("span", { class: "code" }, code));
  tr.append(tdName);
  // ที่อยู่
  tr.append(el("td", { class: "addr", title: o.address }, o.address || "—"));
  // ขนส่ง
  tr.append(el("td", {}, o.carrier || "—"));
  // เลขแทร็ค + ปุ่มติ๊ก
  tr.append(buildTrackCell(o));
  // ช่องทางชำระ (COD ย่อจาก เก็บเงินปลายทาง) — ชิดขวา
  tr.append(el("td", { class: "tar" }, paymentMethodLabel(o.payment_method) || "—"));
  // ยอดขาย
  tr.append(el("td", { class: "amount num" }, nf(o.total_sales)));
  // สถานะจัดส่ง
  tr.append(el("td", { class: "center" }, badge(deliveryBadge(o.delivery_status), o.delivery_status)));
  // สถานะชำระ
  tr.append(el("td", { class: "center" }, badge(paymentBadge(o.payment_status), o.payment_status)));
  // หมายเหตุ
  tr.append(el("td", { class: o.note ? "note mono" : "note" }, o.note || "—"));
  return tr;
}

function buildTrackCell(o: Order): HTMLElement {
  const td = el("td", {});
  if (!o.tracking_no) { td.append("—"); return td; }
  const inner = el("div", { class: "trackcell" });
  inner.append(el("span", { class: "mono" }, o.tracking_no));
  const tick = el("span", { class: "tick" }, icon("i-tick"));
  tick.title = "เลือกเพื่อคัดลอกเลขแทร็ค";
  tick.addEventListener("click", () => toggleTick(o.id));
  tickEls.set(o.id, tick);
  inner.append(tick);
  td.append(inner);
  return td;
}

function badge(b: { cls: string; icon: string }, text: string): HTMLElement {
  return el("span", { class: `badge ${b.cls}` }, icon(b.icon), text);
}

// ======================================================
//  เลือกเลขแทร็ค → คัดลอก
// ======================================================
function toggleTick(id: number) {
  if (state.selected.has(id)) state.selected.delete(id);
  else if (state.selected.size < MAX_SELECT) state.selected.add(id);
  else return; // ครบ 30 แล้ว
  updateSelectionUI();
}

function clearSelection() {
  if (state.selected.size) state.selected.clear();
}

function updateSelectionUI() {
  const count = state.selected.size;
  const full = count >= MAX_SELECT;
  // ปุ่มติ๊กแต่ละแถว
  for (const [id, tick] of tickEls) {
    const on = state.selected.has(id);
    tick.classList.toggle("on", on);
    tick.classList.toggle("disabled", full && !on);
  }
  // แถบก๊อปในหัวคอลัมน์
  if (!copyBarEl || !headHHEl) return;
  if (count === 0) {
    copyBarEl.hidden = true;
    headHHEl.hidden = false;
    return;
  }
  headHHEl.hidden = true;
  copyBarEl.hidden = false;
  copyBarEl.textContent = "";
  const btn = el("button", { class: "copybtn" }, icon("i-copy"), "คัดลอก");
  btn.append(el("span", { class: "cnt" }, String(count)));
  btn.addEventListener("click", doCopy);
  copyBarEl.append(btn);
  if (full) copyBarEl.append(el("span", { class: "maxbadge" }, "เลือกครบ 30 แล้ว"));
  const x = el("span", { class: "copyx", title: "ยกเลิกการเลือก" }, icon("i-close"));
  x.addEventListener("click", () => { clearSelection(); updateSelectionUI(); });
  copyBarEl.append(x);
}

async function doCopy() {
  // เรียงตามลำดับที่เห็นในตาราง (currentVisible)
  const nums = currentVisible
    .filter((o) => state.selected.has(o.id) && o.tracking_no)
    .map((o) => o.tracking_no);
  if (nums.length === 0) return;
  const text = nums.join(" ");
  const ok = await copyToClipboard(text);
  const btn = copyBarEl?.querySelector(".copybtn") as HTMLButtonElement | null;
  if (ok) {
    if (btn) {
      btn.classList.add("done");
      btn.textContent = "";
      btn.append(icon("i-check"), "คัดลอกแล้ว");
      window.setTimeout(() => updateSelectionUI(), 1200);
    }
    toast(`คัดลอกเลขแทร็ค ${nums.length} รายการแล้ว`);
  } else {
    toast("คัดลอกไม่สำเร็จ", false);
  }
}

async function copyToClipboard(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch { /* fallback */ }
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.append(ta);
    ta.select();
    const ok = document.execCommand("copy");
    ta.remove();
    return ok;
  } catch {
    return false;
  }
}

// ======================================================
//  ตัวกรองแบบ Google Sheets
// ======================================================
let openDrop: HTMLElement | null = null;
function closeDrop() { if (openDrop) { openDrop.remove(); openDrop = null; } }

function distinctValues(col: ColKey): { value: string; count: number }[] {
  const m = new Map<string, number>();
  for (const o of state.data!.orders) {
    const v = cellValue(o, col);
    m.set(v, (m.get(v) ?? 0) + 1);
  }
  const arr = [...m.entries()].map(([value, count]) => ({ value, count }));
  arr.sort((a, b) => {
    if (col === "total_sales") return Number(a.value) - Number(b.value);
    return a.value.localeCompare(b.value, "th");
  });
  return arr;
}

function openFilter(th: HTMLElement, col: Column) {
  if (openDrop && openDrop.dataset.col === col.key) { closeDrop(); return; }
  closeDrop();
  const values = distinctValues(col.key);
  const current = state.filters.get(col.key);
  // temp = ค่าที่ติ๊ก (ยังไม่กด "ใช้ตัวกรอง")
  const temp = new Set<string>(current ? current : values.map((v) => v.value));

  const drop = el("div", { class: "fdrop" });
  drop.dataset.col = col.key;
  openDrop = drop;

  // sort
  const sortSec = el("div", { class: "sec fsort" });
  const asc = el("a", { class: state.sort?.col === col.key && state.sort.dir === "asc" ? "act" : "" }, icon("i-sortaz"), "เรียง ก → ฮ");
  const desc = el("a", { class: state.sort?.col === col.key && state.sort.dir === "desc" ? "act" : "" }, icon("i-sortza"), "เรียง ฮ → ก");
  asc.addEventListener("click", () => { state.sort = { col: col.key, dir: "asc" }; closeDrop(); renderTable(); });
  desc.addEventListener("click", () => { state.sort = { col: col.key, dir: "desc" }; closeDrop(); renderTable(); });
  sortSec.append(asc, desc);
  drop.append(sortSec);

  // search values
  const searchSec = el("div", { class: "sec" });
  const fs = el("div", { class: "fsearch" }, icon("i-search"));
  const inp = el("input", { placeholder: "ค้นหาค่า..." }) as HTMLInputElement;
  fs.append(inp);
  searchSec.append(fs);
  drop.append(searchSec);

  // value list
  const listSec = el("div", { class: "sec" });
  const links = el("div", { class: "flinks" });
  const selAll = el("a", {}, "เลือกทั้งหมด");
  const clr = el("a", {}, "ล้าง");
  links.append(selAll, " · ", clr);
  const fvals = el("div", { class: "fvals" });
  listSec.append(links, fvals);
  drop.append(listSec);

  const rowEls: { value: string; row: HTMLElement; cbx: HTMLElement }[] = [];
  function renderVals(filterText = "") {
    fvals.textContent = "";
    rowEls.length = 0;
    const q = filterText.trim().toLowerCase();
    for (const { value, count } of values) {
      const label = value === "" ? "(ว่าง)" : value;
      if (q && !label.toLowerCase().includes(q)) continue;
      const cbx = el("span", { class: "cbx" + (temp.has(value) ? "" : " off") }, icon("i-tick"));
      const row = el("div", { class: "fval" }, cbx, label, el("span", { class: "cnt" }, nf(count)));
      row.addEventListener("click", () => {
        if (temp.has(value)) { temp.delete(value); cbx.classList.add("off"); }
        else { temp.add(value); cbx.classList.remove("off"); }
      });
      fvals.append(row);
      rowEls.push({ value, row, cbx });
    }
  }
  renderVals();
  inp.addEventListener("input", () => renderVals(inp.value));
  selAll.addEventListener("click", () => { for (const v of values) temp.add(v.value); rowEls.forEach((r) => r.cbx.classList.remove("off")); });
  clr.addEventListener("click", () => { temp.clear(); rowEls.forEach((r) => r.cbx.classList.add("off")); });

  // actions
  const actions = el("div", { class: "factions" });
  const cancel = el("button", { class: "fbtn" }, "ยกเลิก");
  const apply = el("button", { class: "fbtn p" }, "ใช้ตัวกรอง");
  cancel.addEventListener("click", closeDrop);
  apply.addEventListener("click", () => {
    // ครบทุกค่า = ไม่กรอง
    if (temp.size === values.length) state.filters.delete(col.key);
    else state.filters.set(col.key, new Set(temp));
    clearSelection();          // กรอง → ล้างการเลือก
    closeDrop();
    renderTable();
  });
  actions.append(cancel, apply);
  drop.append(actions);

  th.append(drop);
  inp.focus();
}

function renderActiveFilters() {
  const root = $("#activefilters");
  root.textContent = "";
  if (state.filters.size === 0) { root.hidden = true; return; }
  root.hidden = false;
  root.append(el("span", {}, "ตัวกรอง:"));
  for (const [col, set] of state.filters) {
    const label = COLUMNS.find((c) => c.key === col)!.label;
    const vals = [...set].map((v) => (v === "" ? "(ว่าง)" : v)).join(", ");
    const chip = el("span", { class: "chip" }, `${label}: ${vals.length > 40 ? vals.slice(0, 40) + "…" : vals}`, icon("i-x", "width:.85em"));
    chip.addEventListener("click", () => { state.filters.delete(col); clearSelection(); renderTable(); });
    root.append(chip);
  }
  const clall = el("span", { class: "clearall" }, "ล้างทั้งหมด");
  clall.addEventListener("click", () => { state.filters.clear(); clearSelection(); renderTable(); });
  root.append(clall);
}

// ======================================================
//  Month picker
// ======================================================
function buildMonthPicker() {
  const pick = $("#monthPick");
  pick.textContent = "";
  const yr = el("div", { class: "yr" });
  const prev = el("button", { class: "ynav" }, icon("i-chev-l"));
  const next = el("button", { class: "ynav" }, icon("i-chev-r"));
  const yv = el("span", { class: "yv" }, String(state.pickerYear));
  prev.addEventListener("click", (e) => { e.stopPropagation(); state.pickerYear--; buildMonthPicker(); });
  next.addEventListener("click", (e) => { e.stopPropagation(); state.pickerYear++; buildMonthPicker(); });
  yr.append(prev, yv, next);
  pick.append(yr);

  const grid = el("div", { class: "mgrid" });
  const selY = Number(state.month.slice(0, 4));
  const selM = Number(state.month.slice(5, 7));
  const now = new Date();
  for (let m = 1; m <= 12; m++) {
    const ym = `${state.pickerYear}-${String(m).padStart(2, "0")}`;
    const cls = ["m"];
    if (state.pickerYear === selY && m === selM) cls.push("sel");
    if (state.monthsWithData.has(ym)) cls.push("has");
    const isFuture = state.pickerYear > now.getFullYear() ||
      (state.pickerYear === now.getFullYear() && m > now.getMonth() + 1);
    if (isFuture) cls.push("dim");
    const cell = el("div", { class: cls.join(" ") }, THAI_MONTHS_SHORT[m - 1]);
    cell.addEventListener("click", (e) => {
      e.stopPropagation();
      $("#monthPick").hidden = true;
      loadMonth(ym);
    });
    grid.append(cell);
  }
  pick.append(grid);
}

// ======================================================
//  Zoom
// ======================================================
const ZOOM_LEVELS = [80, 90, 100, 110, 125, 140];

function applyZoom(pct: number) {
  document.documentElement.style.fontSize = `${(16 * pct) / 100}px`;
  $("#zoomLvl").textContent = `${pct}%`;
  localStorage.setItem("fa_zoom", String(pct));
}
function initZoom() {
  const saved = Number(localStorage.getItem("fa_zoom")) || 100;
  applyZoom(ZOOM_LEVELS.includes(saved) ? saved : 100);
  $("#zoomOut").addEventListener("click", () => {
    const cur = Number(localStorage.getItem("fa_zoom")) || 100;
    const i = Math.max(0, ZOOM_LEVELS.indexOf(cur) - 1);
    applyZoom(ZOOM_LEVELS[i]);
  });
  $("#zoomIn").addEventListener("click", () => {
    const cur = Number(localStorage.getItem("fa_zoom")) || 100;
    const i = Math.min(ZOOM_LEVELS.length - 1, ZOOM_LEVELS.indexOf(cur) + 1);
    applyZoom(ZOOM_LEVELS[i]);
  });
}

// ======================================================
//  โหลดเดือน + bootstrap
// ======================================================
async function loadMonth(month: string) {
  state.month = month;
  state.pickerYear = Number(month.slice(0, 4));
  // reset มุมมองต่อเดือน
  state.filters.clear();
  state.sort = null;
  state.search = "";
  ($("#searchInput") as HTMLInputElement).value = "";
  clearSelection();
  $("#monthLabel").textContent = monthLabel(month);
  $("#pageTitle").textContent = `ออเดอร์ — ${monthLabel(month)}`;
  $("#kpi").textContent = "";
  $("#tableWrap").innerHTML = `<div class="state">กำลังโหลด...</div>`;
  try {
    const data = await fetchOrders(month);
    if (!data.authorized) { toLogin(); return; }
    computeKpiDaily(data);            // get_orders คืนแค่ orders → คำนวณ KPI/daily ที่นี่
    state.data = data;
    renderKpi(data);
    renderTable();
    buildMonthPicker();
  } catch (e: any) {
    $("#tableWrap").innerHTML = `<div class="state err">โหลดข้อมูลไม่สำเร็จ: ${e?.message ?? e}</div>`;
  }
}

async function bootstrap() {
  initZoom();

  // month picker toggle
  $("#monthPill").addEventListener("click", (e) => {
    e.stopPropagation();
    const p = $("#monthPick");
    p.hidden = !p.hidden;
    if (!p.hidden) buildMonthPicker();
  });

  // ค้นหา
  const si = $("#searchInput") as HTMLInputElement;
  si.addEventListener("input", () => {
    state.search = si.value;
    clearSelection();
    if (state.data) renderTable();
  });

  // ปุ่มนำเข้า (Stage 2)
  $("#importBtn").addEventListener("click", () => toast("หน้านำเข้าไฟล์ยังไม่เปิดใช้ (Stage 2)", false));

  // logout
  $("#logoutBtn").addEventListener("click", async () => {
    const t = getToken();
    if (t) await authLogout(t);
    toLogin();
  });

  // ปิด dropdown/picker เมื่อคลิกนอก
  document.addEventListener("click", (e) => {
    const t = e.target as Node;
    if (openDrop && !openDrop.contains(t) && !(t as HTMLElement).closest?.(".funnel")) closeDrop();
    const pick = $("#monthPick");
    if (!pick.hidden && !$("#monthsel").contains(t)) pick.hidden = true;
  });

  // gate: มี session แล้วเข้าแอป ไม่งั้นไปหน้า login
  if (getToken()) await startApp();
  else toLogin();
}

// โหลดเดือน + เข้าแอป (หลัง login ผ่าน)
async function startApp() {
  try {
    const m = await fetchMonths();
    if (!m.authorized) { toLogin(); return; }
    document.body.classList.add("authed");
    document.body.classList.add("ready");
    updateUserDisplay();
    const months = m.months ?? [];
    state.monthsWithData = new Set(months);
    const first = months[0] ?? new Date().toISOString().slice(0, 7);
    await loadMonth(first);
  } catch {
    toLogin(); // ต่อเซิร์ฟเวอร์ไม่ได้/session เสีย → กลับไป login
  }
}

function toLogin() {
  clearSession();
  document.body.classList.remove("authed");
  renderLogin(() => { void startApp(); });
  document.body.classList.add("ready");
}

function updateUserDisplay() {
  const name = displayName() || "user";
  const av = document.querySelector("#userAvatar") as HTMLElement | null;
  const nm = document.querySelector("#userName") as HTMLElement | null;
  if (av) av.textContent = (name[0] || "U").toUpperCase();
  if (nm) nm.textContent = name;
}

bootstrap();
