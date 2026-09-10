// หน้า "รายการตีกลับ" (Stage 9) — ธีม light เดียวกับหน้า order
// 2 โหมด:
//   • หักยอด           → recon_returns (no_deduct=false) · รอบ 26–25 ตามวันบันทึกตีกลับ · 3 การ์ด (scope+จำนวน+ยอด)
//   • สถานะตีกลับทั้งหมด → orders delivery_status='ตีกลับ' · เดือนปฏิทิน 1–สิ้นเดือน (แบบหน้า order) · การ์ด scope+จำนวน+กราฟ
// ตัวเลือกเดือน: stepper เด่น (◀ ▶ + กดเลือกจาก grid) · default = รอบ/เดือนปัจจุบันเสมอ
// สิทธิ์: Adm/Vm/all_teams เห็นทุกทีม · RTs เห็นทีมตัวเอง (คุมใน RPC) · funnel filter หัวคอลัมน์แบบหน้า order
import { el, icon, nf, dmy, paymentMethodLabel, paymentStatusLabel, deliveryBadge, paymentBadge, THAI_MONTHS_SHORT, loadColsHidden, saveColsHidden, attachTopScrollbar } from "./util";
import { fetchReturnsList, type ReturnsListResp, type ReturnListRow } from "./api";
import { makeVTable, type VTable } from "./virtual";

let toastFn: (msg: string, ok?: boolean) => void = () => {};
let data: ReturnsListResp | null = null;
let allRows: ReturnListRow[] = [];
const state = {
  cycle: null as string | null,
  mode: "deduct" as "deduct" | "status",
  teamId: null as number | null,
  sellerCode: null as string | null,
};
let pickerYear = new Date().getFullYear();
let prevOrders = 0, prevSales = 0;
// funnel filter/sort (client-side)
const filters = new Map<string, Set<string>>();
let sort: { key: string; dir: "asc" | "desc" } | null = null;
let openDrop: HTMLElement | null = null;
let outsideBound = false;
// ซ่อน/โชว์คอลัมน์ (แยกตามโหมด) + เมนู
const hiddenDeduct = loadColsHidden("fa_cols_ret_deduct");   // จำต่อเครื่อง (แยกตามโหมด)
const hiddenStatus = loadColsHidden("fa_cols_ret_status");
const curHidden = () => (state.mode === "status" ? hiddenStatus : hiddenDeduct);

const dash = (s: string | null | undefined): string => (s && s.trim() !== "" ? s : "—");
const badge = (cls: string, ic: string, label: string) => ic ? el("span", { class: `badge ${cls}` }, icon(ic), label) : el("span", { class: `badge ${cls}` }, label);

// ---------- นิยามคอลัมน์ ----------
interface RLCol {
  key: string;
  label: string;
  align?: "right" | "center";
  numeric?: boolean;
  thClass?: string;
  tdClass?: string;
  val: (r: ReturnListRow) => string;
  render: (r: ReturnListRow) => Node | string;
}
function sellerCell(r: ReturnListRow): Node {
  if (!r.seller_code) return document.createTextNode("—");
  const box = el("span", { class: "rlseller" }, el("span", { class: "rlcode" }, r.seller_code));
  if (r.seller_name) box.append(" ", el("span", { class: "rlsname" }, r.seller_name));
  return box;
}
// caret กางทั้งแถว (เหมือนหน้า order · toggle .rowopen ที่ <tr>)
function caretToggle(extra = ""): HTMLElement {
  const tog = el("span", { class: `itemtoggle ${extra}`.trim(), title: "ดู/ซ่อนรายละเอียดทั้งแถว" }, icon("i-caret")) as HTMLElement;
  tog.addEventListener("click", (e) => { e.stopPropagation(); const tr = (e.currentTarget as HTMLElement).closest("tr") as HTMLElement | null; if (tr) toggleRlRow(tr); });
  return tog;
}
function itemsCell(r: ReturnListRow): Node {
  const s = (r.items ?? "").trim();
  if (!s) return document.createTextNode("—");
  const lines = s.split("\n");
  const frag = document.createDocumentFragment();
  const first = el("div", { class: "iln0" }, el("span", { class: "itxt", title: lines[0] }, lines[0]));
  if (lines.length > 1) {
    first.append(caretToggle());
    const rest = el("div", { class: "itemrest" });
    for (let i = 1; i < lines.length; i++) rest.append(el("div", { class: "iln", title: lines[i] }, lines[i]));
    frag.append(first, rest);
  } else {
    frag.append(first);
  }
  return frag;
}
function nameCell(r: ReturnListRow): Node {
  const name = r.customer_name;
  if (!name) return document.createTextNode("—");
  const frag = document.createDocumentFragment();
  const tog = caretToggle("nametoggle"); tog.style.display = "none";
  frag.append(el("div", { class: "nameline" }, el("span", { class: "ntxt name", title: name }, name), tog));
  return frag;
}
function addrCell(r: ReturnListRow): Node {
  const a = r.address;
  if (!a) return document.createTextNode("—");
  const frag = document.createDocumentFragment();
  const tog = caretToggle("addrtoggle"); tog.style.display = "none";
  frag.append(el("div", { class: "addrline" },
    el("span", { class: "atxt", title: a }, a),
    el("div", { class: "addrparts" }, el("div", { class: "apart" }, a)),
    tog));
  return frag;
}

// โหมดหักยอด — เรียง+ชื่อ+ความกว้างคอลัมน์ = หน้า order
const COLS_DEDUCT: RLCol[] = [
  { key: "ordered_at", label: "วันที่", thClass: "datehead", tdClass: "datecell", val: (r) => r.ordered_at, render: (r) => dmy(r.ordered_at) },
  { key: "phone", label: "เบอร์โทร", tdClass: "mono", val: (r) => r.phone ?? "", render: (r) => dash(r.phone) },
  { key: "customer_name", label: "ชื่อลูกค้า", tdClass: "name-cell", val: (r) => r.customer_name ?? "", render: nameCell },
  { key: "team_name", label: "ทีม", tdClass: "rlteam", val: (r) => r.team_name ?? "", render: (r) => dash(r.team_name) },
  { key: "seller_code", label: "ผู้ขาย", val: (r) => r.seller_code ?? "", render: sellerCell },
  { key: "items", label: "รายการสินค้า", tdClass: "items", val: (r) => (r.items ?? "").replace(/\n/g, ", "), render: itemsCell },
  { key: "total_sales", label: "ยอดขาย", align: "right", numeric: true, tdClass: "amount num", val: (r) => String(r.total_sales), render: (r) => nf(r.total_sales) },
  { key: "carrier", label: "ขนส่ง", val: (r) => r.carrier ?? "", render: (r) => dash(r.carrier) },
  { key: "tracking_out", label: "เลขแทร็ค", tdClass: "mono", val: (r) => r.tracking_out ?? "", render: (r) => dash(r.tracking_out) },
  { key: "return_date", label: "วันตีกลับถึง", thClass: "datehead", tdClass: "datecell", val: (r) => r.return_date ?? "", render: (r) => (r.return_date ? dmy(r.return_date) : "—") },
];

// โหมดสถานะตีกลับ — เหมือนหน้า order + ทีม/ผู้ขาย (ตัด i, หมายเหตุ)
const COLS_STATUS: RLCol[] = [
  { key: "ordered_at", label: "วันที่", thClass: "datehead", tdClass: "datecell", val: (r) => r.ordered_at, render: (r) => dmy(r.ordered_at) },
  { key: "phone", label: "เบอร์โทร", tdClass: "mono", val: (r) => r.phone ?? "", render: (r) => dash(r.phone) },
  { key: "customer_name", label: "ชื่อลูกค้า", tdClass: "name-cell", val: (r) => r.customer_name ?? "", render: nameCell },
  { key: "team_name", label: "ทีม", tdClass: "rlteam", val: (r) => r.team_name ?? "", render: (r) => dash(r.team_name) },
  { key: "seller_code", label: "ผู้ขาย", val: (r) => r.seller_code ?? "", render: sellerCell },
  { key: "address", label: "ที่อยู่", tdClass: "addr-cell", val: (r) => r.address ?? "", render: addrCell },
  { key: "items", label: "รายการสินค้า", tdClass: "items", val: (r) => (r.items ?? "").replace(/\n/g, ", "), render: itemsCell },
  { key: "payment_method", label: "ชำระ", align: "right", tdClass: "tar", val: (r) => paymentMethodLabel(r.payment_method ?? ""), render: (r) => dash(paymentMethodLabel(r.payment_method ?? "")) },
  { key: "total_sales", label: "ยอดขาย", align: "right", numeric: true, tdClass: "amount num", val: (r) => String(r.total_sales), render: (r) => nf(r.total_sales) },
  { key: "carrier", label: "ขนส่ง", val: (r) => r.carrier ?? "", render: (r) => dash(r.carrier) },
  { key: "tracking_out", label: "เลขแทร็ค", tdClass: "mono", val: (r) => r.tracking_out ?? "", render: (r) => dash(r.tracking_out) },
  { key: "delivery_status", label: "สถานะจัดส่ง", align: "center", val: (r) => r.delivery_status ?? "", render: (r) => { const b = deliveryBadge(r.delivery_status ?? ""); return badge(b.cls, b.icon, r.delivery_status ?? "—"); } },
  { key: "payment_status", label: "สถานะชำระ", align: "center", val: (r) => r.payment_status ?? "", render: (r) => { const b = paymentBadge(r.payment_status ?? ""); return badge(b.cls, b.icon, paymentStatusLabel(r.payment_status ?? "—")); } },
  { key: "return_arrived", label: "ตีกลับถึงแล้ว", align: "center", val: (r) => (r.return_arrived ? "ถึงแล้ว" : "—"), render: (r) => (r.return_arrived ? badge("g", "i-return", "ถึงแล้ว") : "—") },
];
const activeCols = (): RLCol[] => (state.mode === "status" ? COLS_STATUS : COLS_DEDUCT);
const visibleCols = (): RLCol[] => activeCols().filter((c) => !curHidden().has(c.key));

// ---------- virtual scrolling (windowing) ----------
let vt: VTable | null = null;
let curVisible: ReturnListRow[] = [];   // ข้อมูลที่กรอง/เรียงแล้ว (ครบทุกแถว)
let curCols: RLCol[] = [];              // คอลัมน์ที่แสดง (snapshot ต่อการวาด)
const rlExpanded = new Set<number>();   // แถวที่กางรายละเอียด (index) — คงสภาพข้ามการเลื่อน

function buildRlRow(i: number): HTMLElement {
  const r = curVisible[i];
  const rowEl = el("tr", {}) as HTMLElement;
  rowEl.dataset.idx = String(i);
  if (rlExpanded.has(i)) rowEl.classList.add("rowopen");
  for (const col of curCols) {
    const cls = [col.tdClass ?? "", col.align === "center" ? "center" : "", col.align === "right" && !col.tdClass ? "tar" : ""].filter(Boolean).join(" ");
    const td = el("td", cls ? { class: cls } : {});
    td.append(col.render(r));
    rowEl.append(td);
  }
  return rowEl;
}
// เปิด/ปิดรายละเอียดทั้งแถว + อัปเดตความสูง virtual ให้ spacer ถูก
function toggleRlRow(tr: HTMLElement) {
  const i = Number(tr.dataset.idx);
  if (!Number.isFinite(i)) return;
  const open = tr.classList.toggle("rowopen");
  if (open) { rlExpanded.add(i); vt?.setRowHeight(i, tr.getBoundingClientRect().height); }
  else { rlExpanded.delete(i); vt?.setRowHeight(i, null); }
}
// โชว์ปุ่มขยาย ▸ เฉพาะแถวในหน้าต่างที่ข้อความล้น
function rlMeasureToggles(scope: ParentNode) {
  for (const tx of scope.querySelectorAll<HTMLElement>(".ntxt, .atxt")) {
    if (tx.scrollWidth > tx.clientWidth + 1) {
      const tog = tx.parentElement?.querySelector<HTMLElement>(".itemtoggle");
      if (tog) tog.style.display = "";
    }
  }
}

// ---------- render ----------
export function renderReturnsList(root: HTMLElement, deps: { toast: (msg: string, ok?: boolean) => void }) {
  toastFn = deps.toast;
  root.innerHTML = "";
  root.append(buildShell());
  // spotlight: การ์ดเรืองแสงตามเมาส์ (bind ครั้งเดียว · #rlCards คงอยู่)
  document.getElementById("rlCards")?.addEventListener("mousemove", (e) => {
    const card = (e.target as HTMLElement).closest(".rlkpi") as HTMLElement | null;
    if (!card) return;
    const r = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${e.clientX - r.left}px`);
    card.style.setProperty("--my", `${e.clientY - r.top}px`);
  });
  if (!outsideBound) {
    outsideBound = true;
    document.addEventListener("click", (e) => {
      const t = e.target as HTMLElement;
      if (openDrop && !t.closest?.(".fdrop") && !t.closest?.(".funnel")) closeDrop();
      const mp = document.getElementById("rlMonthPick");
      if (mp && !mp.hidden && !t.closest?.("#rlMonthPick") && !t.closest?.("#rlPCenter")) mp.hidden = true;
      const cp = document.getElementById("rlColsPop");
      if (cp && !cp.hidden && !t.closest?.("#rlColsPop") && !t.closest?.("#rlColsBtn")) cp.hidden = true;
    });
  }
  void load(true);
}

function segBtn(mode: "deduct" | "status", label: string, ic: string): HTMLElement {
  const b = el("button", { class: "rlsegbtn" + (state.mode === mode ? " on" : ""), type: "button", "data-mode": mode },
    icon(ic), el("span", {}, label)) as HTMLElement;
  b.addEventListener("click", () => {
    if (state.mode === mode) return;
    state.mode = mode;
    state.cycle = null;               // เดือนคนละแบบ → ให้ server เลือก default ปัจจุบัน
    prevOrders = 0; prevSales = 0;    // เลขวิ่งจาก 0 ตอนสลับโหมด
    filters.clear(); sort = null; closeDrop();
    document.querySelectorAll<HTMLElement>("#rlMode .rlsegbtn")
      .forEach((x) => x.classList.toggle("on", x.getAttribute("data-mode") === mode));
    void load(false);
  });
  return b;
}

// ---------- ตัวเลือกเดือน (stepper เด่น + grid) ----------
function monthShift(ym: string, delta: number): string {
  const [y, m] = ym.split("-").map(Number);
  const dt = new Date(y, m - 1 + delta, 1);
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}`;
}
function buildPeriod(): HTMLElement {
  const prev = el("button", { class: "rlpstep", title: "เดือนก่อนหน้า" }, icon("i-chev-l"));
  const next = el("button", { class: "rlpstep", title: "เดือนถัดไป" }, icon("i-chev-r"));
  const center = el("button", { class: "rlpcenter", id: "rlPCenter", type: "button" },
    el("span", { class: "rlpic" }, icon("i-cal")),
    el("span", { class: "rlpbody" },
      el("span", { class: "rlplabel", id: "rlPLabel" }, "—"),
      el("span", { class: "rlpsub", id: "rlPSub" }, "")),
    icon("i-chev"));
  const pop = el("div", { class: "mpick", id: "rlMonthPick", hidden: "" });
  prev.addEventListener("click", () => { if (state.cycle) { state.cycle = monthShift(state.cycle, -1); void load(false); } });
  next.addEventListener("click", () => { if (state.cycle) { state.cycle = monthShift(state.cycle, 1); void load(false); } });
  center.addEventListener("click", (e) => {
    e.stopPropagation();
    const p = document.getElementById("rlMonthPick"); if (!p) return;
    p.hidden = !p.hidden;
    if (!p.hidden) { if (state.cycle) pickerYear = Number(state.cycle.slice(0, 4)); buildMonthGrid(); }
  });
  return el("div", { class: "rlfield rlperiodfield", id: "rlPeriodField" }, el("span", {}, "เลือกเดือน"),
    el("div", { class: "rlperiod" }, prev, el("div", { class: "rlpwrap" }, center, pop), next));
}
function buildMonthGrid() {
  const pick = document.getElementById("rlMonthPick"); if (!pick) return;
  pick.textContent = "";
  const yr = el("div", { class: "yr" });
  const prev = el("button", { class: "ynav" }, icon("i-chev-l"));
  const next = el("button", { class: "ynav" }, icon("i-chev-r"));
  const yv = el("span", { class: "yv" }, String(pickerYear));
  prev.addEventListener("click", (e) => { e.stopPropagation(); pickerYear--; buildMonthGrid(); });
  next.addEventListener("click", (e) => { e.stopPropagation(); pickerYear++; buildMonthGrid(); });
  yr.append(prev, yv, next); pick.append(yr);
  const grid = el("div", { class: "mgrid" });
  const have = new Set((data?.cycles ?? []).map((c) => c.value));
  const selY = Number((state.cycle ?? "").slice(0, 4));
  const selM = Number((state.cycle ?? "").slice(5, 7));
  for (let m = 1; m <= 12; m++) {
    const ym = `${pickerYear}-${String(m).padStart(2, "0")}`;
    const cls = ["m"];
    if (pickerYear === selY && m === selM) cls.push("sel");
    if (have.has(ym)) cls.push("has");
    const cell = el("div", { class: cls.join(" ") }, THAI_MONTHS_SHORT[m - 1]);
    cell.addEventListener("click", (e) => { e.stopPropagation(); pick.hidden = true; state.cycle = ym; void load(false); });
    grid.append(cell);
  }
  pick.append(grid);
}
function paintPeriod() {
  const deduct = state.mode === "deduct";
  const label = document.getElementById("rlPLabel");
  const sub = document.getElementById("rlPSub");
  const center = document.getElementById("rlPCenter");
  if (label) label.textContent = (deduct ? "รอบเดือน " : "เดือน ") + (data?.cycle?.label ?? "—");
  if (sub) sub.textContent = (data?.cycle?.range ?? "") + (deduct ? "" : " · แบบหน้าออเดอร์");
  center?.classList.toggle("status", !deduct);
  // โหมดสถานะ = แบบหน้าออเดอร์: ย้ายตัวเลือกเดือนไปขวาสุด + โชว์ชื่อเดือนบน breadcrumb
  document.querySelector(".rlbar")?.classList.toggle("status", !deduct);
  const fld = document.getElementById("rlPeriodField"); if (fld) fld.querySelector("span")!.textContent = deduct ? "เลือกรอบเดือน" : "เลือกเดือน";
  const h1 = document.getElementById("rlHeadTitle");
  if (h1) h1.textContent = deduct ? "ออเดอร์ตีกลับ - หักยอด" : "ออเดอร์ตีกลับ - สถานะทั้งหมด";
  const pt = document.getElementById("pageTitle");
  if (pt) pt.textContent = deduct ? "ออเดอร์ตีกลับ" : "ออเดอร์ตีกลับ — " + (data?.cycle?.label ?? "");
  if (state.cycle) { const y = Number(state.cycle.slice(0, 4)); if (!Number.isNaN(y)) pickerYear = y; }
}

function buildShell(): HTMLElement {
  const head = el("div", { class: "rlhead" },
    el("div", { class: "rlicon" }, icon("i-clip-solid")),
    el("div", { class: "rltitles" },
      el("h2", { id: "rlHeadTitle" }, "ออเดอร์ตีกลับ"),
      el("p", {}, "สรุปออเดอร์ตีกลับ · กรองตามทีม/พนักงานตามสิทธิ์ที่ดูได้")));
  const modeWrap = el("div", { class: "rlseg", id: "rlMode" },
    segBtn("deduct", "หักยอด", "i-boxret-solid"),
    segBtn("status", "สถานะตีกลับทั้งหมด", "i-return"));
  const top = el("div", { class: "rltop" }, head, modeWrap);

  const teamSel = el("select", { class: "rlsel", id: "rlTeam" }) as HTMLSelectElement;
  const sellerSel = el("select", { class: "rlsel", id: "rlSeller" }) as HTMLSelectElement;
  const teamField = el("label", { class: "rlfield", id: "rlTeamField" }, el("span", {}, "ทีม"), teamSel);
  const sellerField = el("label", { class: "rlfield" }, el("span", {}, "พนักงาน"), sellerSel);
  teamSel.addEventListener("change", () => {
    state.teamId = teamSel.value ? Number(teamSel.value) : null;
    state.sellerCode = null; fillSellerOptions(); void load(false);
  });
  sellerSel.addEventListener("change", () => { state.sellerCode = sellerSel.value || null; void load(false); });

  const bar = el("div", { class: "rlbar" }, buildPeriod(), el("span", { class: "rlbardiv" }), teamField, sellerField);
  // การ์ดสร้างครั้งเดียว (คงที่) → อัปเดตแค่ค่าข้างในตอนข้อมูลเปลี่ยน (เลขวิ่ง/พิมพ์ดีด)
  const cards = el("div", { class: "rlcards", id: "rlCards" },
    el("div", { class: "rlkpi scope" },
      el("span", { class: "rlkpi-ic", id: "rlScopeIc" }, icon("i-grid")),
      el("div", { class: "rlkpi-body" },
        el("span", { class: "rlkpi-lbl", id: "rlScopeKind" }, "ขอบเขตที่ดู"),
        el("span", { class: "rlkpi-scope", id: "rlScopeMain" }, "—"),
        el("span", { class: "rlkpi-sub", id: "rlScopeSub" }, ""))),
    el("div", { class: "rlkpi ded" },
      el("span", { class: "rlkpi-ic" }, icon("i-boxret-solid")),
      el("div", { class: "rlkpi-body" },
        el("span", { class: "rlkpi-lbl", id: "rlCountLbl" }, "ตีกลับ"),
        el("span", { class: "rlkpi-val", id: "rlCountVal" }, "0"),
        el("span", { class: "rldelta flat", id: "rlCountDelta" }, ""))),
    el("div", { class: "rlkpi sale", id: "rlSalesCard" },
      el("span", { class: "rlkpi-ic" }, icon("i-coin")),
      el("div", { class: "rlkpi-body" },
        el("span", { class: "rlkpi-lbl" }, "ยอดขายที่ถูกหัก"),
        el("span", { class: "rlkpi-val", id: "rlSalesVal" }, "0"),
        el("span", { class: "rldelta flat", id: "rlSalesDelta" }, ""))),
    el("div", { class: "rlkpi graph", id: "rlGraphCard", hidden: "" },
      el("div", { class: "rlkpi-body wide" },
        el("span", { class: "rlkpi-lbl", id: "rlGraphLbl" }, "ตีกลับรายวัน"),
        el("div", { class: "rlkpi-chartbox", id: "rlGraphChart" }))));
  // ปุ่มเลือกคอลัมน์ (ซ่อน/โชว์)
  const colsBtn = el("button", { class: "rlcolsbtn", id: "rlColsBtn", type: "button", title: "เลือกคอลัมน์" }, icon("i-grid"), el("span", {}, "คอลัมน์")) as HTMLElement;
  const colsPop = el("div", { class: "rlcolspop", id: "rlColsPop", hidden: "" });
  colsBtn.addEventListener("click", (e) => { e.stopPropagation(); colsPop.hidden = !colsPop.hidden; if (!colsPop.hidden) buildColsMenu(); });
  const cardTop = el("div", { class: "card-top" },
    el("div", { class: "t", id: "rlCardTitle" }, "ออเดอร์ตีกลับ"),
    el("div", { class: "meta", id: "rlMeta" }, ""),
    el("div", { class: "rlcolswrap" }, colsBtn, colsPop));
  const prog = el("div", { class: "rlprogress" }, el("i", {}));
  const wrap = el("div", { class: "rlwrap", id: "rlWrap" });
  const card = el("div", { class: "card" }, cardTop, prog, wrap);
  return el("div", { class: "rlpage" }, top, bar, cards, card);
}

// ---------- team/seller dropdown ----------
function fillTeamOptions() {
  const field = document.querySelector("#rlTeamField") as HTMLElement | null;
  const sel = document.querySelector("#rlTeam") as HTMLSelectElement | null;
  if (!field || !sel) return;
  const teams = data?.teams ?? [];
  field.style.display = teams.length > 1 || !!data?.all_teams ? "" : "none";
  sel.innerHTML = "";
  sel.append(el("option", { value: "" }, "ทุกทีม"));
  for (const t of teams) sel.append(el("option", { value: String(t.id) }, t.name));
  sel.value = state.teamId ? String(state.teamId) : "";
}
function fillSellerOptions() {
  const sel = document.querySelector("#rlSeller") as HTMLSelectElement | null;
  if (!sel) return;
  const all = data?.sellers ?? [];
  const list = state.teamId == null ? all
    : all.filter((s) => (state.teamId === -1 ? s.team_id == null : s.team_id === state.teamId));
  sel.innerHTML = "";
  sel.append(el("option", { value: "" }, "ทุกคน"));
  for (const s of list) sel.append(el("option", { value: s.code }, s.name ? `${s.code} — ${s.name}` : s.code));
  sel.value = state.sellerCode && list.some((s) => s.code === state.sellerCode) ? state.sellerCode : "";
  if (sel.value === "") state.sellerCode = null;
}

// ---------- load ----------
function renderRlLoading() {
  vt?.detach(); vt = null;
  const wrap = document.querySelector("#rlWrap") as HTMLElement | null;
  if (wrap) { wrap.onscroll = null; wrap.innerHTML = ""; wrap.append(el("div", { class: "loadbox" }, el("span", { class: "loadspin" }), el("span", {}, "กำลังโหลดข้อมูล…"))); }
  document.getElementById("rlCards")?.classList.add("cards-loading");   // คงกรอบการ์ด ซ่อนแค่ตัวเลข
}
async function load(first: boolean) {
  renderRlLoading();   // ล้างของเดิมออกทันที + โชว์กำลังโหลด (ไม่ให้รู้สึกค้างระหว่างรอ fetch)
  const resp = await fetchReturnsList(state.cycle, state.mode, state.teamId, state.sellerCode);
  data = resp;
  if (!resp.authorized) { toastFn("เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่", false); return; }
  if (!resp.ok) { paintMessage(resp.error === "forbidden" ? "ไม่มีสิทธิ์ดูหน้านี้" : "เกิดข้อผิดพลาดในการโหลดข้อมูล"); return; }
  if (state.cycle == null) state.cycle = resp.cycle?.value ?? null;
  allRows = resp.rows ?? [];
  if (first) { fillTeamOptions(); fillSellerOptions(); }
  paintPeriod();
  paintCards();
  paintTable();
}

function paintMessage(msg: string) {
  const wrap = document.querySelector("#rlWrap") as HTMLElement | null;
  if (wrap) wrap.innerHTML = `<div class="rlempty">${msg}</div>`;
  const cards = document.getElementById("rlCards");
  if (cards) cards.innerHTML = "";
}

// ---------- การ์ด (scope + จำนวน + ยอด/กราฟ) ----------
function animNumEl(elm: HTMLElement, from: number, to: number, prefix = "") {
  const gen = Number(elm.dataset.animgen ?? "0") + 1;   // guard: ยกเลิก animation เก่าบน element เดียวกัน
  elm.dataset.animgen = String(gen);
  elm.textContent = prefix + nf(to);   // ตั้งค่าถูกต้องทันที (กัน rAF ไม่ยิงตอนแท็บเบื้องหลัง → เลขค้าง)
  if (from === to) return;
  const dur = 480, t0 = performance.now();
  const step = (t: number) => {
    if (elm.dataset.animgen !== String(gen)) return;   // มี animNumEl ใหม่มาแล้ว → หยุด loop เก่า
    const k = Math.min(1, (t - t0) / dur);
    const v = Math.round(from + (to - from) * (1 - Math.pow(1 - k, 3)));
    elm.textContent = prefix + nf(v);
    if (k < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}
function scopeInfo(): { kind: string; main: string; sub: string; icon: string } {
  if (state.sellerCode) {
    const s = (data?.sellers ?? []).find((x) => x.code === state.sellerCode);
    return { kind: "พนักงานที่เลือก", main: state.sellerCode + (s?.name ? " · " + s.name : ""), sub: s ? "ทีม " + ((data?.teams ?? []).find((t) => t.id === s.team_id)?.name ?? "(ไม่มีทีม)") : "", icon: "i-user" };
  }
  if (state.teamId) {
    const t = (data?.teams ?? []).find((x) => x.id === state.teamId);
    return { kind: "ทีมที่เลือก", main: t?.name ?? "ทีม", sub: "ทั้งทีม", icon: "i-grid" };
  }
  const teams = data?.teams ?? [];
  if (!data?.all_teams && teams.length === 1) return { kind: "ทีมของคุณ", main: teams[0].name, sub: "ทั้งทีม", icon: "i-grid" };
  return { kind: "ขอบเขตที่ดู", main: data?.all_teams ? "ทุกทีม" : "ทีมที่ดูได้", sub: "ตามสิทธิ์", icon: "i-grid" };
}
function updateGraph(rows: ReturnListRow[]) {
  const box = document.getElementById("rlGraphChart"); if (!box) return;
  const lbl = document.getElementById("rlGraphLbl"); if (lbl) lbl.textContent = "ตีกลับรายวัน · " + (data?.cycle?.label ?? "");
  const y = Number((state.cycle ?? "").slice(0, 4));
  const mo = Number((state.cycle ?? "").slice(5, 7));
  const days = y && mo ? new Date(y, mo, 0).getDate() : 31;
  const counts = new Array(days).fill(0);
  for (const r of rows) { const d = Number(r.ordered_at.slice(8, 10)); if (d >= 1 && d <= days) counts[d - 1]++; }
  const max = Math.max(1, ...counts);
  const chart = el("div", { class: "chart red rlchart" });
  for (let i = 0; i < days; i++) {
    if (!counts[i]) { chart.append(el("span", { class: "dbar empty" })); continue; }
    const b = el("span", { class: "dbar" }) as HTMLElement;
    b.title = `วันที่ ${i + 1} · ตีกลับ ${counts[i]} รายการ`;
    b.style.height = Math.round((counts[i] / max) * 100) + "%";   // CSS transition ทำให้แท่งโต
    chart.append(b);
  }
  box.innerHTML = ""; box.append(chart);
}
// ---------- อัปเดตค่าในที่ (คงที่ · เปลี่ยนแค่ข้อมูล) ----------
const $id = (id: string) => document.getElementById(id);
function setText(id: string, t: string) { const e = $id(id); if (e) e.textContent = t; }
function setIcon(id: string, ic: string) { const u = $id(id)?.querySelector("use"); if (u) u.setAttribute("href", "#" + ic); }
const twGen = new Map<string, number>();
function typewriter(id: string, text: string) {   // พิมพ์ดีดตอนค่าเปลี่ยน
  const elm = $id(id); if (!elm) return;
  if (elm.textContent === text) return;
  const gen = (twGen.get(id) ?? 0) + 1; twGen.set(id, gen);
  elm.textContent = ""; let i = 0;
  const step = () => { if (twGen.get(id) !== gen) return; i++; elm.textContent = text.slice(0, i); if (i < text.length) setTimeout(step, 24); };
  step();
}
function setDelta(id: string, cur: number, prev: number) {   // เดลต้าเทียบรอบก่อน
  const e = $id(id); if (!e) return;
  e.classList.remove("up", "down", "flat");
  if (prev === 0) { e.classList.add(cur > 0 ? "up" : "flat"); e.textContent = cur > 0 ? "ใหม่รอบนี้" : "— เทียบรอบก่อน"; return; }
  const pct = ((cur - prev) / prev) * 100;
  const dir = pct > 0 ? "up" : pct < 0 ? "down" : "flat";
  e.classList.add(dir);
  e.textContent = `${dir === "up" ? "▲" : dir === "down" ? "▼" : "•"} ${Math.abs(pct).toFixed(0)}% เทียบรอบก่อน`;
}
function paintCards() {
  if (!data) return;
  document.getElementById("rlCards")?.classList.remove("cards-loading");   // ข้อมูลมาแล้ว
  const deduct = state.mode === "deduct";
  const rows = computeVisible();
  const orders = rows.length;
  const sales = rows.reduce((s, r) => s + (r.total_sales || 0), 0);
  const prev = data.prev ?? { orders: 0, sales: 0 };
  const sc = scopeInfo();
  setIcon("rlScopeIc", sc.icon);
  setText("rlScopeKind", sc.kind);
  typewriter("rlScopeMain", sc.main);
  setText("rlScopeSub", sc.sub);
  setText("rlCountLbl", deduct ? "ตีกลับ (หักยอด)" : "ตีกลับทั้งหมด");
  const cv = $id("rlCountVal"); if (cv) animNumEl(cv, prevOrders, orders);
  setDelta("rlCountDelta", orders, prev.orders);
  const salesCard = $id("rlSalesCard"), graphCard = $id("rlGraphCard");
  if (salesCard) salesCard.hidden = !deduct;
  if (graphCard) graphCard.hidden = deduct;
  if (deduct) {
    const sv = $id("rlSalesVal"); if (sv) animNumEl(sv, prevSales, sales, "฿ ");
    setDelta("rlSalesDelta", sales, prev.sales);
  } else {
    updateGraph(rows);
  }
  prevOrders = orders; prevSales = sales;
}

// ---------- table + funnel filter ----------
function computeVisible(): ReturnListRow[] {
  const cols = activeCols();
  let rows = allRows;
  for (const [key, set] of filters) {
    const col = cols.find((c) => c.key === key);
    if (col) rows = rows.filter((r) => set.has(col.val(r)));
  }
  if (sort) {
    const col = cols.find((c) => c.key === sort!.key);
    if (col) {
      const dir = sort.dir === "asc" ? 1 : -1;
      rows = [...rows].sort((a, b) => col.numeric ? (Number(col.val(a)) - Number(col.val(b))) * dir : col.val(a).localeCompare(col.val(b), "th") * dir);
    }
  }
  return rows;
}
function distinctValues(col: RLCol): { value: string; count: number }[] {
  // cross-filter: นับเฉพาะแถวที่ผ่านตัวกรองคอลัมอื่น (ยกเว้นคอลัมนี้) เหมือน Google Sheet
  const cols = activeCols();
  let rows = allRows;
  for (const [key, set] of filters) {
    if (key === col.key) continue;
    const c = cols.find((x) => x.key === key);
    if (c) rows = rows.filter((r) => set.has(c.val(r)));
  }
  const m = new Map<string, number>();
  for (const r of rows) { const v = col.val(r); m.set(v, (m.get(v) ?? 0) + 1); }
  const arr = [...m.entries()].map(([value, count]) => ({ value, count }));
  arr.sort((a, b) => col.numeric ? Number(a.value) - Number(b.value) : a.value.localeCompare(b.value, "th"));
  return arr;
}
function paintTable() {
  const wrap = document.querySelector("#rlWrap") as HTMLElement | null;
  if (!wrap) return;
  vt?.detach(); vt = null;
  curCols = visibleCols();
  curVisible = computeVisible();
  rlExpanded.clear();   // กรอง/เรียง/เปลี่ยนโหมด → ยุบทุกแถว

  const table = el("table", { class: "rltable" });
  const thead = el("thead");
  const htr = el("tr");
  for (const col of curCols) htr.append(buildTh(col));
  thead.append(htr);
  const tbody = el("tbody");
  table.append(thead, tbody);
  wrap.innerHTML = "";
  wrap.append(table);
  attachTopScrollbar(wrap);   // แถบเลื่อนแนวนอนบนสุด (จับง่ายกว่าล่าง)

  const title = document.getElementById("rlCardTitle");
  if (title) title.textContent = state.mode === "status"
    ? "ออเดอร์ตีกลับ (สถานะทั้งหมด)"
    : "ออเดอร์ตีกลับ ที่หักยอด ในรอบเดือน " + (data?.cycle?.label ?? "");
  const meta = document.getElementById("rlMeta");
  if (meta) meta.textContent = `${nf(curVisible.length)} / ${nf(allRows.length)} รายการ · คลิกกรวยที่หัวคอลัมน์เพื่อกรอง`;

  const prog = document.querySelector(".rlprogress i") as HTMLElement | null;
  const updateProg = () => {
    if (!prog) return;
    const max = wrap.scrollHeight - wrap.clientHeight;
    prog.style.width = (max > 4 ? (wrap.scrollTop / max) * 100 : 0) + "%";
  };

  if (!curVisible.length) {
    tbody.append(el("tr", {}, el("td", { colspan: String(curCols.length) },
      el("div", { class: "rlempty" }, allRows.length ? "ไม่มีรายการตรงกับตัวกรอง" : "ไม่มีออเดอร์ตีกลับในเดือนนี้"))));
    wrap.onscroll = updateProg; updateProg();
    return;
  }

  // วัดความกว้างคอลัมน์จากตัวอย่าง (auto layout) → ล็อกเป็น fixed กันคอลัมน์เพี้ยนตอน virtualize
  const sampleN = Math.min(curVisible.length, 60);
  for (let i = 0; i < sampleN; i++) tbody.append(buildRlRow(i));
  const ths = [...htr.children] as HTMLElement[];
  const widths = ths.map((t) => Math.ceil(t.getBoundingClientRect().width));
  const baseH = Math.round((tbody.firstElementChild as HTMLElement)?.getBoundingClientRect().height || 50);
  tbody.textContent = "";
  table.style.tableLayout = "fixed";
  ths.forEach((t, i) => { t.style.width = widths[i] + "px"; });

  vt = makeVTable({
    wrap, tbody, colspan: curCols.length,
    count: () => curVisible.length, buildRow: buildRlRow, baseH,
    afterWindow: (tb) => rlMeasureToggles(tb),
  });
  wrap.scrollTop = 0;
  vt.render(true);
  wrap.onscroll = updateProg; updateProg();
}
function buildTh(col: RLCol): HTMLElement {
  const th = el("th", {});
  if (col.thClass) th.classList.add(...col.thClass.split(" "));
  if (col.align === "center") th.classList.add("c");
  if (col.align === "right") th.classList.add("rcol");
  const active = filters.has(col.key);
  if (active) th.classList.add("filtered");
  const hh = el("div", { class: "hh" }, col.label);
  const funnel = el("span", { class: "funnel" + (active ? " on" : "") }, icon("i-funnel"));
  funnel.addEventListener("click", (e) => { e.stopPropagation(); openFilter(th, col); });
  hh.append(funnel);
  th.append(hh);
  return th;
}
function buildColsMenu() {
  const pop = document.getElementById("rlColsPop"); if (!pop) return;
  pop.textContent = "";
  const hidden = curHidden();
  const cols = activeCols();
  pop.append(el("div", { class: "rlcolshd" }, "แสดงคอลัมน์"));
  for (const c of cols) {
    const cbx = el("span", { class: "cbx" + (hidden.has(c.key) ? " off" : "") }, icon("i-tick"));
    const row = el("div", { class: "rlcolitem" }, cbx, c.label);
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      if (hidden.has(c.key)) hidden.delete(c.key);
      else if (cols.length - hidden.size > 1) hidden.add(c.key);   // เหลืออย่างน้อย 1 คอลัมน์
      cbx.classList.toggle("off", hidden.has(c.key));
      saveColsHidden(state.mode === "status" ? "fa_cols_ret_status" : "fa_cols_ret_deduct", hidden);   // จำต่อเครื่อง
      paintTable();
    });
    pop.append(row);
  }
}
function closeDrop() { if (openDrop) { openDrop.remove(); openDrop = null; } }
function openFilter(th: HTMLElement, col: RLCol) {
  if (openDrop && openDrop.dataset.col === col.key) { closeDrop(); return; }
  closeDrop();
  const values = distinctValues(col);
  const current = filters.get(col.key);
  const temp = new Set<string>(current ? current : values.map((v) => v.value));

  const drop = el("div", { class: "fdrop" });
  drop.dataset.col = col.key;
  openDrop = drop;

  const sortSec = el("div", { class: "sec fsort" });
  const asc = el("a", { class: sort?.key === col.key && sort.dir === "asc" ? "act" : "" }, icon("i-sortaz"), "เรียง A → Z");
  const desc = el("a", { class: sort?.key === col.key && sort.dir === "desc" ? "act" : "" }, icon("i-sortza"), "เรียง Z → A");
  asc.addEventListener("click", () => { sort = { key: col.key, dir: "asc" }; closeDrop(); paintTable(); });
  desc.addEventListener("click", () => { sort = { key: col.key, dir: "desc" }; closeDrop(); paintTable(); });
  sortSec.append(asc, desc);
  drop.append(sortSec);

  const searchSec = el("div", { class: "sec" });
  const fs = el("div", { class: "fsearch" }, icon("i-search"));
  const inp = el("input", { placeholder: "ค้นหาค่า..." }) as HTMLInputElement;
  fs.append(inp);
  searchSec.append(fs);
  drop.append(searchSec);

  const listSec = el("div", { class: "sec" });
  const links = el("div", { class: "flinks" });
  const selAll = el("a", {}, "เลือกทั้งหมด");
  const clr = el("a", {}, "ล้าง");
  links.append(selAll, " · ", clr);
  const fvals = el("div", { class: "fvals" });
  listSec.append(links, fvals);
  drop.append(listSec);

  const rowEls: { cbx: HTMLElement }[] = [];
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
      rowEls.push({ cbx });
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
  apply.addEventListener("click", () => {
    if (temp.size === values.length) filters.delete(col.key);
    else filters.set(col.key, new Set(temp));
    closeDrop();
    paintTable();
    paintCards();
  });
  actions.append(cancel, apply);
  drop.append(actions);

  th.append(drop);
  if (drop.getBoundingClientRect().left < 8) { drop.style.right = "auto"; drop.style.left = "0"; }
  inp.focus();
}
