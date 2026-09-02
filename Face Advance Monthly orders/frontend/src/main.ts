import "./style.css";
import {
  fetchMonths, fetchOrders, authLogout, importOrders, type ImportResp,
  saveOrderTracking, getOrderTracking, type SaveTrackingArgs,
  getDetailPresets,
} from "./api";
import { renderLogin } from "./auth";
import { getToken, clearSession, displayName } from "./session";
import { parseWorkbook, type ImportRow, type ParseResult } from "./import";
import type { Order, OrderItem, OrdersResponse, Kpi, Daily, TrackingEntry } from "./types";
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
  { key: "items", label: "รายการสินค้า" },
  { key: "payment_method", label: "ชำระ", align: "right" },
  { key: "total_sales", label: "ยอดขาย", align: "right" },
  { key: "carrier", label: "ขนส่ง" },
  { key: "tracking_no", label: "เลขแทร็ค" },
  { key: "delivery_status", label: "สถานะจัดส่ง", align: "center" },
  { key: "payment_status", label: "สถานะชำระ", align: "center" },
  { key: "return_arrived", label: "ตีกลับถึงแล้ว", align: "center" },
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
let headTickEl: HTMLElement | null = null;

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
  const kpi: Kpi = { exported_count: 0, sales_total: 0, sales_paid: 0, sales_unpaid: 0, returned_count: 0, returned_amount: 0, returned_amount_status: 0 };
  for (const o of d.orders) {
    const idx = Number(o.date.slice(8, 10)) - 1;
    const amt = o.total_sales || 0;
    const inRange = idx >= 0 && idx < days;
    kpi.exported_count++;
    kpi.sales_total += amt;
    if (inRange) daily.exported[idx]++;
    if (o.payment_status === "ชำระแล้ว") { kpi.sales_paid += amt; if (inRange) daily.sales_paid[idx] += amt; }
    else if (o.payment_status === "รอชำระ") { kpi.sales_unpaid += amt; if (inRange) daily.sales_unpaid[idx] += amt; }
    // จำนวน/อัตรา/กราฟ + ยอดตีกลับจากสถานะ = ใช้สถานะจัดส่ง "ตีกลับ"
    if (o.delivery_status === "ตีกลับ") { kpi.returned_count++; kpi.returned_amount_status += amt; if (inRange) daily.returned[idx]++; }
    // ยอดที่ตีกลับถึงแล้ว = ผลรวมเฉพาะออเดอร์ที่ return_arrived
    if (o.return_arrived) kpi.returned_amount += amt;
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
  const avgSales = daysWithData ? Math.round(d.kpi.sales_total / daysWithData) : 0;   // หารด้วยวันที่มีข้อมูล (ให้ตรงกับการ์ดจำนวนส่งออก)
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
  root.append(kcardSplit("green", "i-coin", "ยอดขาย", mainPaid, detail2, chart2, cap2));

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
  const bigRet = el("div", { class: "kbig num", style: "color:#DC2626" });
  bigRet.append(el("small", {}, "฿"), " " + nf(d.kpi.returned_amount));
  // ยอดจากสถานะ: เท่ากับยอดถึงแล้ว = เทา (ตีกลับกลับมาครบ) · ไม่เท่า = แดงอ่อน (ยังไม่ครบ)
  const retMatched = d.kpi.returned_amount === d.kpi.returned_amount_status;
  bigRet.append(el("span", { class: "retsub" + (retMatched ? " done" : "") }, ` / ${nf(d.kpi.returned_amount_status)}`));
  const mainRed = el("div", { class: "kmain" }, bigRet,
    el("div", { class: "kunit" }, "ตีกลับถึงแล้ว / จากสถานะตีกลับ"));
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
  tr.append(el("th", { class: "acthead c" }, "อัพเดต"));
  thead.append(tr);

  const tbody = el("tbody");
  if (rows.length === 0) {
    const td = el("td", { colspan: String(COLUMNS.length + 1) });
    td.append(el("div", { class: "state" }, d.orders.length ? "ไม่มีรายการตรงกับตัวกรอง" : "ยังไม่มีออเดอร์ในเดือนนี้"));
    tbody.append(el("tr", {}, td));
  } else {
    for (const o of rows) tbody.append(buildRow(o));
  }
  table.append(thead, tbody);
  wrap.append(table);

  // โชว์ปุ่มขยาย (ที่อยู่/ชื่อ) เฉพาะแถวที่ข้อความล้น
  // แยก read (scrollWidth) กับ write (display) เป็น 2 เฟส กัน layout thrashing (สำคัญมากตอนแถวเยอะ)
  const toShow: HTMLElement[] = [];
  for (const tx of wrap.querySelectorAll<HTMLElement>(".atxt, .ntxt")) {
    if (tx.scrollWidth > tx.clientWidth + 1) {
      const tog = tx.parentElement?.querySelector<HTMLElement>(".itemtoggle");
      if (tog) toShow.push(tog);
    }
  }
  for (const tog of toShow) tog.style.display = "";

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

  // คอลัมน์เลขแทร็ค: ช่องติ๊กหัวตาราง (เลือกทั้งคอลัม/ล้าง) + แถบก๊อป (โผล่เมื่อเลือก ≥1)
  if (col.key === "tracking_no") {
    headHHEl = hh;
    headTickEl = makeHeaderTick();
    hh.insertBefore(headTickEl, hh.lastElementChild); // ช่องติ๊กอยู่ขวา (หน้ากรวยตัวกรอง)
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
  // ชื่อลูกค้า (+code) — โชว์บรรทัดเดียว · ล้น → ปุ่มขยายดูเต็ม
  tr.append(buildNameCell(o, tr));
  // ที่อยู่ (โชว์บรรทัดเดียว · ล้น → ปุ่มขยายดูเต็ม)
  tr.append(buildAddrCell(o, tr));
  // รายการสินค้า (โชว์บรรทัดแรก · มี ≥2 → ปุ่มสามเหลี่ยมขยายทั้งแถว)
  tr.append(buildItemsCell(o, tr));
  // ช่องทางชำระ (COD ย่อจาก เก็บเงินปลายทาง) — ชิดขวา
  tr.append(el("td", { class: "tar" }, paymentMethodLabel(o.payment_method) || "—"));
  // ยอดขาย
  tr.append(el("td", { class: "amount num" }, nf(o.total_sales)));
  // ขนส่ง
  tr.append(el("td", {}, o.carrier || "—"));
  // เลขแทร็ค + ปุ่มติ๊ก
  tr.append(buildTrackCell(o));
  // สถานะจัดส่ง (badge + ดินสอแก้ inline)
  tr.append(buildStatusCell(o, "delivery"));
  // สถานะชำระ (badge + ดินสอแก้ inline)
  tr.append(buildStatusCell(o, "payment"));
  // ตีกลับถึงแล้ว (ลอจิกเฟสถัดไป — ตอนนี้ "-" หรือ "ถึงแล้ว")
  const raCell = el("td", { class: "center" });
  if (o.return_arrived) raCell.append(badge({ cls: "r", icon: "i-return" }, "ถึงแล้ว"));
  else raCell.append("—");
  tr.append(raCell);
  // หมายเหตุ
  tr.append(el("td", { class: o.note ? "note mono" : "note" }, o.note || "—"));
  // แก้ไข (เปิด sidebar)
  const actCell = el("td", { class: "actcell" });
  const editBtn = el("button", { class: "rowedit", title: "อัพเดต / บันทึกติดตาม" }, icon("i-editbox"));
  editBtn.addEventListener("click", (e) => { e.stopPropagation(); openSidebar(o); });
  actCell.append(editBtn);
  tr.append(actCell);
  return tr;
}

// สถานะ (จัดส่ง/ชำระ) + ดินสอแก้ inline → popup เลือก → ยืนยัน
function buildStatusCell(o: Order, field: "delivery" | "payment"): HTMLElement {
  const td = el("td", { class: "center statuscell" });
  const val = field === "delivery" ? o.delivery_status : o.payment_status;
  const b = field === "delivery" ? deliveryBadge(val) : paymentBadge(val);
  const wrap = el("div", { class: "stwrap" }, badge(b, val));
  const pen = el("span", { class: "stedit", title: "แก้สถานะ" }, icon("i-edit"));
  pen.addEventListener("click", (e) => { e.stopPropagation(); openStatusPopup(pen, o, field); });
  wrap.append(pen);
  td.append(wrap);
  return td;
}

function buildNameCell(o: Order, tr: HTMLElement): HTMLElement {
  const td = el("td", { class: "name-cell" });
  const { name, code } = splitNameCode(o.customer_name);
  const line = el("div", { class: "nameline" });
  const txt = el("span", { class: "ntxt name", title: o.customer_name }, name || "—");
  if (code) txt.append(" ", el("span", { class: "code" }, code));
  const tog = el("span", { class: "itemtoggle nametoggle", title: "ดู/ซ่อนรายละเอียดทั้งแถว" }, icon("i-caret"));
  tog.style.display = "none"; // โชว์เฉพาะแถวที่ชื่อล้น (เช็ค overflow หลัง render)
  tog.addEventListener("click", (e) => { e.stopPropagation(); tr.classList.toggle("rowopen"); });
  line.append(txt, tog);
  td.append(line);
  return td;
}

function buildAddrCell(o: Order, tr: HTMLElement): HTMLElement {
  const td = el("td", { class: "addr-cell" });
  const wrap = el("div", { class: "addrline" });
  const txt = el("span", { class: "atxt", title: o.address }, o.address || "—");
  // ตอนขยาย: แยกส่วนย่อย (รายละเอียด/ตำบล/อำเภอ/จังหวัด/ไปรษณีย์) บรรทัดละส่วน (ยาว→wrap ปกติ)
  const parts = el("div", { class: "addrparts" });
  const ap = o.address_parts?.length ? o.address_parts : [o.address || "—"];
  for (const p of ap) parts.append(el("div", { class: "apart" }, p));
  const tog = el("span", { class: "itemtoggle addrtoggle", title: "ดู/ซ่อนรายละเอียดทั้งแถว" }, icon("i-caret"));
  tog.style.display = "none"; // โชว์เฉพาะแถวที่ที่อยู่ล้น (เช็ค overflow หลัง render)
  tog.addEventListener("click", (e) => { e.stopPropagation(); tr.classList.toggle("rowopen"); });
  wrap.append(txt, parts, tog);
  td.append(wrap);
  return td;
}

function buildItemsCell(o: Order, tr: HTMLElement): HTMLElement {
  const td = el("td", { class: "items" });
  const items = o.items || [];
  if (items.length === 0) { td.append("—"); return td; }
  const line = (it: OrderItem) => `${it.name} ×${it.qty}`;
  const first = el("div", { class: "iln0" }, el("span", { class: "itxt", title: line(items[0]) }, line(items[0])));
  if (items.length > 1) {
    const tog = el("span", { class: "itemtoggle", title: "ดู/ซ่อนรายละเอียดทั้งแถว" }, icon("i-caret"));
    tog.addEventListener("click", (e) => { e.stopPropagation(); tr.classList.toggle("rowopen"); });
    first.append(tog);
    const rest = el("div", { class: "itemrest" });
    for (let i = 1; i < items.length; i++) rest.append(el("div", { class: "iln", title: line(items[i]) }, line(items[i])));
    td.append(first, rest);
  } else {
    td.append(first);
  }
  return td;
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

// รายการที่แสดงอยู่และมีเลขแทร็ค (เลือกได้)
function selectableVisible(): Order[] {
  return currentVisible.filter((o) => o.tracking_no);
}

// เลือกเร็ว: เติมรายการที่โชว์ (มีเลขแทร็ค) จนครบ 30 — ตาม filter ปัจจุบัน
function quickSelect() {
  for (const o of currentVisible) {
    if (state.selected.size >= MAX_SELECT) break;
    if (o.tracking_no && !state.selected.has(o.id)) state.selected.add(o.id);
  }
}

// ช่องติ๊กหัวตาราง: ติ๊ก = เลือกทั้งคอลัม (สูงสุด 30) · ติ๊กซ้ำ (เต็ม/เลือกครบแล้ว) = ล้าง
function onHeaderTick() {
  const sel = selectableVisible();
  const allSel = sel.length > 0 && sel.every((o) => state.selected.has(o.id));
  if (allSel || state.selected.size >= MAX_SELECT) clearSelection();
  else quickSelect();
  updateSelectionUI();
}

function makeHeaderTick(): HTMLElement {
  const t = el("span", { class: "tick headtick", title: "เลือกเลขแทร็คที่แสดงทั้งหมด (สูงสุด 30) · ติ๊กซ้ำเพื่อล้าง" }, icon("i-tick"));
  t.addEventListener("click", (e) => { e.stopPropagation(); onHeaderTick(); });
  return t;
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
  // สถานะช่องติ๊กหัวตาราง (on = เลือกครบทุกอันที่แสดง, partial = เลือกบางส่วน)
  const sel = selectableVisible();
  const allSel = sel.length > 0 && sel.every((o) => state.selected.has(o.id));
  const styleHead = (t: HTMLElement | null) => {
    if (!t) return;
    t.classList.toggle("on", count > 0 && allSel);
    t.classList.toggle("partial", count > 0 && !allSel);
  };
  styleHead(headTickEl);

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
  const cbTick = makeHeaderTick();
  styleHead(cbTick);
  copyBarEl.append(cbTick);
  const btn = el("button", { class: "copybtn" }, icon("i-copy"), "คัดลอก");
  btn.append(el("span", { class: "cnt" }, String(count)));
  btn.addEventListener("click", doCopy);
  copyBarEl.append(btn);
  const x = el("span", { class: "copyx", title: "ยกเลิกการเลือก" }, icon("i-close"));
  x.addEventListener("click", () => { clearSelection(); updateSelectionUI(); });
  copyBarEl.append(x);
}

async function doCopy() {
  // ก๊อปทุกอันที่เลือก (รวมที่ถูก filter ซ่อน) เรียงตามลำดับข้อมูลเต็ม (เก่า→ใหม่)
  const src = state.data?.orders ?? currentVisible;
  const nums = src
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
//  การบันทึกติดตาม (Stage 5): แก้สถานะ inline + sidebar
// ======================================================
const DELIVERY_STATUSES = ["รอส่ง", "ส่งแล้ว", "ส่งสำเร็จ", "ตีกลับ", "ยกเลิก", "มีปัญหา"];
const PAYMENT_STATUSES = ["รอชำระ", "ชำระแล้ว", "ยกเลิก"];
const RETURN_REASONS = [
  "ไม่สามารถติดต่อลูกค้าได้",
  "ลูกค้าไม่สะดวกรับในรอบการจัดส่ง",
  "ลูกค้าไม่ได้สั่ง",
  "ลูกค้ายกเลิก เนื่องจาก",
  "ลูกค้าต้องการเปลี่ยนสินค้า",
  "ร้านค้าส่งของผิด",
  "จัดส่งนานเกินไป",
  "ขนส่งบริการไม่ดี",
  "ขนส่งไม่นำส่งให้ลูกค้า",
  "อื่นๆ ระบุเพิ่มเติม",
];
const REASONS_WITH_EXTRA = new Set(["ลูกค้ายกเลิก เนื่องจาก", "อื่นๆ ระบุเพิ่มเติม"]);

function trackErrMsg(err?: string): string {
  switch (err) {
    case "return_reason_required": return "กรุณาเลือกเหตุผลตีกลับ";
    case "status_detail_required": return "กรุณากรอกรายละเอียดปัญหา";
    case "order_not_found":        return "ไม่พบออเดอร์นี้แล้ว";
    case "bad_delivery_status":
    case "bad_payment_status":     return "สถานะไม่ถูกต้อง";
    default:                       return "บันทึกไม่สำเร็จ";
  }
}

// อัปเดต order ใน state จาก response แล้ว re-render (KPI ตีกลับเปลี่ยนตามด้วย)
function applyOrderUpdate(o: Order, r: { delivery_status?: string; payment_status?: string; return_reason?: string; status_detail?: string }) {
  if (r.delivery_status) o.delivery_status = r.delivery_status;
  if (r.payment_status) o.payment_status = r.payment_status;
  o.return_reason = r.return_reason ?? "";
  o.status_detail = r.status_detail ?? "";
  computeKpiDaily(state.data!);
  renderKpi(state.data!);
  renderTable();
}

// ---- แก้สถานะ inline: ดินสอ → popup เลือก → ยืนยัน ----
function openStatusPopup(anchor: HTMLElement, o: Order, field: "delivery" | "payment") {
  closeDrop();
  const cur = field === "delivery" ? o.delivery_status : o.payment_status;
  const opts = field === "delivery" ? DELIVERY_STATUSES : PAYMENT_STATUSES;
  let sel = cur;

  const pop = el("div", { class: "stpop" });
  openDrop = pop;
  const list = el("div", { class: "stlist" });
  const rowEls = new Map<string, HTMLElement>();
  for (const s of opts) {
    const b = field === "delivery" ? deliveryBadge(s) : paymentBadge(s);
    const row = el("div", { class: "stopt" + (s === sel ? " sel" : "") }, badge(b, s), el("span", { class: "sttick" }, icon("i-tick")));
    row.addEventListener("click", () => {
      sel = s;
      for (const [k, elx] of rowEls) elx.classList.toggle("sel", k === s);
    });
    rowEls.set(s, row);
    list.append(row);
  }
  pop.append(list);

  const actions = el("div", { class: "stactions" });
  const cancel = el("button", { class: "btncancel" }, "ยกเลิก");
  const ok = el("button", { class: "fbtn p" }, "ยืนยัน");
  cancel.addEventListener("click", closeDrop);
  ok.addEventListener("click", async () => {
    if (sel === cur) { closeDrop(); return; }
    // ตีกลับ/มีปัญหา ต้องมีเหตุผล → เด้งเปิด sidebar ให้กรอก
    if (field === "delivery" && (sel === "ตีกลับ" || sel === "มีปัญหา")) {
      closeDrop();
      openSidebar(o, { presetDelivery: sel });
      return;
    }
    closeDrop();
    const args: SaveTrackingArgs = field === "delivery" ? { delivery_status: sel } : { payment_status: sel };
    try {
      const r = await saveOrderTracking(o.id, args);
      if (!r.authorized) { toLogin(); return; }
      if (!r.ok) { toast(trackErrMsg(r.error), false); return; }
      applyOrderUpdate(o, r);
      toast("อัปเดตสถานะแล้ว");
    } catch { toast("บันทึกไม่สำเร็จ", false); }
  });
  actions.append(cancel, ok);
  pop.append(actions);

  // วางใน td (position:relative) ใต้ดินสอ
  const td = anchor.closest("td")!;
  td.append(pop);
  const r = pop.getBoundingClientRect();
  if (r.right > window.innerWidth - 8) { pop.style.right = "auto"; pop.style.left = "0"; }
  if (r.bottom > window.innerHeight - 8) { pop.style.top = "auto"; pop.style.bottom = "calc(100% + .25rem)"; }
}

// ---- sidebar: ตัวแก้ไขหลัก + ไทม์ไลน์ ----
let sidebarEl: HTMLElement | null = null;
function closeSidebar() { if (sidebarEl) { sidebarEl.remove(); sidebarEl = null; } }

function openSidebar(o: Order, opts?: { presetDelivery?: string }) {
  closeSidebar();
  const root = el("div", { class: "sboverlay" });   // พื้นหลังทึบ — คลิกนอกไม่ปิด (ตามสเปก)
  const panel = el("div", { class: "sbpanel" });
  root.append(panel);
  sidebarEl = root;

  // header
  const head = el("div", { class: "sbhead" });
  head.append(el("div", { class: "sbtitle" }, "รายละเอียด / บันทึกติดตาม"));
  // ปุ่มปิดแบบ widget ลอยทับขอบซ้าย ตรงเส้นล่าง header (hover แดง)
  const closeW = el("button", { class: "sbclosew", type: "button", title: "ปิด" }, icon("i-close"));
  closeW.addEventListener("click", () => requestClose());
  head.append(closeW);
  panel.append(head);

  const body = el("div", { class: "sbbody" });
  panel.append(body);

  // ---- ส่วนแสดงข้อมูล (อ่านอย่างเดียว) — กริดกระชับ เห็นครบ ----
  const itemsNode = el("span", { class: "sbitems" });
  const its = o.items || [];
  if (its.length) its.forEach((it, i) => { if (i) itemsNode.append(el("br")); itemsNode.append(`${it.name} ×${it.qty}`); });
  else itemsNode.append("—");
  const seller = o.seller_code || o.seller_name
    ? `${o.seller_code || "—"}${o.seller_name ? " · " + o.seller_name : ""}` : "ไม่ระบุ";

  const infoC = infoCard("i-user", "ico-blue", "ข้อมูลออเดอร์");
  infoC.card.querySelector(".sbcardhd")!.append(el("span", { class: "sbheaddate" }, dmy(o.date)));
  // hero: ชื่อลูกค้าเด่น + เบอร์โทร
  const { name: custName, code: custCode } = splitNameCode(o.customer_name);
  const nameEl = el("div", { class: "sbname" }, custName || "—");
  if (custCode) nameEl.append(" ", el("span", { class: "sbnamecode" }, custCode));
  const heroL = el("div", { class: "sbherol" }, nameEl, el("div", { class: "sbphone" }, fmtPhone(o.phone) || "—"));
  // ยอดขาย + ช่องทางชำระ อยู่แถวเดียวกับชื่อ/เบอร์ (ชิดขวา) — ช่องทางชำระบน, ยอดตัวเลขล่าง (ไม่มี label "ยอดขาย")
  // สียอดขายตามสถานะชำระ: ชำระแล้ว=เขียว · ยกเลิก=แดง · รอชำระ=ส้ม (เฉดเดียวกับการ์ด KPI)
  const payColor = o.payment_status === "ชำระแล้ว" ? "#059669" : o.payment_status === "ยกเลิก" ? "#DC2626" : "#EA580C";
  const heroR = el("div", { class: "sbheror" },
    el("div", { class: "sbpay" }, paymentMethodLabel(o.payment_method) || "—"),
    el("div", { class: "sbmoneyval", style: "color:" + payColor }, "฿" + nf(o.total_sales)));
  infoC.body.append(el("div", { class: "sbhero" }, heroL, heroR));
  // meta กริด (สั้น) + บล็อกยาว
  // ที่อยู่ (บนสุดของบล็อกล่าง) — อยู่เหนือแถวขนส่ง/เลขแทร็ก/ผู้ขาย
  infoC.body.append(gridField("ที่อยู่", o.address, true));
  // ขนส่ง · เลขแทร็ก · ผู้ขาย — 3 ช่องระดับเดียวกัน
  // KEX → เลขแทร็กกดได้ เปิดลิงก์ติดตามแท็บใหม่
  let trackNode: Node | string = "—";
  if (o.tracking_no) {
    if ((o.carrier || "").trim().toUpperCase() === "KEX") {
      trackNode = el("a", {
        class: "trackbox mono tracklink",
        href: "https://th.kex-express.com/th/track/?track=" + encodeURIComponent(o.tracking_no),
        target: "_blank", rel: "noopener noreferrer", title: "ติดตามพัสดุ KEX",
      }, o.tracking_no);
    } else {
      trackNode = el("span", { class: "trackbox mono" }, o.tracking_no);
    }
  }
  const meta = el("div", { class: "sbgrid sbgrid3" });
  meta.append(
    gridField("ขนส่ง", o.carrier),
    gridField("เลขแทร็ก", trackNode),
    gridField("ผู้ขาย", seller),
  );
  infoC.body.append(meta);
  infoC.body.append(gridField("รายการสินค้า", itemsNode, true));
  if (o.note) infoC.body.append(gridField("หมายเหตุ", o.note, true));
  // เหตุผล/รายละเอียดสถานะปัจจุบัน (ถ้ามี)
  if (o.return_reason || o.status_detail) {
    const extra = el("div", { class: "sbextra" });
    if (o.return_reason) extra.append(el("div", {}, el("b", {}, "เหตุผลตีกลับ: "), o.return_reason));
    if (o.status_detail) extra.append(el("div", {}, el("b", {}, "รายละเอียด: "), o.status_detail));
    infoC.body.append(extra);
  }
  body.append(infoC.card);

  // ---- ส่วนแก้ไขสถานะ (chip เห็นทันที ไม่ใช่ dropdown) ----
  const editC = infoCard("i-editbox", "ico-indigo", "แก้ไขสถานะ");
  let selDelivery = opts?.presetDelivery ?? o.delivery_status;
  let selPayment = o.payment_status;
  let selReason = "";

  const delGroup = chipGroup(DELIVERY_STATUSES, selDelivery, deliveryBadge, (v) => { selDelivery = v; syncCond(); updateSaveState(); });

  const reasonBlock = el("div", { class: "sbcond" });
  const reasonG = chipList(RETURN_REASONS, "", (v) => { selReason = v; syncCond(); updateSaveState(); });
  const reasonExtra = el("textarea", { class: "sbtextarea", rows: "2", placeholder: "ระบุเพิ่มเติม…" }) as HTMLTextAreaElement;
  const reasonExtraWrap = el("div", { class: "sbcond" }, reasonExtra);
  reasonBlock.append(el("div", { class: "sbsublabel" }, "เหตุผลที่ตีกลับ"), reasonG.el, reasonExtraWrap);

  const problemBlock = el("div", { class: "sbcond" });
  const problemTa = el("textarea", { class: "sbtextarea", rows: "3", placeholder: "รายละเอียดปัญหา…" }) as HTMLTextAreaElement;
  const detailPresets = presetStrip(problemTa, () => updateSaveState());
  problemBlock.append(el("div", { class: "sbsublabel" }, "รายละเอียดปัญหา"), problemTa, detailPresets.el);

  // prefill จากค่าเดิม (สถานะเดิมเป็นตีกลับ/มีปัญหา และไม่ได้ preset ทับ)
  if (o.delivery_status === "ตีกลับ" && !opts?.presetDelivery) {
    selReason = o.return_reason || ""; reasonG.set(selReason); reasonExtra.value = o.status_detail || "";
  } else if (o.delivery_status === "มีปัญหา" && !opts?.presetDelivery) {
    problemTa.value = o.status_detail || "";
  }

  const payGroup = chipGroup(PAYMENT_STATUSES, selPayment, paymentBadge, (v) => { selPayment = v; updateSaveState(); });

  editC.body.append(
    el("div", { class: "sbfld" }, "สถานะจัดส่ง"), delGroup.el,
    reasonBlock, problemBlock,
    el("div", { class: "sbfld sbfld-gap" }, "สถานะชำระเงิน"), payGroup.el,
  );
  // (editC ต่อท้าย "บันทึกการติดตาม" ด้านล่าง ตามที่เจ้านายสั่ง)

  function syncCond() {
    reasonBlock.style.display = selDelivery === "ตีกลับ" ? "" : "none";
    problemBlock.style.display = selDelivery === "มีปัญหา" ? "" : "none";
    reasonExtraWrap.style.display = selDelivery === "ตีกลับ" && REASONS_WITH_EXTRA.has(selReason) ? "" : "none";
  }
  syncCond();

  // มีการแก้ไขหรือยัง (เทียบกับค่าเดิมของออเดอร์)
  function hasChanges() {
    const noteT = noteTa.value.trim();
    let changed = selDelivery !== o.delivery_status || selPayment !== o.payment_status || noteT !== "";
    if (selDelivery === "ตีกลับ") changed = changed || selReason !== (o.return_reason || "") || reasonExtra.value.trim() !== (o.status_detail || "");
    if (selDelivery === "มีปัญหา") changed = changed || problemTa.value.trim() !== (o.status_detail || "");
    return changed;
  }
  // เปิด/ปิดปุ่มยืนยันบันทึก: ต้องมีการแก้ไข + ฟิลด์จำเป็นครบ
  function updateSaveState() {
    let ok = true;
    if (selDelivery === "ตีกลับ") {
      if (!selReason) ok = false;
      else if (REASONS_WITH_EXTRA.has(selReason) && !reasonExtra.value.trim()) ok = false;
    } else if (selDelivery === "มีปัญหา") {
      if (!problemTa.value.trim()) ok = false;
    }
    saveBtn.disabled = !(hasChanges() && ok);
  }
  // ปิด sidebar: ถ้ามีการแก้ไข → เตือนก่อน (custom popup ไม่ใช้ native confirm)
  function requestClose() {
    if (!hasChanges()) { closeSidebar(); return; }
    const cf = el("div", { class: "sbconfirm" });
    const cancelB = el("button", { class: "btncancel" }, "ยกเลิก");
    cancelB.addEventListener("click", () => cf.remove());
    const okB = el("button", { class: "fbtn p" }, "ยืนยัน");
    okB.addEventListener("click", closeSidebar);
    cf.append(el("div", { class: "sbconfirmbox" },
      el("div", { class: "sbconfirmtitle" }, "มีการแก้ไขที่ยังไม่บันทึก"),
      el("div", { class: "sbconfirmmsg" }, "ต้องการปิดโดยไม่บันทึกการแก้ไขหรือไม่?"),
      el("div", { class: "sbconfirmact" }, cancelB, okB)));
    panel.append(cf);
  }

  // ---- บันทึกการติดตาม: ประวัติโน้ต (บน) + ช่องเพิ่ม (ล่าง) — การ์ดหลัก ----
  const trackC = infoCard("i-msg", "ico-amber", "บันทึกการติดตาม");
  const noteCount = el("span", { class: "sbcount" });
  const noteBox = el("div", { class: "sbnotes" }, el("div", { class: "tlempty" }, "กำลังโหลด…"));
  const noteTa = el("textarea", { class: "sbtextarea", rows: "3", placeholder: "พิมพ์บันทึกการติดตาม…" }) as HTMLTextAreaElement;
  trackC.body.append(
    el("div", { class: "sbsublabel" }, "ประวัติโน้ต ", noteCount), noteBox,
    el("div", { class: "sbfld sbfld-gap" }, "เพิ่มบันทึก"), noteTa,
  );
  body.append(trackC.card);
  body.append(editC.card);   // แก้ไขสถานะ อยู่ล่างบันทึกการติดตาม

  // ---- ประวัติการเปลี่ยนสถานะ (ซ่อนในปุ่ม toggle, ปิดไว้ก่อน) ----
  const logBox = el("div", { class: "sbtimeline" }, el("div", { class: "tlempty" }, "กำลังโหลด…"));
  const logBody = el("div", { class: "sbcardbody" }, logBox);
  logBody.style.display = "none";
  const logHd = el("button", { class: "sbcardhd sbtoggle", type: "button" },
    el("span", { class: "sbico ico-indigo" }, icon("i-clock")),
    el("span", { class: "sbcardt" }, "ประวัติการเปลี่ยนสถานะ"),
    el("span", { class: "sbtogcaret" }, icon("i-caret")));
  logHd.addEventListener("click", () => {
    const open = logBody.style.display === "none";
    logBody.style.display = open ? "" : "none";
    logHd.classList.toggle("open", open);
  });
  body.append(el("div", { class: "sbcard" }, logHd, logBody));

  void loadTimeline(o.id, noteBox, logBox, noteCount);

  // ---- footer ----
  const foot = el("div", { class: "sbfoot" });
  const closeBtn = el("button", { class: "btncancel" }, "ปิด");
  const saveBtn = el("button", { class: "fbtn p" }, "ยืนยันบันทึก");
  for (const t of [reasonExtra, problemTa, noteTa]) t.addEventListener("input", updateSaveState);
  updateSaveState();   // เริ่มต้น: disable (ยังไม่แก้)
  closeBtn.addEventListener("click", () => requestClose());
  saveBtn.addEventListener("click", async () => {
    const newDelivery = selDelivery;
    const newPayment = selPayment;
    const note = noteTa.value.trim();
    let reason: string | undefined;
    let detail: string | undefined;
    if (newDelivery === "ตีกลับ") {
      reason = selReason;
      if (!reason) { toast("กรุณาเลือกเหตุผลตีกลับ", false); return; }
      if (REASONS_WITH_EXTRA.has(reason)) {
        detail = reasonExtra.value.trim();
        if (!detail) { toast("กรุณาระบุเหตุผลเพิ่มเติม", false); return; }
      }
    } else if (newDelivery === "มีปัญหา") {
      detail = problemTa.value.trim();
      if (!detail) { toast("กรุณากรอกรายละเอียดปัญหา", false); return; }
    }
    const args: SaveTrackingArgs = {
      delivery_status: newDelivery,
      payment_status: newPayment,
      return_reason: reason,
      status_detail: detail,
      note: note || undefined,
    };
    saveBtn.setAttribute("disabled", "1");
    try {
      const r = await saveOrderTracking(o.id, args);
      if (!r.authorized) { toLogin(); return; }
      if (!r.ok) { toast(trackErrMsg(r.error), false); saveBtn.removeAttribute("disabled"); return; }
      if (newDelivery === "มีปัญหา" && !r.noop) detailPresets.commitSaved();   // คำใหม่ → เก็บ localStorage
      applyOrderUpdate(o, r);
      toast(r.noop ? "ไม่มีการเปลี่ยนแปลง" : "บันทึกแล้ว");
      closeSidebar();
    } catch { toast("บันทึกไม่สำเร็จ", false); saveBtn.removeAttribute("disabled"); }
  });
  foot.append(closeBtn, saveBtn);
  panel.append(foot);

  // ตัวบอกว่ายังเลื่อนดูด้านล่างได้อีก (ซ่อนเมื่อเลื่อนสุด) — กดเพื่อเลื่อนลง
  const scrollHint = el("button", { class: "sbscrollhint", type: "button", title: "เลื่อนดูเพิ่ม" }, icon("i-chev"));
  scrollHint.addEventListener("click", () => body.scrollBy({ top: Math.round(body.clientHeight * 0.75), behavior: "smooth" }));
  panel.append(scrollHint);
  const updateScrollHint = () => {
    scrollHint.classList.toggle("show", body.scrollTop + body.clientHeight < body.scrollHeight - 8);
  };
  body.addEventListener("scroll", updateScrollHint);
  window.setTimeout(updateScrollHint, 250);
  window.setTimeout(updateScrollHint, 700);   // อีกครั้งหลังไทม์ไลน์โหลด (ความสูงเปลี่ยน)

  document.body.append(root);
  requestAnimationFrame(() => root.classList.add("show"));   // trigger slide-in
  // เด้งจากตาราง (ตีกลับ/มีปัญหา) → เลื่อนไปการ์ดแก้ไขสถานะให้กรอกเหตุผลได้ทันที
  if (opts?.presetDelivery) {
    window.setTimeout(() => editC.card.scrollIntoView({ behavior: "smooth", block: "start" }), 330);
  }
}

// การ์ดหมวด: หัวการ์ดมี icon-box สีพาสเทล + ชื่อหมวด
function infoCard(iconId: string, tint: string, title: string): { card: HTMLElement; body: HTMLElement } {
  const body = el("div", { class: "sbcardbody" });
  const card = el("div", { class: "sbcard" },
    el("div", { class: "sbcardhd" }, el("span", { class: "sbico " + tint }, icon(iconId)), el("span", { class: "sbcardt" }, title)),
    body);
  return { card, body };
}

// ช่องข้อมูลในกริด (label เล็กด้านบน + value) · full = เต็มความกว้าง
function gridField(label: string, value: string | Node, full = false): HTMLElement {
  return el("div", { class: "sbgi" + (full ? " full" : "") },
    el("span", { class: "sbgl" }, label),
    el("span", { class: "sbgv" }, typeof value === "string" ? (value || "—") : value));
}

// chip สถานะ: แต่ละตัวเลือกเห็นทันที (คลิกเลือก) — สีตาม badge
function chipGroup(options: string[], initial: string, badgeFn: (s: string) => { cls: string; icon: string },
  onChange: (v: string) => void): { el: HTMLElement; set: (v: string) => void } {
  let val = initial;
  const wrap = el("div", { class: "stchiprow" });
  const chips = new Map<string, HTMLElement>();
  const paint = () => { for (const [k, c] of chips) c.classList.toggle("sel", k === val); };
  for (const s of options) {
    const c = el("button", { class: "stchip", type: "button" }, badge(badgeFn(s), s));
    c.addEventListener("click", () => { val = s; paint(); onChange(s); });
    chips.set(s, c); wrap.append(c);
  }
  paint();
  return { el: wrap, set: (v: string) => { val = v; paint(); } };
}

// รายการตัวเลือกแนวตั้ง (radio) — เห็นทุกตัวเลือกทันที เช่น เหตุผลตีกลับ
// localStorage: คำใหม่ที่พิมพ์เอง + ลำดับชิป (เฉพาะเครื่องนี้)
const LS_DETAIL_LOCAL = "fa_detail_local";   // string[] คำที่พนักงานพิมพ์เอง (ลบได้)
const LS_DETAIL_ORDER = "fa_detail_order";   // string[] ลำดับการแสดงชิป
function lsGetArr(key: string): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(key) || "[]");
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
  } catch { return []; }
}
function lsSetArr(key: string, val: string[]) {
  try { localStorage.setItem(key, JSON.stringify(val)); } catch { /* quota/โหมดส่วนตัว → ข้าม */ }
}

// ชิปคำแนะนำ "รายละเอียดปัญหา" — default จาก DB (ลบไม่ได้) · คำใหม่+ลำดับ+ลบ อยู่ localStorage
function presetStrip(ta: HTMLTextAreaElement, onPick: () => void): {
  el: HTMLElement;
  commitSaved: () => void;
  syncFromText: () => void;
} {
  let defaults: string[] = [];                  // จาก DB — ลบไม่ได้
  let locals: string[] = lsGetArr(LS_DETAIL_LOCAL);
  let order: string[] = lsGetArr(LS_DETAIL_ORDER);
  let activeLabel: string | null = null;
  let dragLabel: string | null = null;

  const wrap = el("div", { class: "pstrip" });
  const row = el("div", { class: "pstriprow" });
  const prevBtn = el("button", { class: "pnav", type: "button", title: "เลื่อนซ้าย" }, "‹") as HTMLButtonElement;
  const nextBtn = el("button", { class: "pnav", type: "button", title: "เลื่อนขวา" }, "›") as HTMLButtonElement;
  const strip = el("div", { class: "pstripwrap" }, prevBtn, row, nextBtn);
  wrap.append(el("div", { class: "psublabel" }, "เลือกจากที่เคยใช้ ", el("span", { class: "phint" }, "(ลากสลับได้)")), strip);

  // ปุ่มลูกศรเลื่อนแถวชิปทีละชิป (โผล่เฉพาะตอนล้นแถว)
  function updateNav() {
    const max = row.scrollWidth - row.clientWidth;
    const over = max > 1;
    strip.classList.toggle("scroll", over);
    prevBtn.disabled = !over || row.scrollLeft <= 1;
    nextBtn.disabled = !over || row.scrollLeft >= max - 1;
  }
  function scrollByChip(dir: number) {
    const rowLeft = row.getBoundingClientRect().left;
    const chips = Array.from(row.children) as HTMLElement[];
    // ใช้ scrollBy แบบ instant — ความลื่นมาจาก CSS scroll-behavior:smooth (behavior:'smooth' ใน JS ไม่ทำงานบน container นี้)
    if (dir > 0) {
      const t = chips.find((c) => c.getBoundingClientRect().left > rowLeft + 1);
      if (t) row.scrollBy({ left: t.getBoundingClientRect().left - rowLeft });
    } else {
      const past = chips.filter((c) => c.getBoundingClientRect().left < rowLeft - 1);
      const t = past[past.length - 1];
      if (t) row.scrollBy({ left: t.getBoundingClientRect().left - rowLeft });
    }
  }
  prevBtn.addEventListener("click", () => scrollByChip(-1));
  nextBtn.addEventListener("click", () => scrollByChip(1));
  row.addEventListener("scroll", updateNav);
  // จับตอน row เปลี่ยนขนาด (เช่น บล็อกถูกโชว์จาก display:none) → คำนวณ overflow ใหม่
  new ResizeObserver(() => updateNav()).observe(row);

  const isDefault = (l: string) => defaults.includes(l);

  // รวม default + local (ไม่ซ้ำ) เรียงตาม order ที่บันทึกไว้ · คำที่ยังไม่มีในลำดับต่อท้าย
  function allLabels(): string[] {
    const set = new Set<string>();
    for (const l of defaults) set.add(l);
    for (const l of locals) set.add(l);
    const ordered = order.filter((l) => set.has(l));
    for (const l of set) if (!ordered.includes(l)) ordered.push(l);
    return ordered;
  }
  function saveOrder() { order = allLabels(); lsSetArr(LS_DETAIL_ORDER, order); }

  const paint = () => {
    for (const c of Array.from(row.children) as HTMLElement[])
      c.classList.toggle("on", c.dataset.label === activeLabel);
  };
  const clearIns = () => { for (const c of Array.from(row.children) as HTMLElement[]) c.classList.remove("insl", "insr"); };

  function pick(label: string) {
    ta.value = label; activeLabel = label; paint();
    ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length);
    onPick();
  }
  function removeLocal(label: string) {
    locals = locals.filter((l) => l !== label); lsSetArr(LS_DETAIL_LOCAL, locals);
    order = order.filter((l) => l !== label); lsSetArr(LS_DETAIL_ORDER, order);
    if (activeLabel === label) activeLabel = null;
    render();
  }
  function move(from: string, to: string, after: boolean) {
    if (from === to) return;
    const arr = allLabels();
    const fi = arr.indexOf(from); if (fi < 0) return;
    arr.splice(fi, 1);
    const ti = arr.indexOf(to); if (ti < 0) return;
    arr.splice(after ? ti + 1 : ti, 0, from);
    order = arr; lsSetArr(LS_DETAIL_ORDER, order);
    render();
  }

  function render() {
    row.textContent = "";
    for (const label of allLabels()) {
      const chip = el("div", { class: "pchip", draggable: "true" });
      chip.dataset.label = label;
      chip.append(el("span", { class: "pchiptext" }, label));
      chip.addEventListener("click", (e) => {
        if ((e.target as HTMLElement).closest(".pchipdel")) return;
        pick(label);
      });
      if (!isDefault(label)) {
        const del = el("button", { class: "pchipdel", type: "button", title: "ลบชิปนี้" }, "×");
        del.addEventListener("click", (e) => { e.stopPropagation(); removeLocal(label); });
        chip.append(del);
      }
      chip.addEventListener("dragstart", (e) => {
        dragLabel = label; chip.classList.add("drag");
        if (e.dataTransfer) e.dataTransfer.effectAllowed = "move";
      });
      chip.addEventListener("dragend", () => { dragLabel = null; chip.classList.remove("drag"); clearIns(); });
      chip.addEventListener("dragover", (e) => {
        e.preventDefault();
        if (dragLabel === null || dragLabel === label) return;
        const r = chip.getBoundingClientRect();
        const after = e.clientX > r.left + r.width / 2;
        chip.classList.toggle("insr", after);
        chip.classList.toggle("insl", !after);
      });
      chip.addEventListener("dragleave", () => chip.classList.remove("insl", "insr"));
      chip.addEventListener("drop", (e) => {
        e.preventDefault();
        chip.classList.remove("insl", "insr");
        if (dragLabel === null) return;
        const r = chip.getBoundingClientRect();
        move(dragLabel, label, e.clientX > r.left + r.width / 2);
      });
      row.append(chip);
    }
    paint();
    requestAnimationFrame(updateNav);   // อัปเดตปุ่มลูกศรหลัง layout
  }

  // โหลด default จาก DB แล้ว render (ระหว่างรอ แสดง local ไปก่อน)
  render();
  void (async () => {
    try {
      const r = await getDetailPresets("problem");
      if (r.authorized && r.ok && r.presets) defaults = r.presets.map((p) => p.label);
    } catch { /* ไม่มี default ก็ยังใช้ชิป local ได้ */ }
    saveOrder();   // ผูก default เข้าลำดับด้วย
    render();
    const cur = ta.value.trim();
    if (cur && allLabels().includes(cur)) { activeLabel = cur; paint(); }
  })();

  // ยกเลิกไฮไลต์ชิปเมื่อพิมพ์แก้จนไม่ขึ้นต้นด้วยคำในชิป
  function syncActive() {
    if (activeLabel && !ta.value.startsWith(activeLabel)) { activeLabel = null; paint(); }
  }
  // ---- autocomplete แบบ Google Sheets ----
  // พิมพ์ต่อท้าย → เติมส่วนที่เหลือของ "คำในชิป" ที่ขึ้นต้นตรงกัน (ไฮไลต์เป็น ghost)
  // ghost คือ selection ท้ายข้อความ → พิมพ์ตัวต่อไปจะทับ ghost เอง · Backspace = ตัด ghost ทิ้ง
  let ghostLabel: string | null = null;
  ta.addEventListener("input", (e) => {
    const ie = e as InputEvent;
    const it = ie.inputType || "";
    if (ie.isComposing || it.startsWith("delete") || it === "insertLineBreak") { ghostLabel = null; syncActive(); return; }
    const typed = ta.value;
    if (typed && ta.selectionStart === typed.length) {
      const match = allLabels().find((l) => l.length > typed.length && l.startsWith(typed));
      if (match) {
        ta.value = match;
        ta.setSelectionRange(typed.length, match.length);   // ไฮไลต์เฉพาะส่วนที่เติม
        ghostLabel = match;
        syncActive();
        return;
      }
    }
    ghostLabel = null;
    syncActive();
  });
  // Enter ตอนมี ghost = รับคำนั้น + เลือกชิปอัตโนมัติ (ไม่ขึ้นบรรทัดใหม่)
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && ghostLabel && ta.value === ghostLabel &&
        ta.selectionStart < ta.selectionEnd && ta.selectionEnd === ta.value.length) {
      e.preventDefault();
      const l = ghostLabel; ghostLabel = null;
      pick(l);   // ตั้ง activeLabel + ไฮไลต์ชิป + วางเคอร์เซอร์ท้าย
    }
  });

  return {
    el: wrap,
    // เรียกหลังบันทึกสำเร็จ (delivery=มีปัญหา): คำใหม่ที่พิมพ์เอง (ไม่ได้อิงชิป) → เก็บ localStorage
    commitSaved() {
      if (activeLabel) return;                       // อิงชิปเดิม = ไม่สร้างใหม่ (คำซ้ำ)
      const txt = ta.value.trim();
      if (!txt || allLabels().includes(txt)) return; // ว่าง/มีอยู่แล้ว → ข้าม
      locals.push(txt); lsSetArr(LS_DETAIL_LOCAL, locals);
      saveOrder();
    },
    syncFromText: syncActive,
  };
}

function chipList(options: string[], initial: string, onChange: (v: string) => void): { el: HTMLElement; set: (v: string) => void } {
  let val = initial;
  const wrap = el("div", { class: "rlist" });
  const rows = new Map<string, HTMLElement>();
  const paint = () => { for (const [k, r] of rows) r.classList.toggle("sel", k === val); };
  for (const s of options) {
    const r = el("button", { class: "ritem", type: "button" }, el("span", { class: "rdot" }), el("span", {}, s));
    r.addEventListener("click", () => { val = s; paint(); onChange(s); });
    rows.set(s, r); wrap.append(r);
  }
  paint();
  return { el: wrap, set: (v: string) => { val = v; paint(); } };
}

async function loadTimeline(orderId: number, noteBox: HTMLElement, logBox: HTMLElement, noteCount?: HTMLElement) {
  try {
    const r = await getOrderTracking(orderId);
    if (!r.authorized) { toLogin(); return; }
    const all = r.timeline ?? [];
    const notes = all.filter((e) => e.type === "note");
    if (noteCount) noteCount.textContent = notes.length ? `(${notes.length})` : "";
    renderNotes(noteBox, notes);
    renderTimeline(logBox, all.filter((e) => e.type !== "note"));
  } catch {
    for (const b of [noteBox, logBox]) { b.textContent = ""; b.append(el("div", { class: "tlempty err" }, "โหลดไม่สำเร็จ")); }
  }
}

// ประวัติโน้ต (แยก) — บับเบิลครีม
function renderNotes(box: HTMLElement, notes: TrackingEntry[]) {
  box.textContent = "";
  if (notes.length === 0) { box.append(el("div", { class: "tlempty" }, "ยังไม่มีโน้ต")); return; }
  for (const e of notes) {
    const item = el("div", { class: "notecard" });
    item.append(el("div", { class: "tlhead" },
      el("span", { class: "tldate" }, trackTime(e.at)), el("span", { class: "tlby" }, e.by || "—")));
    item.append(el("div", { class: "notebody" }, e.note ?? ""));
    box.append(item);
  }
}

// เบอร์โทรใส่ขีด (เฉพาะ sidebar): 10 หลัก→089-772-7171, 9 หลัก→02-XXX-XXXX
function fmtPhone(p: string): string {
  const d = (p || "").replace(/\D/g, "");
  if (d.length === 10) return `${d.slice(0, 3)}-${d.slice(3, 6)}-${d.slice(6)}`;
  if (d.length === 9) return `${d.slice(0, 2)}-${d.slice(2, 5)}-${d.slice(5)}`;
  return p || "";
}

function trackTime(at: string): string {
  const [d, t] = at.split("T");
  const [y, m, day] = d.split("-").map(Number);
  return `${day}/${m}/${y} - ${(t || "00:00:00").slice(0, 5)}`;
}

function tlNode(type: TrackingEntry["type"]): { iconId: string; cls: string } {
  if (type === "delivery_change") return { iconId: "i-truck", cls: "nd-blue" };
  if (type === "payment_change") return { iconId: "i-coin", cls: "nd-green" };
  return { iconId: "i-msg", cls: "nd-amber" };
}

function tlContent(e: TrackingEntry): (Node | string)[] {
  if (e.type === "note") return [e.note ?? ""];
  const bfn = e.type === "delivery_change" ? deliveryBadge : paymentBadge;
  const parts: (Node | string)[] = [
    badge(bfn(e.old ?? ""), e.old ?? "—"),
    el("span", { class: "tlarrow" }, icon("i-chev-r", "width:.85em")),
    badge(bfn(e.new ?? ""), e.new ?? "—"),
  ];
  if (e.detail) parts.push(el("div", { class: "tldetail" }, e.detail));
  return parts;
}

function renderTimeline(box: HTMLElement, entries: TrackingEntry[]) {
  box.textContent = "";
  if (entries.length === 0) { box.append(el("div", { class: "tlempty" }, "ยังไม่มีประวัติการติดตาม")); return; }
  const wrap = el("div", { class: "tlwrap" });
  for (const e of entries) {
    const n = tlNode(e.type);
    const row = el("div", { class: "tlrow " + e.type });
    row.append(el("span", { class: "tlnode " + n.cls }, icon(n.iconId)));
    const main = el("div", { class: "tlmain" });
    main.append(el("div", { class: "tlhead" },
      el("span", { class: "tldate" }, trackTime(e.at)), el("span", { class: "tlby" }, e.by || "—")));
    main.append(el("div", { class: "tlbody" + (e.type === "note" ? " tlnote" : "") }, ...tlContent(e)));
    row.append(main);
    wrap.append(row);
  }
  box.append(wrap);
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
  const asc = el("a", { class: state.sort?.col === col.key && state.sort.dir === "asc" ? "act" : "" }, icon("i-sortaz"), "เรียง A → Z");
  const desc = el("a", { class: state.sort?.col === col.key && state.sort.dir === "desc" ? "act" : "" }, icon("i-sortza"), "เรียง Z → A");
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
  const cancel = el("button", { class: "btncancel" }, "ยกเลิก");
  const apply = el("button", { class: "fbtn p" }, "ใช้ตัวกรอง");
  cancel.addEventListener("click", closeDrop);
  apply.addEventListener("click", () => {
    // ครบทุกค่า = ไม่กรอง
    if (temp.size === values.length) state.filters.delete(col.key);
    else state.filters.set(col.key, new Set(temp));
    closeDrop();
    renderTable();             // การเลือกไม่หาย (persist ข้ามการกรอง)
  });
  actions.append(cancel, apply);
  drop.append(actions);

  th.append(drop);
  // กันกล่องล้นขอบจอ: คอลัมน์ซ้ายสุด (วันที่) ที่ right:0 จะยื่นทะลุซ้าย → สลับมาชิดซ้าย
  if (drop.getBoundingClientRect().left < 8) {
    drop.style.right = "auto";
    drop.style.left = "0";
  }
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
    chip.addEventListener("click", () => { state.filters.delete(col); renderTable(); });
    root.append(chip);
  }
  const clall = el("span", { class: "clearall" }, "ล้างทั้งหมด");
  clall.addEventListener("click", () => { state.filters.clear(); renderTable(); });
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
  let searchTimer: number | undefined;
  si.addEventListener("input", () => {
    state.search = si.value;
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => { if (state.data) renderTable(); }, 160); // debounce กันค้าง
  });

  // ปุ่มนำเข้าไฟล์ (Stage 2)
  $("#importBtn").addEventListener("click", () => openImportModal());

  // logout
  $("#logoutBtn").addEventListener("click", async () => {
    const t = getToken();
    if (t) await authLogout(t);
    toLogin();
  });

  // idle-timeout: ออกจากระบบอัตโนมัติถ้าไม่มีการใช้งานเกิน 90 นาที (ตรงกับฝั่ง DB)
  setupIdleTracking();

  // ปิด dropdown/picker เมื่อคลิกนอก
  document.addEventListener("click", (e) => {
    const t = e.target as Node;
    if (openDrop && !openDrop.contains(t) && !(t as HTMLElement).closest?.(".funnel") && !(t as HTMLElement).closest?.(".stedit")) closeDrop();
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
    resetIdle();                       // เริ่มนับ idle-timeout เมื่อเข้าแอป
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
  window.clearTimeout(idleTimer);     // หยุดนับ idle เมื่อออกจากระบบ
  closeImportModal();
  closeSidebar();
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

// ======================================================
//  Idle-timeout — auto logout 90 นาทีหลัง action ล่าสุด (ตรงกับ DB)
// ======================================================
const IDLE_MS = 30 * 60 * 1000;   // idle-timeout 30 นาที (ตรงกับ DB app_session_uid)
let idleTimer: number | undefined;
let lastIdleReset = 0;

function resetIdle() {
  if (!document.body.classList.contains("authed")) return;
  window.clearTimeout(idleTimer);
  idleTimer = window.setTimeout(onIdleExpire, IDLE_MS);
}
function onIdleExpire() {
  const t = getToken();
  if (t) void authLogout(t);
  toLogin();
  toast("ไม่มีการใช้งานเกิน 30 นาที — ออกจากระบบอัตโนมัติ", false);
}
function setupIdleTracking() {
  const onActivity = () => {
    const now = Date.now();
    if (now - lastIdleReset > 30000) { lastIdleReset = now; resetIdle(); } // throttle 30 วิ
  };
  for (const ev of ["mousemove", "keydown", "click", "scroll", "touchstart"]) {
    document.addEventListener(ev, onActivity, { passive: true });
  }
}

// ======================================================
//  นำเข้าไฟล์ (Stage 2)
// ======================================================
let importOv: HTMLElement | null = null;
let importRows: ImportRow[] = [];

function closeImportModal() {
  if (importOv) { importOv.remove(); importOv = null; }
  importRows = [];
}

function openImportModal() {
  closeImportModal();
  const ov = el("div", { class: "modal-ov" });
  const modal = el("div", { class: "modal" });
  const head = el("div", { class: "modal-head" },
    el("div", { class: "modal-title" }, icon("i-upload"), "นำเข้าไฟล์ออเดอร์"));
  const closeX = el("button", { class: "modal-x", title: "ปิด" }, icon("i-close"));
  closeX.addEventListener("click", closeImportModal);
  head.append(closeX);
  const body = el("div", { class: "modal-body" });
  modal.append(head, body);
  ov.append(modal);
  document.body.append(ov);
  importOv = ov;
  ov.addEventListener("click", (e) => { if (e.target === ov) closeImportModal(); });
  showImportPick(body);
}

function showImportPick(body: HTMLElement) {
  body.textContent = "";
  const drop = el("label", { class: "importdrop" });
  const inp = el("input", { type: "file", accept: ".xlsx", hidden: "" }) as HTMLInputElement;
  drop.append(
    icon("i-upload"),
    el("div", { class: "idt" }, "เลือกไฟล์ Export Orders (.xlsx) จาก GoSell"),
    el("div", { class: "ids" }, "คลิกเพื่อเลือก หรือลากไฟล์มาวาง"),
    inp);
  inp.addEventListener("change", () => { if (inp.files?.[0]) void handleImportFile(inp.files[0], body); });
  drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
  drop.addEventListener("dragleave", () => drop.classList.remove("over"));
  drop.addEventListener("drop", (e) => {
    e.preventDefault(); drop.classList.remove("over");
    const f = e.dataTransfer?.files?.[0];
    if (f) void handleImportFile(f, body);
  });
  body.append(drop,
    el("div", { class: "importnote" }, "ระบบจะข้ามออเดอร์ที่ยกเลิก · ตรวจวันซ้ำ/แบรนด์ · ให้ยืนยันก่อนบันทึกจริง"));
}

function importLoading(body: HTMLElement, msg: string) {
  body.textContent = "";
  body.append(el("div", { class: "importstate" }, el("span", { class: "spin" }), msg));
}
function importError(body: HTMLElement, msg: string) {
  body.textContent = "";
  body.append(el("div", { class: "importstate err" }, icon("i-x"), msg));
  const again = el("button", { class: "fbtn" }, "เลือกไฟล์ใหม่");
  again.addEventListener("click", () => showImportPick(body));
  body.append(el("div", { class: "modal-foot" }, again));
}

async function handleImportFile(file: File, body: HTMLElement) {
  if (!/\.xlsx$/i.test(file.name)) { importError(body, "รองรับเฉพาะไฟล์ .xlsx เท่านั้น"); return; }
  importLoading(body, `กำลังอ่านไฟล์ "${file.name}"...`);
  let parsed: ParseResult;
  try {
    parsed = parseWorkbook(await file.arrayBuffer());
  } catch (e: any) {
    importError(body, e?.message ?? "อ่านไฟล์ไม่สำเร็จ");
    return;
  }
  if (parsed.rows.length === 0) {
    importError(body, "ไม่พบออเดอร์ที่นำเข้าได้ในไฟล์นี้" + (parsed.skipped.length ? ` (ข้าม ${parsed.skipped.length} รายการ)` : ""));
    return;
  }
  importRows = parsed.rows;
  importLoading(body, "กำลังตรวจสอบข้อมูล...");
  let pre: ImportResp;
  try {
    pre = await importOrders(parsed.rows, "preflight");
  } catch (e: any) {
    importError(body, "ตรวจสอบข้อมูลไม่สำเร็จ: " + (e?.message ?? e));
    return;
  }
  if (!pre.authorized) { closeImportModal(); toLogin(); return; }
  showImportPreview(body, file.name, parsed, pre);
}

function istat(val: string, label: string, tone: string): HTMLElement {
  return el("div", { class: `istat ${tone}` }, el("div", { class: "iv num" }, val), el("div", { class: "il" }, label));
}
function collapsible(title: string, items: string[]): HTMLElement {
  const wrap = el("details", { class: "icollapse" });
  wrap.append(el("summary", {}, title));
  const list = el("div", { class: "ilist" });
  for (const it of items.slice(0, 100)) list.append(el("div", {}, it));
  if (items.length > 100) list.append(el("div", { class: "more" }, `…และอีก ${items.length - 100} รายการ`));
  wrap.append(list);
  return wrap;
}

function showImportPreview(body: HTMLElement, fname: string, parsed: ParseResult, pre: ImportResp) {
  body.textContent = "";
  const canConfirm = !!pre.ok && (pre.orders_ok ?? 0) > 0;
  const dates = pre.dates ?? [];
  const dateLabel = dates.length ? dates.map(dmy).join(", ") : "—";

  body.append(el("div", { class: "ifile" }, icon("i-check"), fname));
  body.append(el("div", { class: "iline" }, "วันที่ในไฟล์: ", el("b", {}, dateLabel)));
  body.append(el("div", { class: "istats" },
    istat(nf(pre.orders_ok ?? 0), "ออเดอร์จะนำเข้า", "blue"),
    istat("฿" + nf(pre.total_sales ?? 0), "ยอดขายรวม", "green"),
    istat(nf(pre.new_customers ?? 0), "ลูกค้าใหม่", "plain")));

  if (pre.error) body.append(el("div", { class: "ibox err" }, icon("i-x"), pre.error));

  const problems = pre.problems ?? [];
  if (problems.length) {
    const box = el("div", { class: "ibox err" });
    box.append(el("div", { class: "ibh" }, icon("i-x"), `มี ${problems.length} ออเดอร์ที่นำเข้าไม่ได้ (ต้องแก้ไฟล์ก่อน)`));
    const list = el("div", { class: "ilist" });
    for (const p of problems.slice(0, 20)) list.append(el("div", {}, `#${p.order_no} — ${p.reason}`));
    if (problems.length > 20) list.append(el("div", { class: "more" }, `…และอีก ${problems.length - 20} รายการ`));
    box.append(list);
    body.append(box);
  }

  if (parsed.skipped.length) body.append(collapsible(`ข้ามอัตโนมัติ ${parsed.skipped.length} รายการ`, parsed.skipped));
  const warns = [...parsed.warnings, ...(pre.warnings ?? []).map((w) => `สินค้าไม่พบในระบบ: ${w}`)];
  if (warns.length) body.append(collapsible(`หมายเหตุ ${warns.length} รายการ`, warns));

  const foot = el("div", { class: "modal-foot" });
  const cancel = el("button", { class: "fbtn" }, "เลือกไฟล์ใหม่");
  cancel.addEventListener("click", () => showImportPick(body));
  const confirm = el("button", { class: "btn" }, icon("i-upload"), `ยืนยันนำเข้า ${nf(pre.orders_ok ?? 0)} ออเดอร์`) as HTMLButtonElement;
  confirm.disabled = !canConfirm;
  confirm.addEventListener("click", () => void doImportConfirm(body));
  foot.append(cancel, confirm);
  body.append(foot);
}

async function doImportConfirm(body: HTMLElement) {
  importLoading(body, "กำลังนำเข้าข้อมูล...");
  let res: ImportResp;
  try {
    res = await importOrders(importRows, "confirm");
  } catch (e: any) {
    importError(body, "นำเข้าไม่สำเร็จ: " + (e?.message ?? e));
    return;
  }
  if (!res.authorized) { closeImportModal(); toLogin(); return; }
  if (!res.ok) { importError(body, res.error ?? "นำเข้าไม่สำเร็จ (ข้อมูลไม่ผ่านการตรวจสอบ)"); return; }
  const importedMonth = (res.dates?.[0] ?? "").slice(0, 7);
  closeImportModal();
  toast(`นำเข้าสำเร็จ ${nf(res.inserted ?? 0)} ออเดอร์`);
  await refreshAfterImport(importedMonth);
}

async function refreshAfterImport(month: string) {
  try {
    const m = await fetchMonths();
    if (!m.authorized) { toLogin(); return; }
    state.monthsWithData = new Set(m.months ?? []);
    const target = /^\d{4}-\d{2}$/.test(month) ? month : (state.month || (m.months ?? [])[0]);
    if (target) await loadMonth(target);
    else buildMonthPicker();
  } catch { /* นำเข้าแล้ว refresh พลาดไม่ร้ายแรง */ }
}

bootstrap();
