// หน้า EDITH (Stage 9b) — ศูนย์จัดการเคสทั้งระบบ · Adm only
// ดีไซน์: layout เดซี่ v3 (KPI + คิว time-bucket + โต๊ะตรวจ + audit filter) · พาเลตมืดเดซี่ v1
// ปัญหา 4 ชนิด: error(COD ยอดไม่ตรง) · conflict(บันทึกตีกลับชน) · recon(COD+ตีกลับ) · dedup(ลูกค้าซ้ำ)
import { el, icon, nf } from "./util";
import {
  fetchEdithIssues, fetchEdithDetail, fetchEdithLog,
  edithDeleteRecon, edithRestoreRecon, edithResolveConflict, edithMerge, edithDismissDup,
  edithResolveError, edithSetPaymentStatus,
  type EdithIssue, type EdithIssueType, type EdithCounts, type EdithLogRow,
} from "./api";
import { openUserModal, resetUserModal } from "./usermgmt";

let toastFn: (msg: string, ok?: boolean) => void = () => {};
let root: HTMLElement;
let issues: EdithIssue[] = [];
let counts: EdithCounts = { error: 0, conflict: 0, recon: 0, dedup: 0, total: 0 };
let selected: { type: EdithIssueType; ref: number } | null = null;
const qFilter = new Set<EdithIssueType>(); // ว่าง = ทุกชนิด
type Bucket = "lt2" | "2to6" | "6to12" | "gt12";
let bucketFilter: Bucket | null = null;
let searchText = "";
let logRows: EdithLogRow[] = [];
let logUsers: string[] = [];
const logFilter = { user: "", group: "" as "" | "data" | "auth" | "view", range: "1h" as "1h" | "today" | "7d" | "all", q: "" };
let pollTimer = 0;
let busy = false;

const q = <T extends HTMLElement = HTMLElement>(sel: string) => root.querySelector(sel) as T | null;

const SLA_WARN = 360;   // 6 ชม.
const SLA_CRIT = 720;   // 12 ชม.

interface TypeMeta { icon: string; label: string; desc: string; play: string; cls: EdithIssueType; }
const TYPES: Record<EdithIssueType, TypeMeta> = {
  error:    { icon: "i-alert-solid",  label: "Error / ยอด COD ไม่ตรง", desc: "ตรวจยอดรับเงินจริง",
    play: "เทียบยอดรับ COD กับยอดออเดอร์ — แก้ยอดให้ตรง หรือลบเรคคอร์ด COD เพื่อคืนสถานะ 'รอชำระ'", cls: "error" },
  conflict: { icon: "i-boxret-solid", label: "Conflict / บันทึกตีกลับชน", desc: "เลือกทั้งเวอร์ชันที่ถูก",
    play: "มีบันทึกตีกลับ 2 เวอร์ชันขัดกัน — เทียบทีละช่อง แล้วเลือกทั้งเวอร์ชันที่ถูกต้อง", cls: "conflict" },
  recon:    { icon: "i-wallet",       label: "Recon / COD + ตีกลับ", desc: "ตรวจว่ารายการใดผิด",
    play: "ออเดอร์มีทั้งรายการ COD และตีกลับพร้อมกัน — ลบรายการที่ผิด ระบบจะคืนสถานะให้อัตโนมัติ", cls: "recon" },
  dedup:    { icon: "i-user",         label: "Dedup / ลูกค้าอาจซ้ำ", desc: "ตรวจตัวตนก่อนรวมข้อมูล",
    play: "ลูกค้าอาจเป็นคนเดียวกัน — เลือกฝั่งที่เก็บไว้ อีกฝั่งจะถูกรวมเข้ามาแล้วลบทิ้ง", cls: "dedup" },
};
const TYPE_ORDER: EdithIssueType[] = ["error", "conflict", "recon", "dedup"];

// ---------- utils ----------
function ageLabel(min: number): string {
  if (min < 1) return "เมื่อครู่";
  if (min < 60) return `${min} นาที`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h} ชม.${min % 60 ? " " + (min % 60) + " น." : ""}`;
  const d = Math.floor(h / 24);
  return `${d} วัน${h % 24 ? " " + (h % 24) + " ชม." : ""}`;
}
function slaCls(min: number): string {
  return min >= SLA_CRIT ? "crit" : min >= SLA_WARN ? "warn" : "ok";
}
function bucketOf(min: number): Bucket {
  return min < 120 ? "lt2" : min < 360 ? "2to6" : min < 720 ? "6to12" : "gt12";
}
const BUCKETS: { key: Bucket; label: string }[] = [
  { key: "lt2", label: "< 2 ชม." }, { key: "2to6", label: "2–6 ชม." },
  { key: "6to12", label: "6–12 ชม." }, { key: "gt12", label: "> 12 ชม." },
];
function fmtTime(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const hh = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  if (d.toDateString() === now.toDateString()) return hh;
  return `${d.getDate()}/${d.getMonth() + 1} ${hh}`;
}
const EVENT_TH: Record<string, string> = {
  view_orders: "เปิดดูหน้าออเดอร์", login_ok: "เข้าสู่ระบบ", logout: "ออกจากระบบ",
  otp_sent: "ส่ง OTP", otp_verify_fail: "OTP ผิด", login_password_fail: "รหัสผ่านผิด",
  order_tracking_save: "แก้สถานะออเดอร์", import_orders: "นำเข้าออเดอร์", import_cod: "นำเข้า COD",
  save_returns: "บันทึกตีกลับ", edith_fix_cod: "แก้ยอด COD", edith_delete_recon: "ลบข้อมูล recon",
  edith_restore_recon: "กู้คืน recon", edith_resolve_conflict: "ตัดสิน conflict", edith_merge_customers: "รวมลูกค้าซ้ำ",
  edith_set_payment_status: "เปลี่ยนสถานะชำระ",
  admin_create_user: "สร้างบัญชีผู้ใช้", admin_update_user: "แก้ไขบัญชีผู้ใช้", admin_reset_password: "รีเซ็ตรหัสผ่าน",
};
const eventTh = (e: string) => EVENT_TH[e] ?? e;
const EVENT_GROUP: Record<string, "data" | "auth" | "view"> = {
  view_orders: "view",
  login_ok: "auth", logout: "auth", otp_sent: "auth", otp_verify_fail: "auth", login_password_fail: "auth",
  order_tracking_save: "data", import_orders: "data", import_cod: "data", save_returns: "data",
  edith_fix_cod: "data", edith_delete_recon: "data", edith_restore_recon: "data",
  edith_resolve_conflict: "data", edith_merge_customers: "data", edith_set_payment_status: "data",
  admin_create_user: "data", admin_update_user: "data", admin_reset_password: "data",
};

// number ticker (นับขึ้นจากค่าเดิม · ตั้งค่าสุดท้ายทันทีกัน background-tab)
function ticker(node: HTMLElement, to: number) {
  const from = parseInt(node.textContent || "0", 10) || 0;
  node.textContent = String(to);
  if (from === to) return;
  const gen = (parseInt(node.dataset.gen || "0", 10) + 1);
  node.dataset.gen = String(gen);
  const t0 = performance.now(); const dur = 420;
  const step = (t: number) => {
    if (node.dataset.gen !== String(gen)) return;
    const p = Math.min(1, (t - t0) / dur);
    const e = 1 - Math.pow(1 - p, 3);
    node.textContent = String(Math.round(from + (to - from) * e));
    if (p < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

// ---------- shell ----------
function buildShell(container: HTMLElement) {
  root = container;
  container.classList.add("edith-host");
  container.innerHTML = "";

  const masthead = el("div", { class: "ed-masthead" },
    el("h1", { class: "ed-h1" }, "ศูนย์จัดการเคส",
      el("span", {}, "ตรวจหลักฐาน ตัดสินใจ แล้วเดินงานต่อ")),
    el("div", { class: "ed-session" },
      el("span", { class: "ed-syncdot" }, el("i", { class: "ed-dot" }), el("span", { id: "edSync" }, "ทุกกิจกรรมของทุก user")),
      (() => {
        const b = el("button", { class: "ed-users-btn" }, icon("i-user"), "จัดการผู้ใช้") as HTMLButtonElement;
        b.addEventListener("click", () => void openUserModal(toastFn));
        return b;
      })(),
      (() => {
        const b = el("button", { class: "ed-refresh" }, icon("i-refresh"), "รีเฟรช") as HTMLButtonElement;
        b.addEventListener("click", () => { b.classList.add("spin"); void refreshAll().finally(() => setTimeout(() => b.classList.remove("spin"), 400)); });
        return b;
      })()));

  const kpis = el("nav", { class: "ed-kpis", id: "edKpis", "aria-label": "เลือกประเภทปัญหา" });

  const queue = el("section", { class: "ed-col ed-queue" },
    el("div", { class: "ed-phead" },
      el("div", { class: "ed-phead-l" }, el("h2", {}, "คิวที่ต้องจัดการ"), el("span", { class: "ed-count", id: "edQCount" }, "0")),
      el("span", { class: "ed-caps" }, "WORK QUEUE")),
    el("div", { class: "ed-qtools" },
      (() => {
        const wrap = el("label", { class: "ed-search" }, icon("i-search"),
          el("input", { id: "edQSearch", type: "search", placeholder: "ออเดอร์ · ชื่อ · เลขพัสดุ", autocomplete: "off" }),
          el("kbd", { "aria-hidden": "true" }, "/"));
        const inp = wrap.querySelector("input") as HTMLInputElement;
        let deb = 0;
        inp.addEventListener("input", () => { clearTimeout(deb); deb = window.setTimeout(() => { searchText = inp.value.trim().toLowerCase(); paintQueue(); paintAging(); }, 180); });
        return wrap;
      })(),
      el("div", { class: "ed-chips", id: "edQChips", "aria-label": "กรองประเภทคิว" }),
      el("div", { class: "ed-aging", id: "edAging", "aria-label": "กรองอายุเคส" })),
    el("div", { class: "ed-qsort" }, el("span", { id: "edQFilterLabel" }, "ทุกประเภท"), el("span", {}, "ค้างนานที่สุดก่อน ↓")),
    el("div", { class: "ed-qlist", id: "edQueue" }),
    el("div", { class: "ed-qfoot" }, el("span", {}, el("kbd", {}, "J"), el("kbd", {}, "K"), "เลื่อนคิว"), el("span", {}, el("kbd", {}, "Enter"), "เปิดเคส")));

  const work = el("main", { class: "ed-col ed-work" },
    el("div", { class: "ed-phead" },
      el("div", { class: "ed-phead-l" }, el("h2", {}, "โต๊ะตรวจเคส"), el("span", { class: "ed-worklabel", id: "edWorkLabel" }, "ภาพรวม")),
      (() => {
        const b = el("button", { class: "ed-iconbtn", id: "edOverviewBtn", title: "กลับภาพรวม", "aria-label": "กลับภาพรวม" }, icon("i-list")) as HTMLButtonElement;
        b.addEventListener("click", () => { selected = null; paintQueue(); renderOverview(); });
        return b;
      })()),
    el("div", { class: "ed-wbody", id: "edWork", tabindex: "-1" }));

  const audit = el("aside", { class: "ed-col ed-audit" },
    el("div", { class: "ed-phead" },
      el("div", { class: "ed-phead-l" }, el("h2", {}, "Audit log"), el("span", { class: "ed-count", id: "edLCount" }, "0")),
      el("span", { class: "ed-caps" }, "ทุกกิจกรรม")),
    el("div", { class: "ed-atools", id: "edLFilters" }),
    el("div", { class: "ed-alist", id: "edLog" }));

  container.append(masthead, kpis, el("div", { class: "ed-desk" }, queue, work, audit));
  renderOverview();
}

// ---------- KPI ----------
function paintKpis() {
  const box = q("#edKpis")!;
  if (!box.children.length) {
    for (const t of TYPE_ORDER) {
      const m = TYPES[t];
      box.append(el("button", { class: `ed-kpi type-${t}`, "data-type": t, "aria-pressed": "false" },
        el("span", { class: "ed-kpi-ic" }, icon(m.icon)),
        el("span", { class: "ed-kpi-copy" },
          el("b", {}, m.label), el("small", {}, m.desc)),
        el("strong", { class: "ed-kpi-n num", id: `edN-${t}` }, "0")));
    }
    box.addEventListener("click", (e) => {
      const btn = (e.target as HTMLElement).closest(".ed-kpi") as HTMLElement | null;
      if (!btn) return;
      const t = btn.dataset.type as EdithIssueType;
      if (qFilter.has(t) && qFilter.size === 1) qFilter.clear();
      else { qFilter.clear(); qFilter.add(t); }
      afterFilterChange();
    });
  }
  for (const t of TYPE_ORDER) ticker(q(`#edN-${t}`)!, counts[t]);
  syncKpiActive();
}
function syncKpiActive() {
  root.querySelectorAll(".ed-kpi").forEach((b) => {
    const t = (b as HTMLElement).dataset.type as EdithIssueType;
    b.setAttribute("aria-pressed", String(qFilter.has(t)));
  });
}
function afterFilterChange() {
  paintChips(); paintAging(); paintQueue(); syncKpiActive();
}

// ---------- queue ----------
function paintChips() {
  const box = q("#edQChips"); if (!box) return; box.innerHTML = "";
  const all = el("button", { class: `ed-chip ${qFilter.size === 0 ? "on" : ""}`, "aria-pressed": String(qFilter.size === 0) }, "ทั้งหมด");
  all.addEventListener("click", () => { qFilter.clear(); afterFilterChange(); });
  box.append(all);
  for (const t of TYPE_ORDER) {
    const c = el("button", { class: `ed-chip type-${t} ${qFilter.has(t) ? "on" : ""}`, "aria-pressed": String(qFilter.has(t)) },
      TYPES[t].cls.charAt(0).toUpperCase() + TYPES[t].cls.slice(1), el("b", {}, String(counts[t])));
    c.addEventListener("click", () => {
      if (qFilter.has(t)) qFilter.delete(t); else qFilter.add(t);
      afterFilterChange();
    });
    box.append(c);
  }
  const lbl = q("#edQFilterLabel");
  if (lbl) lbl.textContent = qFilter.size === 0 ? "ทุกประเภท" : [...qFilter].map((t) => TYPES[t].cls).join(" · ");
}
// เคสที่ผ่าน filter ชนิด + ค้นหา (ยังไม่กรอง bucket — ใช้คำนวณ aging count)
function typeSearchFiltered(): EdithIssue[] {
  let list = qFilter.size ? issues.filter((i) => qFilter.has(i.type)) : issues;
  if (searchText) list = list.filter((i) => (i.key + " " + i.summary).toLowerCase().includes(searchText));
  return list;
}
function paintAging() {
  const box = q("#edAging"); if (!box) return; box.innerHTML = "";
  const base = typeSearchFiltered();
  const cnt: Record<Bucket, number> = { lt2: 0, "2to6": 0, "6to12": 0, gt12: 0 };
  for (const i of base) cnt[bucketOf(i.age_minutes)]++;
  for (const b of BUCKETS) {
    const active = bucketFilter === b.key;
    const cell = el("button", { class: `ed-age b-${b.key} ${active ? "on" : ""}`, "data-bucket": b.key, "aria-pressed": String(active) },
      el("span", { class: "ed-age-c num" }, String(cnt[b.key])), el("span", { class: "ed-age-l" }, b.label));
    cell.addEventListener("click", () => { bucketFilter = active ? null : b.key; paintAging(); paintQueue(); });
    box.append(cell);
  }
}
function visibleIssues(): EdithIssue[] {
  let list = typeSearchFiltered();
  if (bucketFilter) list = list.filter((i) => bucketOf(i.age_minutes) === bucketFilter);
  return [...list].sort((a, b) => b.age_minutes - a.age_minutes);
}
function paintQueue() {
  const box = q("#edQueue"); if (!box) return; const ps = box.scrollTop; box.innerHTML = "";
  const list = visibleIssues();
  const qc = q("#edQCount"); if (qc) qc.textContent = String(list.length);
  if (!list.length) {
    box.append(el("div", { class: "ed-empty small" }, icon("i-check-circle"), el("p", {}, issues.length ? "ไม่มีเคสตรงเงื่อนไขนี้" : "ไม่มีปัญหาค้างในคิว 🎉")));
    return;
  }
  for (const it of list) {
    const m = TYPES[it.type];
    const sel = selected && selected.type === it.type && selected.ref === it.ref;
    const urgent = it.age_minutes >= SLA_CRIT;
    const card = el("button", {
      class: `ed-case type-${it.type} sla-${slaCls(it.age_minutes)} ${sel ? "on" : ""}`,
      "data-type": it.type, "data-ref": String(it.ref), "aria-current": String(!!sel),
    },
      el("div", { class: "ed-case-top" },
        el("span", { class: "ed-case-kind" }, icon(m.icon), TYPES[it.type].cls.charAt(0).toUpperCase() + TYPES[it.type].cls.slice(1)),
        el("span", { class: `ed-case-age ${urgent ? "urgent" : ""}` }, ageLabel(it.age_minutes))),
      el("div", { class: "ed-case-key" }, it.key || `#${it.ref}`),
      el("div", { class: "ed-case-sum" }, it.summary));
    card.addEventListener("click", () => selectIssue(it.type, it.ref));
    box.append(card);
  }
  box.scrollTop = ps;
}

// ---------- workspace: overview ----------
function renderOverview() {
  const w = q("#edWork"); if (!w) return; w.innerHTML = "";
  const wl = q("#edWorkLabel"); if (wl) wl.textContent = "ภาพรวม";
  const total = counts.total;

  if (!total) {
    w.append(el("div", { class: "ed-empty big" },
      el("span", { class: "ed-empty-ic" }, icon("i-check-circle")),
      el("h3", {}, "ระบบปกติ ไม่มีเคสค้าง"),
      el("p", {}, "เมื่อมี COD ไม่ตรง · ตีกลับชนกัน · recon ขัดแย้ง หรือลูกค้าซ้ำ เคสจะขึ้นในคิวด้านซ้ายให้ตรวจทันที"),
      playbookBlock()));
    return;
  }

  const overdue = issues.filter((i) => i.age_minutes >= SLA_CRIT).length;
  const errSum = issues.filter((i) => i.type === "error").reduce((s, i) => s + Number((i.extra as Record<string, unknown>).order_total || 0), 0);
  const oldestList = [...issues].sort((a, b) => b.age_minutes - a.age_minutes).slice(0, 4);

  const kids: Node[] = [
    el("div", { class: "ed-ov-kick" }, el("i", { class: "ed-dot" }), "ภาพรวมระบบ"),
    el("h2", { class: "ed-ov-title" }, "มี ", el("strong", {}, String(total)), " เคส ที่รอตรวจสอบ"),
    el("p", { class: "ed-ov-intro" }, "ตรวจข้อมูลต้นทาง เห็นผลลัพธ์ก่อนยืนยัน ทุกการตัดสินใจถูกบันทึกไว้ให้ตรวจย้อนกลับ"),
    el("div", { class: "ed-ov-grid" },
      el("div", { class: "ed-ov-card" }, el("small", {}, "ค้างเกิน 12 ชั่วโมง"),
        el("strong", { class: "num" }, String(overdue), el("span", { class: "ed-ov-unit" }, " เคส")),
        el("span", { class: "ed-ov-detail" }, "เรียงเคสค้างนานไว้ด้านบน")),
      el("div", { class: "ed-ov-card" }, el("small", {}, "ยอดออเดอร์ที่ติด Error"),
        el("strong", { class: "num" }, "฿" + nf(errSum)),
        el("span", { class: "ed-ov-detail" }, "ยอดขายเต็มออเดอร์ · ไม่ใช่ส่วนต่าง"))),
    el("div", { class: "ed-sec" }, el("h3", {}, "เริ่มจากเคสที่ค้างนาน"), el("small", {}, `${total} เคส`)),
  ];

  const reco = el("div", { class: "ed-reco" });
  for (const it of oldestList) {
    const m = TYPES[it.type];
    const row = el("button", { class: `ed-reco-item type-${it.type}` },
      el("span", { class: "ed-reco-ic" }, icon(m.icon)),
      el("span", { class: "ed-reco-text" }, el("strong", {}, it.key || `#${it.ref}`), el("small", {}, it.summary)),
      el("span", { class: `ed-reco-age ${it.age_minutes >= SLA_CRIT ? "urgent" : ""}` }, ageLabel(it.age_minutes)),
      el("span", { class: "ed-reco-go" }, icon("i-chev-r")));
    row.addEventListener("click", () => selectIssue(it.type, it.ref));
    reco.append(row);
  }
  kids.push(reco, playbookBlock());
  w.append(el("div", { class: "ed-ov" }, ...kids));
}
function playbookBlock(): HTMLElement {
  const box = el("div", { class: "ed-play" }, el("div", { class: "ed-play-head" }, icon("i-shield"), "แนวทางจัดการปัญหาแต่ละชนิด"));
  for (const t of TYPE_ORDER) {
    const m = TYPES[t];
    box.append(el("div", { class: `ed-play-row type-${t}` },
      el("span", { class: "ed-play-ic" }, icon(m.icon)),
      el("span", { class: "ed-play-body" }, el("b", {}, m.label), el("span", {}, m.play))));
  }
  return box;
}

async function selectIssue(type: EdithIssueType, ref: number) {
  selected = { type, ref };
  paintQueue();
  const wl = q("#edWorkLabel"); if (wl) wl.textContent = TYPES[type].cls.charAt(0).toUpperCase() + TYPES[type].cls.slice(1);
  const w = q("#edWork")!;
  w.innerHTML = "";
  w.append(el("div", { class: "ed-loading" }, el("span", { class: "ed-spin" }), "กำลังโหลด…"));
  const res = await fetchEdithDetail(type, ref);
  if (!selected || selected.type !== type || selected.ref !== ref) return; // เปลี่ยนเป้าไปแล้ว
  if (!res.ok) { w.innerHTML = ""; w.append(el("div", { class: "ed-empty" }, el("p", {}, "โหลดรายละเอียดไม่ได้"))); return; }
  w.innerHTML = "";
  if (type === "error") w.append(errorResolver(ref, res.order!));
  else if (type === "conflict") w.append(conflictResolver(ref, res.conflict!, res.order));
  else if (type === "recon") w.append(reconResolver(ref, res.order!));
  else w.append(dedupResolver(ref, res.review!));
}

function workHeader(ic: string, title: string, sub: string): HTMLElement {
  return el("div", { class: "ed-whead" },
    el("span", { class: "ed-wic" }, icon(ic)),
    el("span", {}, el("h3", {}, title), el("p", {}, sub)));
}
function kv(label: string, value: Node | string): HTMLElement {
  return el("div", { class: "ed-kv" }, el("span", { class: "ed-k" }, label), el("span", { class: "ed-v" }, value));
}
const g = (o: Record<string, unknown>, k: string) => (o[k] == null ? "" : String(o[k]));
// แถวรูปหลักฐาน (แสดงรูปถ้ามี · คลิกเปิดเต็ม)
function photoRow(url: string): HTMLElement {
  const pv = el("div", { class: "ed-kv" }, el("span", { class: "ed-k" }, "รูปหลักฐาน"));
  if (url) pv.append(el("a", { class: "ed-photo", href: url, target: "_blank", rel: "noopener" },
    el("img", { src: url, alt: "หลักฐานตีกลับ", loading: "lazy" })));
  else pv.append(el("span", { class: "ed-v ed-nophoto" }, "— ไม่มีรูป"));
  return pv;
}

// error resolver — เลือกว่าจะยึดค่าไหน (ออเดอร์/ยอดรับ) แล้วระบบปรับอีกฝั่ง + เปลี่ยนสถานะเอง
function errorResolver(orderId: number, o: Record<string, unknown>): HTMLElement {
  const total = Number(o.total_sales || 0);
  const codId = o.cod_id == null ? null : Number(o.cod_id);
  const hasRow = codId != null;                          // มีเรคคอร์ดรับเงิน COD ที่ match แทร็คไหม
  const cod = o.cod_amount == null ? null : Number(o.cod_amount); // ยอดในเรคคอร์ด (อาจ null = ยังไม่ใส่ยอด)
  const delta = Number(o.delta || 0);
  const box = el("div", { class: "ed-res type-error" });
  box.append(workHeader("i-alert-solid", "Error · COD ยอดไม่ตรง", `ออเดอร์ ${g(o, "order_no") || "#" + orderId} · ${g(o, "customer_name")}`));
  const amt = el("div", { class: "ed-amtgrid" },
    el("div", { class: "ed-amtcard" }, el("span", { class: "ed-amt-l" }, "ยอดออเดอร์"), el("span", { class: "ed-amt-v" }, "฿" + nf(total))),
    el("div", { class: "ed-amtcard" }, el("span", { class: "ed-amt-l" }, "ยอดรับ COD"), el("span", { class: "ed-amt-v" }, !hasRow ? "— ไม่มีเรคคอร์ด" : cod == null ? "฿— ยังไม่ใส่ยอด" : "฿" + nf(cod))),
    el("div", { class: "ed-amtcard delta" }, el("span", { class: "ed-amt-l" }, "ส่วนต่าง"), el("span", { class: "ed-amt-v" }, hasRow ? (delta > 0 ? "+" : "") + "฿" + nf(delta) : "—")));
  box.append(amt);
  box.append(el("div", { class: "ed-info" }, kv("แทร็คส่งออก", el("span", { class: "ed-mono" }, g(o, "tracking_no") || "— ไม่มีแทร็ค")), kv("รายการสินค้า", g(o, "items") || "—"), kv("ผู้ขาย", ((g(o, "seller_code") || "") + " " + g(o, "seller_name")).trim() || "—")));

  if (hasRow) {
    box.append(el("p", { class: "ed-note" }, "เลือกว่าจะยึดค่าไหนเป็นค่าที่ถูก — ระบบจะปรับอีกฝั่งให้ตรงกัน แล้วคิดสถานะใหม่อัตโนมัติ"));
    const useOrder = el("button", { class: "ed-choice" },
      el("span", { class: "ed-choice-l" }, "ใช้ยอดจากออเดอร์"),
      el("span", { class: "ed-choice-v" }, "฿" + nf(total)),
      el("span", { class: "ed-choice-sub" }, "แก้ยอดรับเงินให้เท่ายอดออเดอร์")) as HTMLButtonElement;
    useOrder.addEventListener("click", () => confirmAsk(
      `ยืนยันใช้ยอดจากออเดอร์ ฿${nf(total)}? ระบบจะแก้ยอดรับเงินให้ตรง`,
      () => runAction(useOrder, () => edithResolveError(orderId, "order"), "แก้ตามยอดออเดอร์แล้ว")));
    const useRecv = el("button", { class: "ed-choice recv" },
      el("span", { class: "ed-choice-l" }, "ใช้ยอดจากรายการรับเงิน"),
      el("span", { class: "ed-choice-v" }, cod == null ? "฿— ว่าง" : "฿" + nf(cod)),
      el("span", { class: "ed-choice-sub" }, cod == null ? "รายการรับเงินยังไม่ใส่ยอด — ใช้ไม่ได้" : "แก้ยอดออเดอร์ให้เท่ายอดที่รับจริง")) as HTMLButtonElement;
    if (cod == null) useRecv.disabled = true;
    else useRecv.addEventListener("click", () => confirmAsk(
      `ยืนยันใช้ยอดจากรายการรับเงิน ฿${nf(cod)}? ระบบจะแก้ยอดออเดอร์ให้ตรง`,
      () => runAction(useRecv, () => edithResolveError(orderId, "received"), "แก้ตามยอดรับเงินแล้ว")));
    box.append(el("div", { class: "ed-choices" }, useOrder, useRecv));

    const delBtn = el("button", { class: "ed-btn danger sm" }, icon("i-x"), "ลบเรคคอร์ด COD (คืน 'รอชำระ')") as HTMLButtonElement;
    delBtn.addEventListener("click", () => confirmAsk(
      "ยืนยันลบเรคคอร์ด COD? สถานะจะกลับเป็น 'รอชำระ' (เลิกทำได้ 8 วิ)",
      () => doDelete("cod", orderId, delBtn)));
    box.append(el("div", { class: "ed-actline end" }, delBtn));
  } else {
    box.append(el("div", { class: "ed-callout" }, icon("i-alert"),
      el("span", {}, "ออเดอร์นี้", el("b", {}, "ไม่มีเรคคอร์ดรับเงิน COD"), " ที่ตรงกับเลขแทร็ค (ไม่ใช่แค่ยอดว่าง — คือไม่มีรายการรับเงินเลย) — แก้ยอดอัตโนมัติไม่ได้ ให้เปลี่ยนสถานะด้วยตนเองด้านล่าง")));
  }

  // เปลี่ยนสถานะด้วยตนเอง (มีเสมอ · ทางออกเคสไม่มี COD)
  box.append(statusChanger(orderId, "เปลี่ยนสถานะชำระด้วยตนเอง"));
  return box;
}

// แผงเปลี่ยนสถานะชำระด้วยตนเอง
function statusChanger(orderId: number, title: string): HTMLElement {
  const wrap = el("div", { class: "ed-statusbox" }, el("div", { class: "ed-statusbox-h" }, icon("i-editbox"), title));
  const opts: [string, string][] = [["รอชำระ", "wait"], ["ชำระแล้ว", "paid"], ["ไม่ใช่งานขาย", "nonsale"], ["ยกเลิก", "cancel"]];
  const row = el("div", { class: "ed-statusrow" });
  for (const [st, cls] of opts) {
    const b = el("button", { class: `ed-statusbtn ${cls}` }, st) as HTMLButtonElement;
    b.addEventListener("click", () => confirmAsk(
      `เปลี่ยนสถานะชำระเป็น "${st}" ?`,
      () => runAction(b, () => edithSetPaymentStatus(orderId, st), `เปลี่ยนเป็น ${st} แล้ว`)));
    row.append(b);
  }
  wrap.append(row);
  return wrap;
}

// recon resolver
function reconResolver(orderId: number, o: Record<string, unknown>): HTMLElement {
  const codj = o.cod as Record<string, unknown> | null;
  const retj = o.ret as Record<string, unknown> | null;
  const box = el("div", { class: "ed-res type-recon" });
  box.append(workHeader("i-wallet", "Recon ขัดแย้ง", `ออเดอร์ ${g(o, "order_no") || "#" + orderId} · มีทั้ง COD และตีกลับ`));
  box.append(el("div", { class: "ed-info" },
    kv("ลูกค้า", g(o, "customer_name")),
    kv("แทร็คส่งออก", el("span", { class: "ed-mono" }, g(o, "tracking_no") || "—")),
    kv("ยอดออเดอร์", "฿" + nf(Number(o.total_sales || 0))),
    kv("รายการ", g(o, "items") || "—")));
  const dual = el("div", { class: "ed-dual" });
  const codCard = el("div", { class: "ed-vcard" },
    el("div", { class: "ed-vh cod" }, icon("i-wallet"), "รายการ COD รับเงิน"),
    kv("ยอดรับ", codj ? "฿" + nf(Number(codj.amount || 0)) : "—"),
    kv("แทร็ค (ส่งออก)", el("span", { class: "ed-mono" }, codj ? g(codj, "tracking_out") || "—" : "—")),
    kv("รับจาก", codj ? g(codj, "received_from") || "—" : "—"),
    kv("บันทึกเมื่อ", codj ? fmtTime(String(codj.recorded_at)) : "—"),
    pickDeleteBtn("cod", orderId, "ลบ COD นี้"));
  const retCard = el("div", { class: "ed-vcard" },
    el("div", { class: "ed-vh ret" }, icon("i-boxret-solid"), "รายการตีกลับถึง"),
    kv("ผลตรวจ", retj ? g(retj, "inspection_result") : "—"),
    ...(retj && g(retj, "damage_detail") ? [kv("รายละเอียดเสียหาย", g(retj, "damage_detail"))] : []),
    kv("แทร็คตีกลับ", el("span", { class: "ed-mono" }, retj ? g(retj, "tracking_return") || "—" : "—")),
    kv("แทร็คส่งออก", el("span", { class: "ed-mono" }, retj ? g(retj, "tracking_out") || "—" : "—")),
    kv("บันทึกเมื่อ", retj ? fmtTime(String(retj.recorded_at)) : "—"),
    photoRow(retj ? g(retj, "photo_url") : ""),
    pickDeleteBtn("return", orderId, "ลบตีกลับนี้"));
  dual.append(codCard, retCard);
  box.append(el("p", { class: "ed-note" }, "ตรวจเลขแทร็คให้ตรงกัน แล้วเลือกลบรายการที่ผิด — ระบบจะคืนสถานะอัตโนมัติ"), dual);
  return box;
}
function pickDeleteBtn(kind: "cod" | "return", orderId: number, label: string): HTMLElement {
  const b = el("button", { class: "ed-btn danger sm" }, icon("i-x"), label) as HTMLButtonElement;
  b.addEventListener("click", () => doDelete(kind, orderId, b));
  return b;
}

// conflict resolver — เทียบ 2 เวอร์ชันครบทุก field + รูปหลักฐาน + รายละเอียดออเดอร์
function conflictResolver(conflictId: number, c: Record<string, unknown>, o?: Record<string, unknown>): HTMLElement {
  const subs = (c.submissions as Record<string, unknown>[]) || [];
  const box = el("div", { class: "ed-res type-conflict" });
  box.append(workHeader("i-boxret-solid", "ตัดสิน Conflict บันทึกตีกลับ", `แทร็ค ${g(c, "tracking_out")} · ${subs.length} เวอร์ชันขัดกัน — เลือกชุดที่ถูกต้อง`));

  // รายละเอียดออเดอร์
  if (o) {
    box.append(el("div", { class: "ed-ctx" }, el("div", { class: "ed-ctx-h" }, icon("i-truck-solid"), "รายละเอียดออเดอร์"),
      el("div", { class: "ed-info" },
        kv("ลูกค้า", g(o, "customer_name") || "—"), kv("เบอร์", g(o, "phone") || "—"),
        kv("ยอดออเดอร์", "฿" + nf(Number(o.total_sales || 0))), kv("ขนส่ง", g(o, "carrier") || "—"),
        kv("ผู้ขาย", ((g(o, "seller_code") || "") + " " + g(o, "seller_name")).trim() || "—"),
        kv("รายการสินค้า", g(o, "items") || "—"))));
  }

  const fields: [string, string][] = [
    ["เวลา", "at"], ["แทร็คตีกลับ", "tracking_return"], ["ผลตรวจ", "inspection_result"],
    ["รายละเอียดเสียหาย", "damage_detail"], ["สินค้าที่เสียหาย", "damage_items"], ["ไม่หักยอด", "no_deduct"],
  ];
  const diff = (k: string) => subs.length === 2 && JSON.stringify(subs[0]?.[k] ?? null) !== JSON.stringify(subs[1]?.[k] ?? null);
  const fmtVal = (v: unknown, k: string): string => {
    if (k === "at" && v) return fmtTime(String(v));
    if (k === "no_deduct") return v ? "ใช่" : "ไม่";
    if (k === "damage_items") {
      const arr = Array.isArray(v) ? v as Record<string, unknown>[] : [];
      return arr.length ? arr.map((d) => `${g(d, "name")}${d.qty ? " ×" + d.qty : ""}`).join(", ") : "—";
    }
    return v == null || v === "" ? "—" : String(v);
  };
  const dual = el("div", { class: "ed-dual" });
  subs.forEach((s, idx) => {
    const card = el("div", { class: "ed-vcard conflict" },
      el("div", { class: "ed-vh" }, el("b", {}, `เวอร์ชัน ${idx === 0 ? "A" : "B"}`), el("span", { class: "ed-by" }, "โดย " + (g(s, "by") || "—"))));
    for (const [lab, k] of fields) {
      card.append(el("div", { class: `ed-kv ${diff(k) ? "diff" : ""}` },
        el("span", { class: "ed-k" }, lab, diff(k) ? el("i", { class: "ed-neq" }, "≠") : ""),
        el("span", { class: "ed-v" }, fmtVal(s[k], k))));
    }
    // รูปหลักฐาน
    const photo = g(s, "photo_url");
    const pv = el("div", { class: "ed-kv" }, el("span", { class: "ed-k" }, "รูปหลักฐาน"));
    if (photo) {
      const a = el("a", { class: "ed-photo", href: photo, target: "_blank", rel: "noopener" },
        el("img", { src: photo, alt: "หลักฐานตีกลับ", loading: "lazy" }));
      pv.append(a);
    } else pv.append(el("span", { class: "ed-v ed-nophoto" }, "— ไม่มีรูป"));
    card.append(pv);

    const pick = el("button", { class: "ed-btn primary" }, icon("i-check"), `เลือกเวอร์ชัน ${idx === 0 ? "A" : "B"}`) as HTMLButtonElement;
    pick.addEventListener("click", () => confirmAsk(
      `ยืนยันเลือกเวอร์ชัน ${idx === 0 ? "A" : "B"} (โดย ${g(s, "by") || "—"})? อีกเวอร์ชันจะถูกทิ้ง`,
      () => runAction(pick, () => edithResolveConflict(conflictId, idx), "ตัดสินแล้ว")));
    card.append(pick);
    dual.append(card);
  });
  box.append(dual);
  return box;
}

// dedup resolver — ไฮไลต์จุดที่ซ้ำ/ต่าง + รายละเอียดออเดอร์ + เลือก id ที่จะเก็บชัดเจน
function dedupResolver(reviewId: number, v: Record<string, unknown>): HTMLElement {
  const reasonTh: Record<string, string> = { name: "ชื่อ", address: "ที่อยู่", phone: "เบอร์" };
  const reason = String(v.reason || "");
  const box = el("div", { class: "ed-res type-dedup" });
  box.append(workHeader("i-user", "รวมลูกค้าซ้ำ",
    `${g(v, "brand")} · ระบบสงสัยว่าเป็นคนเดียวกัน (คล้ายกันที่ "${reasonTh[reason] || reason}" ${Number(v.score || 0).toFixed(2)})`));
  box.append(el("div", { class: "ed-callout" }, icon("i-alert"),
    el("span", {}, "เลือกฝั่งที่จะ ", el("b", {}, "เก็บไว้"), " — ระบบจะย้ายออเดอร์และเบอร์ทั้งหมดของอีกฝั่งมารวมที่ id ที่เลือก แล้วลบอีกฝั่งทิ้งถาวร")));

  const idA = Number(v.new_customer_id), idB = Number(v.candidate_customer_id);
  type Val = { v: string; hit: boolean };
  const arr = (k: string): Val[] => Array.isArray(v[k]) ? (v[k] as Val[]) : [];
  type Side = { id: number; names: Val[]; phones: Val[]; addrs: Val[]; orders: number; spent: number; last: string; first: string };
  const A: Side = { id: idA, names: arr("new_names"), phones: arr("new_phones"), addrs: arr("new_addrs"), orders: Number(v.new_orders || 0), spent: Number(v.new_spent || 0), last: g(v, "new_last"), first: g(v, "new_first") };
  const B: Side = { id: idB, names: arr("cand_names"), phones: arr("cand_phones"), addrs: arr("cand_addrs"), orders: Number(v.cand_orders || 0), spent: Number(v.cand_spent || 0), last: g(v, "cand_last"), first: g(v, "cand_first") };
  const fieldsOf = (s: Side): [string, Val[]][] => [["ชื่อ", s.names], ["เบอร์", s.phones], ["ที่อยู่", s.addrs]];

  const mk = (s: Side, other: Side, title: string) => {
    const dup = other.id;
    const nm0 = s.names[0]?.v || "—";
    const card = el("div", { class: "ed-vcard" },
      el("div", { class: "ed-vh" }, el("b", {}, title), el("span", { class: "ed-by" }, "id #" + s.id)));
    for (const [lab, vals] of fieldsOf(s)) {
      const anyHit = vals.some((x) => x.hit);
      const vlist = el("span", { class: "ed-v ed-vlist" });
      if (!vals.length) vlist.append(el("span", { class: "ed-dv" }, "—"));
      else vals.forEach((x) => vlist.append(el("span", { class: `ed-dv ${x.hit ? "hit" : ""}` }, x.v || "—")));
      card.append(el("div", { class: `ed-kv ${anyHit ? "reason" : ""}` },
        el("span", { class: "ed-k" }, lab, anyHit ? el("i", { class: "ed-reason-tag" }, "🎯 ตรงกัน") : ""),
        vlist));
    }
    card.append(el("div", { class: "ed-dstat" },
      el("span", {}, "ออเดอร์ ", el("b", {}, String(s.orders))),
      el("span", {}, "ยอดรวม ", el("b", {}, "฿" + nf(s.spent))),
      el("span", {}, "ลูกค้าใหม่เมื่อ ", el("b", {}, s.first ? fmtTime(s.first) : "—")),
      el("span", {}, "ล่าสุด ", el("b", {}, s.last ? fmtTime(s.last) : "—"))));
    const keep = el("button", { class: "ed-btn primary" }, icon("i-check"), `เก็บ id #${s.id} นี้ไว้`) as HTMLButtonElement;
    keep.addEventListener("click", () => confirmAsk(
      `รวมลูกค้า: เก็บ id #${s.id} (${nm0}) · ย้ายออเดอร์/เบอร์ของ id #${dup} มารวม แล้วลบ #${dup} ทิ้งถาวร?`,
      () => runAction(keep, () => edithMerge(s.id, dup), `รวมมาที่ #${s.id} แล้ว`)));
    card.append(keep);
    return card;
  };
  box.append(el("div", { class: "ed-dual" }, mk(A, B, "รายการใหม่"), mk(B, A, "ที่อาจซ้ำ")));
  // ไม่ใช่คนเดียวกัน → ตั้ง review = rejected (นำออกจากคิว · ไม่แจ้งซ้ำอีก · ไม่รวมข้อมูล)
  const dismiss = el("button", { class: "ed-btn ed-dismiss" }, icon("i-x"), "ไม่ใช่คนเดียวกัน (ไม่รวม)") as HTMLButtonElement;
  dismiss.addEventListener("click", () => confirmAsk(
    `ยืนยันว่า id #${idA} กับ #${idB} เป็นคนละคน? — จะนำออกจากคิว ไม่รวมข้อมูล และไม่แจ้งซ้ำคู่นี้อีก`,
    () => runAction(dismiss, () => edithDismissDup(idA, idB), "ทำเครื่องหมาย 'ไม่ใช่คนเดียวกัน' แล้ว")));
  box.append(el("div", { class: "ed-dismiss-row" }, dismiss));
  return box;
}

// ---------- actions ----------
async function runAction(btn: HTMLButtonElement, fn: () => Promise<{ ok?: boolean; error?: string }>, okMsg: string) {
  if (busy) return; busy = true;
  btn.classList.add("loading"); btn.disabled = true;
  try {
    const r = await fn();
    if (r.ok) { toastFn(okMsg, true); selected = null; await refreshAll(); renderOverview(); }
    else { toastFn("ทำไม่สำเร็จ: " + (r.error || "?"), false); btn.classList.remove("loading"); btn.disabled = false; }
  } catch { toastFn("เชื่อมต่อไม่ได้", false); btn.classList.remove("loading"); btn.disabled = false; }
  finally { busy = false; }
}
async function doDelete(kind: "cod" | "return", orderId: number, btn: HTMLButtonElement) {
  if (busy) return; busy = true;
  btn.classList.add("loading"); btn.disabled = true;
  try {
    const r = await edithDeleteRecon(kind, orderId);
    if (r.ok) {
      selected = null; await refreshAll(); renderOverview();
      undoToast(`ลบข้อมูล ${kind === "cod" ? "COD" : "ตีกลับ"} แล้ว`, kind, r.deleted || {});
    } else { toastFn("ลบไม่สำเร็จ: " + (r.error || "?"), false); btn.classList.remove("loading"); btn.disabled = false; }
  } catch { toastFn("เชื่อมต่อไม่ได้", false); btn.classList.remove("loading"); btn.disabled = false; }
  finally { busy = false; }
}
// undo toast นับถอยหลัง (8 วิ)
function undoToast(msg: string, kind: "cod" | "return", payload: Record<string, unknown>) {
  q(".ed-undo")?.remove();
  const bar = el("div", { class: "ed-undo" },
    icon("i-x"), el("span", {}, msg),
    el("button", { class: "ed-undo-btn" }, icon("i-refresh"), el("span", {}, "เลิกทำ "),
      el("b", { class: "ed-undo-c" }, "8")));
  root.append(bar);
  let left = 8;
  const cd = window.setInterval(() => { left -= 1; const c = bar.querySelector(".ed-undo-c"); if (c) c.textContent = String(left); if (left <= 0) close(); }, 1000);
  const close = () => { clearInterval(cd); bar.classList.add("out"); setTimeout(() => bar.remove(), 250); };
  bar.querySelector(".ed-undo-btn")!.addEventListener("click", async () => {
    clearInterval(cd); bar.remove();
    const r = await edithRestoreRecon(kind, payload);
    if (r.ok) { toastFn("กู้คืนแล้ว", true); await refreshAll(); } else toastFn("กู้คืนไม่ได้: " + (r.error || "?"), false);
  });
  setTimeout(() => { if (bar.isConnected) close(); }, 8200);
}

// confirm dialog (modal กลางจอ · แทนการกด 2 ครั้ง)
function confirmAsk(message: string, onConfirm: () => void) {
  root.querySelector(".ed-modal")?.remove();
  const ok = el("button", { class: "ed-btn primary" }, icon("i-check"), "ยืนยัน") as HTMLButtonElement;
  const cancel = el("button", { class: "ed-btn" }, "ยกเลิก") as HTMLButtonElement;
  const overlay = el("div", { class: "ed-modal" },
    el("div", { class: "ed-modal-card" },
      el("div", { class: "ed-modal-msg" }, message),
      el("div", { class: "ed-modal-actions" }, cancel, ok)));
  const close = () => overlay.remove();
  cancel.addEventListener("click", close);
  overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
  const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") { close(); document.removeEventListener("keydown", onKey); } };
  document.addEventListener("keydown", onKey);
  ok.addEventListener("click", () => { document.removeEventListener("keydown", onKey); close(); onConfirm(); });
  root.append(overlay);
  ok.focus();
}

// ---------- log ----------
function paintLogFilters() {
  const box = q("#edLFilters"); if (!box) return; box.innerHTML = "";
  const groups: [string, string][] = [["", "ทั้งหมด"], ["data", "ข้อมูล"], ["auth", "การเข้าใช้"], ["view", "ดูหน้า"]];
  const chips = el("div", { class: "ed-chips sm" });
  for (const [gk, lab] of groups) {
    const c = el("button", { class: `ed-chip sm ${logFilter.group === gk ? "on" : ""}`, "aria-pressed": String(logFilter.group === gk) }, lab);
    c.addEventListener("click", () => { logFilter.group = gk as typeof logFilter.group; void loadLog(); });
    chips.append(c);
  }
  const search = el("label", { class: "ed-search" }, icon("i-search"),
    el("input", { type: "search", placeholder: "ค้นหากิจกรรม / ออเดอร์", value: logFilter.q, autocomplete: "off" }));
  const sinp = search.querySelector("input") as HTMLInputElement;
  let deb = 0;
  sinp.addEventListener("input", () => { clearTimeout(deb); deb = window.setTimeout(() => { logFilter.q = sinp.value.trim(); void loadLog(); }, 300); });

  const usel = el("select", { class: "ed-sel", "aria-label": "ผู้ทำกิจกรรม" }, el("option", { value: "" }, "ทุกคน")) as HTMLSelectElement;
  for (const u of logUsers) usel.append(el("option", { value: u }, u));
  usel.value = logFilter.user;
  usel.addEventListener("change", () => { logFilter.user = usel.value; void loadLog(); });

  const ranges: [string, string][] = [["1h", "1 ชม. ล่าสุด"], ["today", "วันนี้"], ["7d", "7 วัน"], ["all", "ทั้งหมด"]];
  const rsel = el("select", { class: "ed-sel", "aria-label": "ช่วงเวลา" }) as HTMLSelectElement;
  for (const [rk, lab] of ranges) rsel.append(el("option", { value: rk }, lab));
  rsel.value = logFilter.range;
  rsel.addEventListener("change", () => { logFilter.range = rsel.value as typeof logFilter.range; void loadLog(); });

  box.append(chips, search, el("div", { class: "ed-arow" }, usel, rsel));
}
function eventsForGroup(): string[] | null {
  if (!logFilter.group) return null;
  return Object.keys(EVENT_GROUP).filter((e) => EVENT_GROUP[e] === logFilter.group);
}
function paintLog() {
  const box = q("#edLog"); if (!box) return; const ps = box.scrollTop; box.innerHTML = "";
  if (!logRows.length) { box.append(el("div", { class: "ed-empty small" }, el("p", {}, "ไม่มีบันทึกในช่วงนี้"))); return; }
  for (const r of logRows) {
    const grp = EVENT_GROUP[r.event] || "data";
    box.append(el("div", { class: `ed-log grp-${grp}` },
      el("span", { class: "ed-log-dot" }),
      el("div", { class: "ed-log-main" },
        el("div", { class: "ed-log-meta" }, el("b", {}, r.username || "—"), el("time", {}, fmtTime(r.at))),
        el("div", { class: "ed-log-act" }, eventTh(r.event)),
        r.detail ? el("div", { class: "ed-log-det" }, detailSummary(r.detail)) : "")));
  }
  box.scrollTop = ps;
}
function detailSummary(d: Record<string, unknown>): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(d)) {
    if (v == null || typeof v === "object") continue;
    parts.push(`${k}=${v}`);
    if (parts.length >= 3) break;
  }
  return parts.join(" · ");
}

// ---------- data ----------
async function loadIssues() {
  const res = await fetchEdithIssues();
  if (!res.ok) { if (res.authorized === false) toastFn("session หมดอายุ", false); return; }
  issues = res.issues || [];
  counts = res.counts || counts;
  paintKpis(); paintChips(); paintAging(); paintQueue();
}
function rangeFrom(): string | null {
  const now = Date.now();
  if (logFilter.range === "1h") return new Date(now - 3600e3).toISOString();
  if (logFilter.range === "today") { const d = new Date(); d.setHours(0, 0, 0, 0); return d.toISOString(); }
  if (logFilter.range === "7d") return new Date(now - 7 * 864e5).toISOString();
  return null; // all
}
async function loadLog() {
  const filter: Record<string, unknown> = { limit: 120 };
  if (logFilter.user) filter.user = logFilter.user;
  if (logFilter.q) filter.q = logFilter.q;
  const from = rangeFrom();
  if (from) filter.from = from;
  const evs = eventsForGroup();
  if (evs) filter.events = evs;
  const res = await fetchEdithLog(filter);
  if (!res.ok) return;
  logRows = res.rows || [];
  if (res.users) logUsers = res.users;
  const lc = q("#edLCount"); if (lc) lc.textContent = String(res.total ?? logRows.length);
  paintLogFilters(); paintLog();
}
async function refreshAll() { await Promise.all([loadIssues(), loadLog()]); if (!selected) renderOverview(); }

// ---------- entry ----------
export function renderEdith(container: HTMLElement, opts: { toast: (m: string, ok?: boolean) => void }) {
  toastFn = opts.toast;
  // reset ทุกครั้งที่เข้าใหม่
  qFilter.clear(); bucketFilter = null; searchText = ""; selected = null;
  logFilter.user = ""; logFilter.group = ""; logFilter.range = "1h"; logFilter.q = "";
  resetUserModal();
  buildShell(container);
  paintChips(); paintAging();
  void refreshAll();
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = window.setInterval(() => {
    // หยุด poll เมื่อออกจากหน้า EDITH (renderPage ถอด class edith-host ออก)
    if (root.isConnected && root.classList.contains("edith-host") && root.querySelector("#edKpis")) void refreshAll();
    else { clearInterval(pollTimer); pollTimer = 0; }
  }, 45000);
}
