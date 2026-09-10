// หน้า "ค้นหา" (Stage 9c) — ค้นทั้งระบบ 4 ฟิลด์ (เบอร์/ชื่อ/ที่อยู่/แทร็คส่งออก) ข้ามรอบเดือน
// 2 โหมด: แบบออเดอร์ / แบบหักยอดตีกลับ — ยกตาราง+funnel+การ์ดของหน้านั้นๆ มาเลย (คำนวณจากผลค้นหา · ไม่มีเดือน)
// ตาราง+ตัวกรอง funnel + caret ใช้คลาสร่วมกับหน้า order/หักยอด · ไม่มี sidebar (ดูจากตารางพอ)
import { el, icon, nf, dmy, deliveryBadge, paymentBadge, paymentStatusLabel, paymentMethodLabel } from "./util";
import { makeVTable, type VTable } from "./virtual";
import { searchOrders, type SearchRow, type SearchResp } from "./api";

let toastFn: (m: string, ok?: boolean) => void = () => {};
let root: HTMLElement;
let view: "order" | "deduct" = "order";
let resp: SearchResp | null = null;
let allRows: SearchRow[] = [];
let query = "";
let debTimer = 0;
let reqSeq = 0;
const filters = new Map<string, Set<string>>();
let sort: { key: string; dir: "asc" | "desc" } | null = null;
let openDrop: HTMLElement | null = null;
let outsideBound = false;
const RECENT_KEY = "fa_search_recent";

const q = <T extends HTMLElement = HTMLElement>(sel: string) => root.querySelector(sel) as T | null;
const dash = (s: string | null | undefined) => (s && s.trim() !== "" ? s : "—");
const badge = (cls: string, ic: string, label: string) => ic ? el("span", { class: `badge ${cls}` }, icon(ic), label) : el("span", { class: `badge ${cls}` }, label);

// ---------- recent ----------
function getRecent(): string[] { try { return JSON.parse(localStorage.getItem(RECENT_KEY) || "[]"); } catch { return []; } }
function pushRecent(term: string) { const t = term.trim(); if (t.length < 2) return; localStorage.setItem(RECENT_KEY, JSON.stringify([t, ...getRecent().filter((x) => x !== t)].slice(0, 8))); }

// ---------- highlight ----------
function highlight(text: string | null | undefined): Node {
  const s = text ?? ""; const term = query.trim();
  if (!s || term.length < 2) return document.createTextNode(s || "—");
  const frag = document.createDocumentFragment();
  const low = s.toLowerCase(); const t = term.toLowerCase();
  let i = 0, idx: number;
  while ((idx = low.indexOf(t, i)) !== -1) { if (idx > i) frag.append(s.slice(i, idx)); frag.append(el("mark", { class: "srch-hl" }, s.slice(idx, idx + term.length))); i = idx + term.length; }
  if (i < s.length) frag.append(s.slice(i));
  return frag;
}

// ---------- cells (คลาสร่วมกับหน้า order/หักยอด) ----------
function caretToggle(extra = ""): HTMLElement {
  const tog = el("span", { class: `itemtoggle ${extra}`.trim(), title: "ดู/ซ่อนรายละเอียดทั้งแถว" }, icon("i-caret")) as HTMLElement;
  tog.addEventListener("click", (e) => { e.stopPropagation(); const tr = (e.currentTarget as HTMLElement).closest("tr") as HTMLElement | null; if (tr) toggleSearchRow(tr); });
  return tog;
}
function itemsCell(r: SearchRow): Node {
  const s = (r.items ?? "").trim(); if (!s) return document.createTextNode("—");
  const lines = s.split("\n"); const frag = document.createDocumentFragment();
  const first = el("div", { class: "iln0" }, el("span", { class: "itxt", title: lines[0] }, lines[0]));
  if (lines.length > 1) { first.append(caretToggle()); const rest = el("div", { class: "itemrest" }); for (let i = 1; i < lines.length; i++) rest.append(el("div", { class: "iln", title: lines[i] }, lines[i])); frag.append(first, rest); }
  else frag.append(first);
  return frag;
}
function nameCell(r: SearchRow): Node {
  const name = r.customer_name; if (!name) return document.createTextNode("—");
  const frag = document.createDocumentFragment(); const tog = caretToggle("nametoggle"); tog.style.display = "none";
  frag.append(el("div", { class: "nameline" }, el("span", { class: "ntxt name", title: name }, highlight(name)), tog));
  return frag;
}
function addrCell(r: SearchRow): Node {
  const a = r.address; if (!a) return document.createTextNode("—");
  const frag = document.createDocumentFragment(); const tog = caretToggle("addrtoggle"); tog.style.display = "none";
  frag.append(el("div", { class: "addrline" }, el("span", { class: "atxt", title: a }, highlight(a)), el("div", { class: "addrparts" }, el("div", { class: "apart" }, a)), tog));
  return frag;
}
function sellerCell(r: SearchRow): Node {
  if (!r.seller_code) return document.createTextNode("—");
  const box = el("span", { class: "rlseller" }, el("span", { class: "rlcode" }, r.seller_code));
  if (r.seller_name) box.append(" ", el("span", { class: "rlsname" }, r.seller_name));
  return box;
}

// ---------- columns (ยกจากหน้า order / หักยอด · มี val สำหรับ funnel) ----------
interface Col { key: string; label: string; td?: string; th?: string; align?: "right" | "center"; numeric?: boolean; val: (r: SearchRow) => string; render: (r: SearchRow) => Node | string; }
const delivBadge = (r: SearchRow): Node | string => { const b = deliveryBadge(r.delivery_status ?? ""); return r.delivery_status ? badge(b.cls, b.icon, r.delivery_status) : "—"; };
const payBadge = (r: SearchRow): Node | string => { const b = paymentBadge(r.payment_status ?? ""); return r.payment_status ? badge(b.cls, b.icon, paymentStatusLabel(r.payment_status)) : "—"; };
const COLS_ORDER: Col[] = [
  { key: "ordered_at", label: "วันที่", th: "datehead", td: "datecell", val: (r) => r.ordered_at, render: (r) => dmy(r.ordered_at) },
  { key: "phone", label: "เบอร์โทร", td: "mono", val: (r) => r.phone ?? "", render: (r) => highlight(r.phone) },
  { key: "customer_name", label: "ชื่อลูกค้า", td: "name-cell", val: (r) => r.customer_name ?? "", render: nameCell },
  { key: "address", label: "ที่อยู่", td: "addr-cell", val: (r) => r.address ?? "", render: addrCell },
  { key: "items", label: "รายการสินค้า", td: "items", val: (r) => (r.items ?? "").replace(/\n/g, ", "), render: itemsCell },
  { key: "payment_method", label: "ชำระ", align: "right", td: "tar", val: (r) => paymentMethodLabel(r.payment_method ?? ""), render: (r) => dash(paymentMethodLabel(r.payment_method ?? "")) },
  { key: "total_sales", label: "ยอดขาย", align: "right", numeric: true, td: "amount num", val: (r) => String(r.total_sales), render: (r) => nf(r.total_sales) },
  { key: "carrier", label: "ขนส่ง", val: (r) => r.carrier ?? "", render: (r) => dash(r.carrier) },
  { key: "tracking_out", label: "เลขแทร็ค", td: "mono", val: (r) => r.tracking_out ?? "", render: (r) => highlight(r.tracking_out) },
  { key: "delivery_status", label: "สถานะจัดส่ง", align: "center", val: (r) => r.delivery_status ?? "", render: delivBadge },
  { key: "payment_status", label: "สถานะชำระ", align: "center", val: (r) => r.payment_status ?? "", render: payBadge },
  { key: "return_arrived", label: "ตีกลับถึงแล้ว", align: "center", val: (r) => (r.return_arrived ? "ถึงแล้ว" : "—"), render: (r) => (r.return_arrived ? badge("g", "i-return", "ถึงแล้ว") : "—") },
  { key: "note", label: "หมายเหตุ", val: (r) => r.note ?? "", render: (r) => el("span", { class: "notetxt mono", title: r.note ?? "" }, r.note ? highlight(r.note) : "—") },
];
const COLS_DEDUCT: Col[] = [
  { key: "ordered_at", label: "วันที่", th: "datehead", td: "datecell", val: (r) => r.ordered_at, render: (r) => dmy(r.ordered_at) },
  { key: "phone", label: "เบอร์โทร", td: "mono", val: (r) => r.phone ?? "", render: (r) => highlight(r.phone) },
  { key: "customer_name", label: "ชื่อลูกค้า", td: "name-cell", val: (r) => r.customer_name ?? "", render: nameCell },
  { key: "team_name", label: "ทีม", td: "rlteam", val: (r) => r.team_name ?? "", render: (r) => dash(r.team_name) },
  { key: "seller_code", label: "ผู้ขาย", val: (r) => r.seller_code ?? "", render: sellerCell },
  { key: "items", label: "รายการสินค้า", td: "items", val: (r) => (r.items ?? "").replace(/\n/g, ", "), render: itemsCell },
  { key: "total_sales", label: "ยอดขาย", align: "right", numeric: true, td: "amount num", val: (r) => String(r.total_sales), render: (r) => nf(r.total_sales) },
  { key: "carrier", label: "ขนส่ง", val: (r) => r.carrier ?? "", render: (r) => dash(r.carrier) },
  { key: "tracking_out", label: "เลขแทร็ค", td: "mono", val: (r) => r.tracking_out ?? "", render: (r) => highlight(r.tracking_out) },
  { key: "return_date", label: "วันตีกลับถึง", th: "datehead", td: "datecell", val: (r) => r.return_date ?? "", render: (r) => (r.return_date ? dmy(r.return_date) : "—") },
  { key: "cycle", label: "รอบเดือน", td: "rlteam", val: (r) => r.cycle_label ?? "", render: (r) => { const box = el("span", {}, el("span", { class: "srch-cycle" }, r.cycle_label || "—")); if (r.no_deduct) box.append(" ", badge("n", "i-ban", "ไม่หัก")); return box; } },
];
const cols = (): Col[] => (view === "deduct" ? COLS_DEDUCT : COLS_ORDER);

// ---------- virtual scrolling ----------
let srchVt: VTable | null = null;
let srchVisible: SearchRow[] = [];
let srchCols: Col[] = [];
const srchExpanded = new Set<number>();
function buildSearchRow(i: number): HTMLElement {
  const r = srchVisible[i];
  const tr = el("tr", {}) as HTMLElement;
  tr.dataset.idx = String(i);
  if (srchExpanded.has(i)) tr.classList.add("rowopen");
  for (const c of srchCols) tr.append(el("td", { class: c.td || "" }, c.render(r)));
  return tr;
}
function toggleSearchRow(tr: HTMLElement) {
  const i = Number(tr.dataset.idx);
  if (!Number.isFinite(i)) return;
  const open = tr.classList.toggle("rowopen");
  if (open) { srchExpanded.add(i); srchVt?.setRowHeight(i, tr.getBoundingClientRect().height); }
  else { srchExpanded.delete(i); srchVt?.setRowHeight(i, null); }
}
function srchMeasureToggles(scope: ParentNode) {
  for (const tx of scope.querySelectorAll<HTMLElement>(".ntxt, .atxt")) {
    if (tx.scrollWidth > tx.clientWidth + 1) { const tog = tx.parentElement?.querySelector<HTMLElement>(".itemtoggle"); if (tog) tog.style.display = ""; }
  }
}

// ---------- filter/sort (funnel — ยกจากหน้า order/หักยอด) ----------
function computeVisible(): SearchRow[] {
  const cs = cols();
  let rows = allRows;
  for (const [key, set] of filters) { const col = cs.find((c) => c.key === key); if (col) rows = rows.filter((r) => set.has(col.val(r))); }
  if (sort) { const col = cs.find((c) => c.key === sort!.key); if (col) { const dir = sort.dir === "asc" ? 1 : -1; rows = [...rows].sort((a, b) => col.numeric ? (Number(col.val(a)) - Number(col.val(b))) * dir : col.val(a).localeCompare(col.val(b), "th") * dir); } }
  return rows;
}
function distinctValues(col: Col): { value: string; count: number }[] {
  const m = new Map<string, number>();
  for (const r of allRows) { const v = col.val(r); m.set(v, (m.get(v) ?? 0) + 1); }
  return [...m.entries()].map(([value, count]) => ({ value, count })).sort((a, b) => col.numeric ? Number(a.value) - Number(b.value) : a.value.localeCompare(b.value, "th"));
}
function closeDrop() { if (openDrop) { openDrop.remove(); openDrop = null; } }
function buildTh(col: Col): HTMLElement {
  const th = el("th", {});
  if (col.th) th.classList.add(...col.th.split(" "));
  if (col.align === "center") th.classList.add("c");
  if (col.align === "right") th.classList.add("rcol");
  const active = filters.has(col.key);
  if (active) th.classList.add("filtered");
  const hh = el("div", { class: "hh" }, col.label);
  const funnel = el("span", { class: "funnel" + (active ? " on" : "") }, icon("i-funnel"));
  funnel.addEventListener("click", (e) => { e.stopPropagation(); openFilter(th, col); });
  hh.append(funnel); th.append(hh);
  return th;
}
function openFilter(th: HTMLElement, col: Col) {
  if (openDrop && openDrop.dataset.col === col.key) { closeDrop(); return; }
  closeDrop();
  const values = distinctValues(col);
  const current = filters.get(col.key);
  const temp = new Set<string>(current ? current : values.map((v) => v.value));
  const drop = el("div", { class: "fdrop" }); drop.dataset.col = col.key; openDrop = drop;
  const sortSec = el("div", { class: "sec fsort" });
  const asc = el("a", { class: sort?.key === col.key && sort.dir === "asc" ? "act" : "" }, icon("i-sortaz"), "เรียง A → Z");
  const desc = el("a", { class: sort?.key === col.key && sort.dir === "desc" ? "act" : "" }, icon("i-sortza"), "เรียง Z → A");
  asc.addEventListener("click", () => { sort = { key: col.key, dir: "asc" }; closeDrop(); paint(); });
  desc.addEventListener("click", () => { sort = { key: col.key, dir: "desc" }; closeDrop(); paint(); });
  sortSec.append(asc, desc); drop.append(sortSec);
  const searchSec = el("div", { class: "sec" });
  const fs = el("div", { class: "fsearch" }, icon("i-search"));
  const inp = el("input", { placeholder: "ค้นหาค่า..." }) as HTMLInputElement;
  fs.append(inp); searchSec.append(fs); drop.append(searchSec);
  const listSec = el("div", { class: "sec" });
  const links = el("div", { class: "flinks" });
  const selAll = el("a", {}, "เลือกทั้งหมด"); const clr = el("a", {}, "ล้าง");
  links.append(selAll, " · ", clr);
  const fvals = el("div", { class: "fvals" });
  listSec.append(links, fvals); drop.append(listSec);
  const rowEls: { cbx: HTMLElement }[] = [];
  function renderVals(filterText = "") {
    fvals.textContent = ""; rowEls.length = 0;
    const qq = filterText.trim().toLowerCase();
    for (const { value, count } of values) {
      const label = value === "" ? "(ว่าง)" : value;
      if (qq && !label.toLowerCase().includes(qq)) continue;
      const cbx = el("span", { class: "cbx" + (temp.has(value) ? "" : " off") }, icon("i-tick"));
      const row = el("div", { class: "fval" }, cbx, label, el("span", { class: "cnt" }, nf(count)));
      row.addEventListener("click", () => { if (temp.has(value)) { temp.delete(value); cbx.classList.add("off"); } else { temp.add(value); cbx.classList.remove("off"); } });
      fvals.append(row); rowEls.push({ cbx });
    }
  }
  renderVals();
  inp.addEventListener("input", () => renderVals(inp.value));
  selAll.addEventListener("click", () => { for (const v of values) temp.add(v.value); rowEls.forEach((r) => r.cbx.classList.remove("off")); });
  clr.addEventListener("click", () => { temp.clear(); rowEls.forEach((r) => r.cbx.classList.add("off")); });
  const actions = el("div", { class: "factions" });
  const cancel = el("button", { class: "btncancel" }, "ยกเลิก");
  const apply = el("button", { class: "fbtn p" }, "ใช้ตัวกรอง");
  cancel.addEventListener("click", closeDrop);
  apply.addEventListener("click", () => { if (temp.size === values.length) filters.delete(col.key); else filters.set(col.key, new Set(temp)); closeDrop(); paint(); });
  actions.append(cancel, apply); drop.append(actions);
  th.append(drop);
  if (drop.getBoundingClientRect().left < 8) { drop.style.right = "auto"; drop.style.left = "0"; }
  inp.focus();
}

// ---------- KPI cards — ยกการ์ดจริงของหน้า order/หักยอด มาเลย (ตัดกราฟ) ----------
function kmain(big: Node, unit: string): HTMLElement { return el("div", { class: "kmain" }, big, el("div", { class: "kunit" }, unit)); }
function kbig(num: string, color?: string): HTMLElement { return el("div", { class: "kbig num", ...(color ? { style: "color:" + color } : {}) }, num); }
function kbigCur(cur: string, num: string, color?: string): HTMLElement { const b = el("div", { class: "kbig num", ...(color ? { style: "color:" + color } : {}) }); b.append(el("small", {}, cur), " " + num); return b; }
function kcol(val: Node | string, label: string, color?: string): HTMLElement {
  return el("div", {}, el("div", { class: "sv num", ...(color ? { style: "color:" + color } : {}) }, val), el("div", { class: "l" }, label));
}
function kdetail(...c: HTMLElement[]): HTMLElement { return el("div", { class: "kdetail" }, el("div", { class: "ksub" }, ...c)); }
function kcardSplit(color: string, ic: string, title: string, main: Node, detail: Node): HTMLElement {
  const card = el("div", { class: `kcard t${color}` });
  const wm = icon(ic); wm.setAttribute("class", `wm ${color}`);
  card.append(wm, el("div", { class: "khead" }, el("div", { class: `kicon ${color}` }, icon(ic)), el("div", { class: "ktitle" }, title)), el("div", { class: "krow2" }, main, detail));
  return card;
}
function rlkpi(cls: string, ic: string, lbl: string, valCls: string, val: Node | string, sub?: Node | string): HTMLElement {
  return el("div", { class: `rlkpi ${cls}` }, el("span", { class: "rlkpi-ic" }, icon(ic)),
    el("div", { class: "rlkpi-body" }, el("span", { class: "rlkpi-lbl" }, lbl), el("span", { class: valCls }, val), sub != null ? el("span", { class: "rlkpi-sub" }, sub) : ""));
}
function buildCards(rows: SearchRow[]): HTMLElement {
  if (view === "order") {
    const exported = rows.filter((r) => r.delivery_status && r.delivery_status !== "รอส่ง").length;
    const delivered = rows.filter((r) => r.delivery_status === "ส่งสำเร็จ").length;
    const succRate = exported ? (delivered / exported) * 100 : 0;
    const paid = rows.filter((r) => r.payment_status === "ชำระแล้ว").reduce((a, r) => a + (r.total_sales || 0), 0);
    const unpaid = rows.filter((r) => r.payment_status === "รอชำระ").reduce((a, r) => a + (r.total_sales || 0), 0);
    const total = rows.reduce((a, r) => a + (r.total_sales || 0), 0);
    const returned = rows.filter((r) => r.delivery_status === "ตีกลับ").length;
    const retAmount = rows.filter((r) => r.delivery_status === "ตีกลับ").reduce((a, r) => a + (r.total_sales || 0), 0);
    const retRate = exported ? (returned / exported) * 100 : 0;
    return el("div", { class: "srch-kcards" },
      kcardSplit("blue", "i-truck", "จำนวนส่งออก", kmain(kbig(nf(exported)), "ออเดอร์ที่ส่งจริง"),
        kdetail(kcol(nf(delivered), "ส่งสำเร็จ"), kcol(succRate.toFixed(1) + "%", "อัตราสำเร็จ", "#059669"))),
      kcardSplit("green", "i-coin", "ยอดขาย", kmain(kbigCur("฿", nf(paid), "#059669"), "ยอดที่ชำระแล้ว"),
        kdetail(kcol("฿" + nf(unpaid), "รอชำระ", "#EA580C"), kcol("฿" + nf(total), "ยอดขายรวม"))),
      kcardSplit("red", "i-return", "ตีกลับ", kmain(kbigCur("฿", nf(retAmount), "#DC2626"), "ยอดตีกลับ"),
        kdetail(kcol(nf(returned), "จำนวนออเดอร์"), kcol(retRate.toFixed(1) + "%", "อัตราตีกลับ", "#DC2626"))));
  }
  const deducted = rows.filter((r) => !r.no_deduct);
  const sum = deducted.reduce((a, r) => a + (r.total_sales || 0), 0);
  return el("div", { class: "srch-kcards" },
    rlkpi("scope", "i-grid", "ผลการค้นหา", "rlkpi-scope", `"${resp?.query ?? ""}"`, "ข้ามรอบเดือน · ตามสิทธิ์"),
    rlkpi("ded", "i-boxret-solid", "ตีกลับ (หักยอด)", "rlkpi-val", nf(deducted.length)),
    rlkpi("sale", "i-coin", "ยอดขายที่ถูกหัก", "rlkpi-val", "฿ " + nf(sum)));
}

// ---------- shell ----------
function buildShell(container: HTMLElement) {
  // ล้างการค้นหาเดิมทุกครั้งที่เข้าหน้าใหม่ (เปลี่ยนหน้าแล้วกลับมา = เริ่มใหม่)
  view = "order"; resp = null; allRows = []; query = ""; filters.clear(); sort = null; closeDrop();
  root = container; container.classList.add("srch"); container.innerHTML = "";
  const input = el("input", { class: "srch-input", id: "srchInput", type: "search", placeholder: "ค้นหา เบอร์ · ชื่อ · ที่อยู่ · แทร็ค · หมายเหตุ…", autocomplete: "off", spellcheck: "false" }) as HTMLInputElement;
  const clearBtn = el("button", { class: "srch-clear", id: "srchClear", title: "ล้าง", hidden: "" }, icon("i-x")) as HTMLButtonElement;
  const bar = el("div", { class: "srch-bar" },
    el("div", { class: "srch-inwrap" }, icon("i-search"), input, clearBtn),
    el("div", { class: "rlseg", id: "srchSeg" }, modeBtn("order", "รายออเดอร์", "i-truck-solid"), modeBtn("deduct", "หักยอด", "i-clip-solid")));
  container.append(bar, el("div", { class: "srch-recent", id: "srchRecent" }), el("div", { class: "srch-cardsrow", id: "srchCards" }), el("div", { class: "srch-meta", id: "srchMeta" }), el("div", { class: "srch-results", id: "srchResults" }));

  input.addEventListener("input", () => { query = input.value; clearBtn.hidden = query.length === 0; window.clearTimeout(debTimer); debTimer = window.setTimeout(() => void doSearch(), 320); });
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { window.clearTimeout(debTimer); void doSearch(); } if (e.key === "Escape") { input.value = ""; query = ""; clearBtn.hidden = true; resp = null; allRows = []; paint(); } });
  clearBtn.addEventListener("click", () => { input.value = ""; query = ""; clearBtn.hidden = true; resp = null; allRows = []; input.focus(); paint(); });
  root.addEventListener("keydown", (e) => { if (e.key === "/" && document.activeElement !== input) { e.preventDefault(); input.focus(); } });
  if (!outsideBound) { outsideBound = true; document.addEventListener("click", (e) => { const t = e.target as HTMLElement; if (openDrop && !t.closest?.(".fdrop") && !t.closest?.(".funnel")) closeDrop(); }); }

  paint(); setTimeout(() => input.focus(), 30);
}
function modeBtn(v: "order" | "deduct", label: string, ic: string): HTMLElement {
  const b = el("button", { class: "rlsegbtn" + (view === v ? " on" : ""), type: "button", "data-v": v }, icon(ic), el("span", {}, label));
  b.addEventListener("click", () => {
    if (view === v) return;
    view = v; filters.clear(); sort = null; closeDrop();
    root.querySelectorAll("#srchSeg .rlsegbtn").forEach((x) => x.classList.toggle("on", (x as HTMLElement).dataset.v === v));
    if (query.trim().length >= 2) void doSearch(); else paint();
  });
  return b;
}

// ---------- recent ----------
function paintRecent() {
  const box = q("#srchRecent"); if (!box) return; box.innerHTML = "";
  const list = getRecent();
  if (!list.length || (resp && resp.rows && resp.rows.length)) return;
  box.append(el("span", { class: "srch-rlabel" }, icon("i-clock"), "ค้นล่าสุด"));
  for (const t of list) { const c = el("button", { class: "srch-rchip" }, t); c.addEventListener("click", () => { const inp = q<HTMLInputElement>("#srchInput"); if (inp) { inp.value = t; query = t; (q("#srchClear") as HTMLElement).hidden = false; } void doSearch(); }); box.append(c); }
}

// ---------- search ----------
async function doSearch() {
  const term = query.trim(); const seq = ++reqSeq;
  filters.clear(); sort = null; closeDrop();
  if (term.length < 2) { resp = term.length ? { authorized: true, ok: true, too_short: true, rows: [], count: 0 } : null; allRows = []; paint(); return; }
  const results = q("#srchResults"); if (results) { results.innerHTML = ""; results.append(el("div", { class: "srch-loading" }, el("span", { class: "srch-spin" }), "กำลังค้นหา…")); }
  try { const r = await searchOrders(term, view); if (seq !== reqSeq) return; resp = r; allRows = r.rows ?? []; if (r.ok && (r.count ?? 0) > 0) pushRecent(term); }
  catch { if (seq === reqSeq) { resp = { authorized: true, ok: false, error: "network" }; allRows = []; } }
  paint(); paintRecent();
}

// ---------- paint ----------
function paint() {
  const meta = q("#srchMeta"); const results = q("#srchResults"); const cards = q("#srchCards");
  if (!meta || !results || !cards) return;
  meta.innerHTML = ""; results.innerHTML = ""; cards.innerHTML = "";
  if (!resp) { results.append(emptyState("i-search", "ค้นหาออเดอร์ทั้งระบบ", "พิมพ์ เบอร์ · ชื่อ · ที่อยู่ · แทร็คส่งออก · หมายเหตุ (อย่างน้อย 2 ตัว)")); paintRecent(); return; }
  if (resp.authorized === false) { results.append(emptyState("i-lock", "หมดสิทธิ์", "กรุณาเข้าสู่ระบบใหม่")); return; }
  if (resp.ok === false) { results.append(emptyState("i-alert", "ค้นหาไม่สำเร็จ", "เชื่อมต่อไม่ได้ ลองใหม่อีกครั้ง")); return; }
  if (resp.too_short) { results.append(emptyState("i-search", "พิมพ์อย่างน้อย 2 ตัวอักษร", "ค้นได้จาก เบอร์ · ชื่อ · ที่อยู่ · แทร็ค · หมายเหตุ")); return; }
  if (!allRows.length) { results.append(emptyState("i-search", "ไม่พบผลลัพธ์", `ไม่พบออเดอร์ที่ตรงกับ "${resp.query}"`)); return; }

  const rows = computeVisible();
  cards.append(buildCards(rows));
  const capped = (resp.count ?? 0) >= 5000;
  meta.append(
    el("span", { class: "srch-count" }, `พบ ${nf(resp.count ?? allRows.length)}${capped ? "+" : ""} รายการ`),
    filters.size || sort ? el("span", { class: "srch-metaq" }, `กรองเหลือ ${nf(rows.length)}`) : el("span", { class: "srch-metaq" }, `ค้นด้วย “${resp.query}”`),
    el("span", { class: "srch-metascope" }, view === "order" ? "ทุกออเดอร์ · ข้ามรอบเดือน" : "ตีกลับทั้งหมด · ข้ามรอบเดือน"));

  // virtual scrolling — วาดเฉพาะแถวที่เห็น (รองรับผลลัพธ์เยอะเหมือนหน้าออเดอร์)
  srchVt?.detach(); srchVt = null;
  srchCols = cols();
  srchVisible = rows;
  srchExpanded.clear();
  const table = el("table", {});
  const thr = el("tr", {}); for (const c of srchCols) thr.append(buildTh(c));
  const tbody = el("tbody", {});
  table.append(el("thead", {}, thr), tbody);
  const wrap = el("div", { class: "srch-tablewrap" }, table);
  results.append(el("div", { class: "card srch-card" }, wrap));

  if (!rows.length) {
    tbody.append(el("tr", {}, el("td", { colspan: String(srchCols.length) }, el("div", { class: "srch-empty" }, el("p", {}, "ไม่มีรายการตรงกับตัวกรอง")))));
    return;
  }
  // วัดความกว้างคอลัมน์จากตัวอย่าง → ล็อก table-layout fixed กันคอลัมน์เพี้ยนตอน virtualize
  const sampleN = Math.min(rows.length, 60);
  for (let i = 0; i < sampleN; i++) tbody.append(buildSearchRow(i));
  const ths = [...thr.children] as HTMLElement[];
  const widths = ths.map((t) => Math.ceil(t.getBoundingClientRect().width));
  const baseH = Math.round((tbody.firstElementChild as HTMLElement)?.getBoundingClientRect().height || 50);
  tbody.textContent = "";
  table.style.tableLayout = "fixed";
  ths.forEach((t, i) => { t.style.width = widths[i] + "px"; });

  srchVt = makeVTable({
    wrap, tbody, colspan: srchCols.length,
    count: () => srchVisible.length, buildRow: buildSearchRow, baseH,
    afterWindow: (tb) => srchMeasureToggles(tb),
  });
  wrap.scrollTop = 0;
  srchVt.render(true);
}
function emptyState(ic: string, title: string, sub: string): HTMLElement {
  return el("div", { class: "srch-empty" }, icon(ic), el("h3", {}, title), el("p", {}, sub));
}

// ---------- entry ----------
export function renderSearch(container: HTMLElement, opts: { toast: (m: string, ok?: boolean) => void }) {
  toastFn = opts.toast; void toastFn;
  buildShell(container);
}
