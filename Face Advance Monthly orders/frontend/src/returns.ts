// หน้า "บันทึกตีกลับ" (Stage 8) — ดีไซน์ C: โฟกัสทีละใบ + กองรายการที่กรอกแล้วด้านล่าง
// สเปกเจ้านาย: 3 ช่องกรอกด้านบน (แทร็คส่งออก · แทร็คตีกลับ · ลิงก์รูป) · Enter ไหลต่อเนื่อง
//   · ตรวจซ้ำ/ไม่พบออเดอร์ตั้งแต่ตอนกรอก (ไม่รับค่า) · เสียหาย/ไม่ครบ → เลือกสินค้าในออเดอร์ + จำนวน (ไม่เกินที่มี)
//   · ธง "ไม่หักยอด" (default ปิด · ใช้คิดค่าคอมในหน้ารายการตีกลับ) · รูปพรีวิวกดดูใหญ่ได้ · ร่างกู้คืนได้ถ้าไฟดับ
import { el, icon, nf } from "./util";
import { lookupReturnTracking, saveReturns, fetchReturnsStats, checkReturnPhoto, type ReturnOrder, type ReturnsStats } from "./api";
import { displayName } from "./session";

export const INSPECTIONS = [
  { v: "สินค้าครบ ไม่เสียหาย", cls: "g", short: "ครบ ไม่เสียหาย" },
  { v: "สินค้าเสียหาย", cls: "o", short: "เสียหาย" },
  { v: "สินค้าไม่ครบ", cls: "a", short: "ไม่ครบ" },
  { v: "สินค้าไม่ครบและเสียหาย", cls: "r", short: "ไม่ครบ+เสียหาย" },
] as const;

type DamageKind = "damaged" | "missing";   // เสียหาย (ส้ม) · ไม่ครบ/ไม่กลับมา (แดง)
interface DamageItem { name: string; qty: number; kind: DamageKind }
interface Row {
  id: number;
  tracking_out: string;
  tracking_return: string;
  photo_url: string;
  inspection_result: string;
  damage_items: DamageItem[];
  damage_detail: string;      // ข้อความอ่านง่าย สร้างจาก damage_items
  no_deduct: boolean;
  order: ReturnOrder | null;
}

let draft: Row;
let queue: Row[] = [];
let seq = 1;
const expanded = new Set<number>();   // รายการรอบันทึกที่กางดูรายละเอียดอยู่
let toastFn: (msg: string, ok?: boolean) => void = () => {};
let saveTimer: number | undefined;

const draftKey = () => `fa_returns_draft_${displayName() || "user"}`;
const newRow = (): Row => ({ id: seq++, tracking_out: "", tracking_return: "", photo_url: "", inspection_result: "", damage_items: [], damage_detail: "", no_deduct: false, order: null });
const needDetail = (r: Row) => r.inspection_result !== "" && r.inspection_result !== "สินค้าครบ ไม่เสียหาย";
/** ต้องมีสินค้าครบทุกชนิดที่ผลตรวจกำหนด (ไม่ครบ+เสียหาย = ต้องมีทั้ง "เสียหาย" และ "ขาด") */
const damageOk = (r: Row) => kindsFor(r.inspection_result).every((k) => r.damage_items.some((d) => d.kind === k));
const photoOk = (r: Row) => /^https?:\/\//i.test(r.photo_url.trim());
/** เพิ่มเข้ารายการได้ = พบออเดอร์ + กรอกแทร็คตีกลับ + ลิงก์รูป + เลือกผลตรวจ + สินค้าครบตามผลตรวจ */
const rowReady = (r: Row) => !!r.order && r.tracking_return.trim() !== "" && photoOk(r) && !!r.inspection_result && damageOk(r);
/** ข้อความสรุป แยกกลุ่มเสียหาย/ไม่ครบ เช่น "เสียหาย: A ×2 · ไม่ครบ: B ×1" */
function syncDetailText(r: Row) {
  const g = (k: DamageKind) => r.damage_items.filter((d) => d.kind === k).map((d) => `${d.name} ×${d.qty}`).join(", ");
  const d = g("damaged"), m = g("missing");
  r.damage_detail = [d && `เสียหาย: ${d}`, m && `ขาด: ${m}`].filter(Boolean).join(" · ");
}
/** ผลตรวจ → ชนิดที่อนุญาต (ไม่ครบและเสียหาย = ต้องเลือกทีละชิ้นว่าอะไรเสียหาย อะไรไม่กลับมา) */
function kindsFor(ins: string): DamageKind[] {
  if (ins === "สินค้าเสียหาย") return ["damaged"];
  if (ins === "สินค้าไม่ครบ") return ["missing"];
  if (ins === "สินค้าไม่ครบและเสียหาย") return ["damaged", "missing"];
  return [];
}

/** ลิงก์ Google Drive → URL รูปที่ฝังได้ (ไฟล์ต้องแชร์สาธารณะ) · ลิงก์รูปตรงๆ ใช้ได้เลย */
export function imageSrc(url: string, big = false): string {
  const u = url.trim();
  const m = u.match(/drive\.google\.com\/(?:file\/d\/|open\?id=|uc\?(?:export=\w+&)?id=)([\w-]{20,})/);
  if (m) return `https://drive.google.com/thumbnail?id=${m[1]}&sz=${big ? "w1600" : "w600"}`;
  return u;
}

// ---------- ร่าง (กันไฟดับ/ปิดระบบระหว่างกรอก) ----------
function saveDraft() {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    const keep = { queue, draft: draft.tracking_out.trim() ? draft : null };
    if (!keep.queue.length && !keep.draft) { localStorage.removeItem(draftKey()); return; }
    try { localStorage.setItem(draftKey(), JSON.stringify(keep)); } catch { /* เต็ม/ปิดอยู่ → ข้าม */ }
  }, 350);
}
function readDraft(): { queue: Row[]; draft: Row | null } | null {
  try {
    const raw = localStorage.getItem(draftKey());
    if (!raw) return null;
    const o = JSON.parse(raw) as { queue?: Row[]; draft?: Row | null };
    const q = Array.isArray(o.queue) ? o.queue.filter((r) => r && typeof r.tracking_out === "string") : [];
    const d = o.draft && typeof o.draft.tracking_out === "string" ? o.draft : null;
    return q.length || d ? { queue: q, draft: d } : null;
  } catch { return null; }
}
const clearDraft = () => localStorage.removeItem(draftKey());

// ---------- render ----------
export function renderRecordReturns(root: HTMLElement, deps: { toast: (msg: string, ok?: boolean) => void }) {
  toastFn = deps.toast;
  if (!draft) draft = newRow();
  root.innerHTML = "";
  root.append(buildShell());
  paint();
  // spotlight การ์ดนับ (เรืองแสงตามเมาส์) — bind ครั้งเดียว #rtCards คงอยู่
  document.querySelector("#rtCards")?.addEventListener("mousemove", (e) => {
    const ev = e as MouseEvent;
    const card = (ev.target as HTMLElement).closest(".rtkcard") as HTMLElement | null;
    if (!card) return;
    const r = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${ev.clientX - r.left}px`);
    card.style.setProperty("--my", `${ev.clientY - r.top}px`);
  });
  const d = readDraft();
  if (d && !queue.length && !draft.tracking_out.trim()) showDraftBar((d.queue?.length ?? 0) + (d.draft ? 1 : 0), d);
  focusField("out");
  void loadStats();
}

function buildShell(): HTMLElement {
  const head = el("div", { class: "rthead" },
    el("div", { class: "rticon" }, icon("i-boxret-solid")),
    el("div", { class: "rttitles" },
      el("h2", {}, "บันทึกรายการตีกลับ"),
      el("p", {}, "กรอกแทร็คส่งออก → ระบบดึงออเดอร์มาให้ตรวจ → เลือกผลตรวจ → กดเพิ่มเข้ารายการ")),
  );
  const bar = el("div", { class: "rtdraft", id: "rtDraft", hidden: "" });
  const keys = el("div", { class: "rtkeys" },
    el("span", {}, el("kbd", {}, "Enter"), " ช่องถัดไป"),
    el("span", {}, el("kbd", {}, "Enter"), " ที่ช่องลิงก์รูป = เพิ่มเข้ารายการ"),
    el("span", {}, el("kbd", {}, navigator.platform.includes("Mac") ? "⌘" : "Ctrl"), el("kbd", {}, "Enter"), " บันทึกทั้งหมด"),
  );
  // ── ส่วนที่ 1: การ์ดนับจำนวน 4 ใบ ──
  const cards = el("div", { class: "rtcards", id: "rtCards" });
  // ── ส่วนที่ 2: การ์ดรายการที่ยืนยันแล้ว (ยังไม่บันทึกลง DB) ──
  const saveBtn = el("button", { class: "rtsave", id: "rtSave", type: "button" }, icon("i-check"), el("span", { id: "rtSaveTxt" }, "บันทึก")) as HTMLButtonElement;
  saveBtn.addEventListener("click", () => { void doSave(); });
  // หัวแผง (ตรึงบน): ชื่อ + จำนวน + ปุ่มบันทึก · รายการเลื่อนดูด้านล่าง
  const qcard = el("div", { class: "rtpanel" },
    el("div", { class: "rtpanelhead" },
      el("span", { class: "rtptitle" }, "รายการที่ยืนยันแล้ว"),
      el("span", { class: "rtqbadge", id: "rtQBadge" }, "0 รายการ"),
      el("span", { class: "rtgap" }),
      saveBtn),
    el("div", { class: "rtqlist", id: "rtQList" }),
  );
  // ── ส่วนที่ 3: การ์ดกรอก/ตรวจสอบ ──
  const focusCard = el("div", { class: "rtpanel form", id: "rtFocus" });

  const wrap = el("div", { class: "rtwrap" }, head, bar,
    el("div", { class: "rtgrid" },
      el("div", { class: "rtcol left" }, cards, keys, qcard),
      el("div", { class: "rtcol right" }, focusCard)));
  wrap.addEventListener("keydown", (e) => {
    const ev = e as KeyboardEvent;
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) { ev.preventDefault(); void doSave(); }
  });
  return wrap;
}

function showDraftBar(n: number, d: { queue: Row[]; draft: Row | null }) {
  const bar = document.querySelector("#rtDraft") as HTMLElement | null;
  if (!bar) return;
  bar.hidden = false;
  bar.innerHTML = "";
  const restore = el("button", { class: "rtdbtn", type: "button" }, "กู้คืนข้อมูล") as HTMLElement;
  const drop = el("button", { class: "rtdbtn ghost", type: "button" }, "ทิ้งร่าง") as HTMLElement;
  restore.addEventListener("click", () => {
    queue = d.queue.map((r) => ({ ...r, id: seq++ }));
    if (d.draft) draft = { ...d.draft, id: seq++ };
    bar.hidden = true;
    syncForm(); paintQueue(); paintCards(); updateStats();
    toastFn(`กู้คืน ${n} รายการแล้ว`);
  });
  drop.addEventListener("click", () => { clearDraft(); bar.hidden = true; });
  bar.append(icon("i-alert"), el("span", {}, `พบข้อมูลที่กรอกค้างไว้ ${n} รายการ (ยังไม่ได้บันทึก)`), restore, drop);
}

function paint() {
  const fc = document.querySelector("#rtFocus") as HTMLElement | null;
  if (fc) { fc.innerHTML = ""; fc.append(buildFocus()); renderOrderArea(false); paintThumb(); }
  paintQueue();
  paintCards();
  updateStats();
  saveDraft();
}

// ── ส่วนที่ 1: การ์ดนับจำนวน 4 ใบ ──
let stats: ReturnsStats | null = null;
async function loadStats() {
  try {
    const s = await fetchReturnsStats();
    if (s.authorized && s.ok) { stats = s; paintCards(); }
  } catch { /* ไม่มีสถิติก็ยังใช้งานหน้าได้ */ }
}
function paintCards() {
  const box = document.querySelector("#rtCards") as HTMLElement | null;
  if (!box) return;
  const normal = queue.filter((r) => !r.no_deduct).length;
  const nod = queue.filter((r) => r.no_deduct).length;
  const card = (cls: string, ic: string, label: string, value: string, sub: string) =>
    el("div", { class: `rtkcard ${cls}` },
      el("div", { class: "khead" },
        el("span", { class: "kl" }, label),
        el("span", { class: "kic" }, icon(ic))),
      el("span", { class: "kv" }, value),
      el("span", { class: "ks" }, sub));
  box.innerHTML = "";
  box.append(
    card("cycle", "i-cal", "รอบเดือนปัจจุบัน", stats?.cycle_label ?? "—", stats?.cycle_range ?? "นับรอบ 26 – 25"),
    card("ded", "i-boxret-solid", "ตีกลับรอบนี้ (หักยอด)", stats ? String(stats.deduct ?? 0) : "—", "บันทึกในระบบแล้ว"),
    card("nod", "i-ban", "ตีกลับรอบนี้ (ไม่หักยอด)", stats ? String(stats.no_deduct ?? 0) : "—", "บันทึกในระบบแล้ว"),
    card("today", "i-clip-solid", "รอบันทึกวันนี้", String(queue.length),
      `หักยอด ${normal} · ไม่หักยอด ${nod}`),
  );
}

// ---------- การ์ดโฟกัส (ใบที่กำลังกรอก) ----------
function buildFocus(): HTMLElement {
  const box = el("div", { class: "rtfcard", id: "rtCard" });

  // 3 ช่องกรอกด้านบน · listener อ้าง draft (module) → เปลี่ยน draft ไม่ต้องสร้างฟอร์มใหม่
  const trOut = el("input", { class: "rtinp mono", placeholder: "สแกน/พิมพ์เลขแทร็คส่งออก", value: draft.tracking_out, "data-f": "out" }) as HTMLInputElement;
  const trBack = el("input", { class: "rtinp mono", placeholder: "เลขแทร็คที่ตีกลับมา", value: draft.tracking_return, "data-f": "back" }) as HTMLInputElement;
  const photo = el("input", { class: "rtinp", placeholder: "วางลิงก์รูปกล่อง (Google Drive)", value: draft.photo_url, "data-f": "photo" }) as HTMLInputElement;

  trOut.addEventListener("input", () => { draft.tracking_out = trOut.value; clearFieldErr("out"); if (draft.order) { draft.order = null; renderOrderArea(false); updateStats(); } saveDraft(); });
  trOut.addEventListener("keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") { e.preventDefault(); void doLookup(trOut); } });
  trOut.addEventListener("blur", () => { if (trOut.value.trim() && !draft.order) void doLookup(trOut); });

  trBack.addEventListener("input", () => { draft.tracking_return = trBack.value; clearFieldErr("back"); saveDraft(); });
  trBack.addEventListener("keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") { e.preventDefault(); focusField("photo"); } });

  const thumb = el("div", { class: "rtthumb", id: "rtThumb" });
  photo.addEventListener("input", () => {
    draft.photo_url = photo.value;
    clearFieldErr("photo");
    window.clearTimeout(thumbTimer);
    thumbTimer = window.setTimeout(paintThumb, 400);
    saveDraft();
  });
  photo.addEventListener("keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") { e.preventDefault(); void addToQueue(); } });

  const fld = (label: string, input: HTMLElement, status?: HTMLElement) =>
    el("div", { class: "rtfield" },
      el("div", { class: "rtflrow" }, el("span", { class: "rtflabel" }, label), ...(status ? [status] : [])),
      input);
  const status = el("span", { class: "rtfound", id: "rtFound" });

  // บน (ตรึง): 3 ช่องกรอกซ้าย + รูปกล่องขวา
  box.append(el("div", { class: "rtintop" },
    el("div", { class: "rtinputs" },
      fld("เลขแทร็คส่งออก", trOut, status),
      fld("เลขแทร็คที่ตีกลับมา", trBack),
      fld("ลิงก์รูปกล่องตีกลับ", photo)),
    thumb));

  // กลาง (เลื่อนได้) + ล่าง (ตรึง) — เนื้อหาเติมโดย renderOrderArea (อัปเดตเฉพาะส่วน ไม่สร้างใบใหม่)
  box.append(el("div", { class: "rtfscroll", id: "rtScroll" }));
  box.append(el("div", { class: "rtfactions", id: "rtActions" }));
  return box;   // เนื้อหาโซนออเดอร์/รูป เติมโดย renderOrderArea()+paintThumb() หลัง box เข้า DOM
}

// รูปกล่อง: วาดจาก draft.photo_url (query #rtThumb — เรียกหลัง box เข้า DOM แล้ว)
let thumbTimer: number | undefined;
function paintThumb() {
  const thumb = document.querySelector("#rtThumb") as HTMLElement | null;
  if (!thumb) return;
  thumb.innerHTML = "";
  const u = draft.photo_url.trim();
  if (!u) { thumb.append(el("div", { class: "rtnophoto" }, el("span", {}, "รูปกล่องตีกลับ"), el("small", {}, "วางลิงก์แล้วรูปจะขึ้นที่นี่"))); return; }
  if (!/^https?:\/\//i.test(u)) { thumb.append(el("div", { class: "rtnophoto bad" }, el("span", {}, "ลิงก์ไม่ถูกต้อง"))); return; }
  const img = el("img", { src: imageSrc(u), alt: "รูปกล่องตีกลับ", loading: "lazy" }) as HTMLImageElement;
  img.addEventListener("click", () => openLightbox(u));
  img.addEventListener("error", () => {
    thumb.innerHTML = "";
    thumb.append(el("div", { class: "rtnophoto bad" }, el("span", {}, "เปิดรูปไม่ได้"), el("small", {}, "ไฟล์ต้องแชร์สาธารณะ")));
  });
  thumb.append(img);
}

/** อัปเดตฟอร์มตาม draft ปัจจุบัน โดยไม่สร้างฟอร์มใหม่ (กันกระพริบตอนเพิ่ม/แก้/กู้ร่าง/บันทึก) */
function syncForm() {
  const g = (f: string) => document.querySelector(`#rtFocus input[data-f="${f}"]`) as HTMLInputElement | null;
  const o = g("out"), b = g("back"), p = g("photo");
  if (o) o.value = draft.tracking_out;
  if (b) b.value = draft.tracking_return;
  if (p) p.value = draft.photo_url;
  clearErrors();
  paintThumb();
  renderOrderArea(false);
}

/** เติม/อัปเดตเฉพาะโซนข้อมูลออเดอร์ + ผลตรวจ + ปุ่ม (ไม่แตะช่องกรอก/รูป = ไม่กระพริบ) */
function renderOrderArea(animate: boolean) {
  const r = draft;
  const card = document.querySelector("#rtCard");
  if (card) card.className = `rtfcard${r.order ? " ok" : ""}${rowReady(r) ? " ready" : ""}`;
  const found = document.querySelector("#rtFound");
  if (found) { found.textContent = r.order ? "พบออเดอร์" : "รอค้นหา"; found.className = `rtfound${r.order ? " on" : ""}`; }

  const scroll = document.querySelector("#rtScroll");
  if (scroll) {
    scroll.innerHTML = "";
    scroll.append(orderInfo(r.order, animate));
    if (r.order) scroll.append(el("div", { id: "rtInspect" }, inspectBlock(r)));
  }
  const actions = document.querySelector("#rtActions");
  if (actions) {
    actions.innerHTML = "";
    if (r.order) {
      const tg = el("button", { class: `rttoggle${r.no_deduct ? " on" : ""}`, type: "button" },
        el("span", { class: "knob" }), el("span", { class: "lbl" }, "ไม่หักยอด")) as HTMLElement;
      tg.addEventListener("click", () => { r.no_deduct = !r.no_deduct; tg.classList.toggle("on", r.no_deduct); saveDraft(); });
      const add = el("button", { class: "rtadd2", id: "rtAdd", type: "button" }, icon("i-plus"), "เพิ่มเข้ารายการ") as HTMLButtonElement;
      add.addEventListener("click", () => { void addToQueue(); });
      actions.append(tg, el("span", { class: "rtgap" }), add);
    }
  }
}

/** พิมพ์ดีด: ทุกหัวข้อพิมพ์พร้อมกัน (ขนาน) ความเร็วคงที่ · คอลัมน์ซ้ายเริ่มก่อน (col*stagger) */
let typeGen = 0;
function typewriter(pairs: { el: HTMLElement; text: string; col: number }[], speed = 30, stagger = 140) {
  const gen = ++typeGen;
  pairs.forEach((p) => { p.el.textContent = ""; });
  for (const p of pairs) {
    let ci = 0;
    const step = () => {
      if (gen !== typeGen) return;         // ยกเลิกถ้ามีการพิมพ์ชุดใหม่
      ci++;
      p.el.textContent = p.text.slice(0, ci);
      if (ci < p.text.length) window.setTimeout(step, speed);
    };
    window.setTimeout(() => { if (gen === typeGen) step(); }, p.col * stagger);
  }
}

/** อัปเดตเฉพาะโซนผลตรวจ (กันจอกระพริบ/scroll เด้งจากการสร้างการ์ดใหม่ทั้งใบ) */
function refreshInspect() {
  const host = document.querySelector("#rtInspect");
  if (host) { host.innerHTML = ""; host.append(inspectBlock(draft)); }
  const card = document.querySelector("#rtCard");
  if (card) card.className = `rtfcard${draft.order ? " ok" : ""}${rowReady(draft) ? " ready" : ""}`;
  paintCards(); updateStats(); saveDraft();
}

/** ดีไซน์ B: หัวข้ออยู่เสมอ · ค่าว่างเมื่อยังไม่มีออเดอร์ · พิมพ์ดีดค่าเมื่อ animate=true
 *  o=null → โครงครบ ค่าว่าง (ตามที่เจ้านายอยากได้) */
function orderInfo(o: ReturnOrder | null, animate = false): HTMLElement {
  // col = คอลัมน์ (ซ้าย=0 · กลาง=1 · ขวา=2) → พิมพ์พร้อมกันทุกหัวข้อ ซ้ายเริ่มก่อน
  const anim: { el: HTMLElement; text: string; col: number }[] = [];
  const leaf = (text: string, cls = "", col = 0) => {
    const s = el("span", { class: cls }, o ? text : "") as HTMLElement;
    if (o && text) anim.push({ el: s, text, col });
    return s;
  };
  const cust = leaf(o?.customer_name || "", "", 0);
  const amt = leaf(o ? `฿${nf(o.total_sales)}` : "", "", 2);
  const phone = leaf(o?.phone || "", "vl num", 0);
  const carrier = leaf(o?.carrier || "", "vl", 1);
  const sellerCode = leaf(o ? (o.seller_code || "—") : "", "", 2);
  const sellerName = leaf(o?.seller_name || "", "sub", 2);
  const prodList = el("div", { class: "rtoplist" });
  if (o) {
    const items = o.items_list ?? [];
    const lines = items.length ? items.map((i) => `${i.name} ×${i.qty}`) : [o.items || "—"];
    for (const t of lines) prodList.append(leaf(t, "rtoprod", 0));
  } else {
    prodList.append(el("div", { class: "rtoprod" }, ""));   // เว้นบรรทัดว่างไว้
  }

  const mf = (label: string, valEl: HTMLElement, cls = "") =>
    el("div", { class: `rtomf ${cls}` }, el("span", { class: "lb" }, label), valEl);

  const wrap = el("div", { class: "rtoinfo" },
    el("div", { class: "rtohead" },
      el("div", { class: "rtocust" }, cust),
      el("div", { class: "rtoamt" }, amt)),
    el("div", { class: "rtometa" },
      mf("เบอร์โทรลูกค้า", phone),
      mf("ขนส่ง (ส่งออก)", carrier),
      mf("พนักงานขาย", el("span", { class: "vl" }, sellerCode, sellerName), "seller")),
    el("div", { class: "rtoprods" },
      el("span", { class: "lb" }, "รายการสินค้า (ส่งออก)"), prodList),
  );
  if (animate && anim.length) typewriter(anim);
  return wrap;
}

function inspectBlock(r: Row): HTMLElement {
  const btns = el("div", { class: "rtinsbtns" });
  for (const ins of INSPECTIONS) {
    const on = r.inspection_result === ins.v;
    const c = el("button", { class: `rtinsbtn ${ins.cls}${on ? " on" : ""}`, type: "button" },
      el("span", { class: "dot" }), el("span", { class: "lb" }, ins.short)) as HTMLElement;
    c.addEventListener("click", () => {
      r.inspection_result = on ? "" : ins.v;
      if (!needDetail(r)) { r.damage_items = []; r.damage_detail = ""; }
      refreshInspect();
    });
    btns.append(c);
  }

  const wrap = el("div", { class: "rtinspect" },
    el("div", { class: "rtfield" }, el("span", { class: "rtflabel" }, "ผลการตรวจสอบ"), btns));

  if (needDetail(r)) {
    const list = r.order?.items_list ?? [];
    const items = el("div", { class: "rtdetail" });
    if (!list.length) items.append(el("span", { class: "rtmuted" }, "ไม่พบรายการสินค้าในออเดอร์"));
    const kinds = kindsFor(r.inspection_result);
    for (const it of list) {
      const picked = r.damage_items.find((d) => d.name === it.name);
      const row = el("div", { class: `rtitem${picked ? (picked.kind === "damaged" ? " dmg" : " miss") : ""}` });
      const toggle = (k: DamageKind) => {
        const i = r.damage_items.findIndex((d) => d.name === it.name);
        if (i >= 0 && r.damage_items[i].kind === k) r.damage_items.splice(i, 1);
        else if (i >= 0) r.damage_items[i].kind = k;
        else r.damage_items.push({ name: it.name, qty: 1, kind: k });
        syncDetailText(r); refreshInspect();
      };
      const pick = el("button", { class: "rtiname", type: "button" },
        el("span", { class: "tick" }, picked ? "✓" : ""), it.name,
        el("span", { class: "rtiqty" }, `มี ${it.qty}`)) as HTMLElement;
      pick.addEventListener("click", () => toggle(picked ? picked.kind : kinds[0]));
      row.append(pick);
      // เลือกทีละชิ้นว่า "เสียหาย" หรือ "ไม่ครบ" (เฉพาะกรณีผลตรวจเป็นทั้งสองอย่าง)
      if (kinds.length > 1) {
        const kb = (k: DamageKind, cls: string, label: string) => {
          const b = el("button", { class: `rtkbtn ${cls}${picked?.kind === k ? " on" : ""}`, type: "button" }, label) as HTMLElement;
          b.addEventListener("click", () => toggle(k));
          return b;
        };
        row.append(el("div", { class: "rtkind" }, kb("damaged", "d", "เสียหาย"), kb("missing", "m", "ขาด")));
      }
      if (picked) {
        const qty = el("input", { class: "rtqty", type: "number", inputmode: "numeric", min: "1", max: String(it.qty), value: String(picked.qty), "aria-label": `จำนวน ${it.name}` }) as HTMLInputElement;
        const clamp = () => {
          let n = Math.floor(Number(qty.value) || 1);
          if (n < 1) n = 1;
          if (n > it.qty) { n = it.qty; toastFn(`ออเดอร์นี้มี ${it.name} แค่ ${it.qty} ชิ้น`, false); }
          qty.value = String(n); picked.qty = n; syncDetailText(r); updateStats(); saveDraft();
        };
        qty.addEventListener("input", () => { picked.qty = Math.floor(Number(qty.value) || 1); syncDetailText(r); saveDraft(); });
        qty.addEventListener("blur", clamp);
        row.append(qty);
      }
      items.append(row);
    }
    wrap.append(el("div", { class: "rtfield" }, el("span", { class: "rtflabel" }, "ระบุสินค้าที่เสียหาย / หายไป"), items));
  }
  return wrap;
}

/** ล้าง error ทุกช่องในฟอร์ม */
function clearErrors() {
  document.querySelectorAll("#rtFocus .rterr").forEach((n) => n.remove());
  document.querySelectorAll("#rtFocus .rtinp.bad").forEach((n) => n.classList.remove("bad"));
  document.querySelector("#rtInspect .rtinsbtns")?.classList.remove("bad");
}
/** ช่อง input (out/back/photo): ขอบแดง + ข้อความแดงใต้ช่อง */
function setFieldErr(dataF: string, msg: string, shake = false) {
  const inp = document.querySelector(`#rtFocus input[data-f="${dataF}"]`) as HTMLInputElement | null;
  if (!inp) return;
  inp.classList.add("bad");
  if (shake) { inp.classList.add("shake"); window.setTimeout(() => inp.classList.remove("shake"), 420); }
  const field = inp.closest(".rtfield");
  if (field && !field.querySelector(".rterr")) field.append(el("div", { class: "rterr" }, msg));
}
/** ล้าง error ของช่องเดียว (เรียกตอนพิมพ์แก้) */
function clearFieldErr(dataF: string) {
  const inp = document.querySelector(`#rtFocus input[data-f="${dataF}"]`) as HTMLInputElement | null;
  inp?.classList.remove("bad");
  inp?.closest(".rtfield")?.querySelector(".rterr")?.remove();
}
/** error โซนผลตรวจ/สินค้า (ใน #rtInspect) */
function setInspectErr(msg: string) {
  const btns = document.querySelector("#rtInspect .rtinsbtns");
  const wrap = document.querySelector("#rtInspect .rtinspect");
  if (btns) btns.classList.add("bad");
  if (wrap && !wrap.querySelector(".rterr")) {
    const first = wrap.querySelector(".rtfield");
    (first ?? wrap).append(el("div", { class: "rterr" }, msg));
  }
}

/** ย้ายใบที่กรอกครบเข้ากองด้านล่าง แล้วเคลียร์ช่องให้กรอกใบถัดไป */
async function addToQueue() {
  clearErrors();
  // ตรวจข้อมูลไม่ครบ/ผิด → ทำช่องแดง + ข้อความแดงทุกจุดที่ต้องแก้
  if (!rowReady(draft)) {
    let n = 0;
    if (!draft.order) { setFieldErr("out", "ยังไม่ได้ค้นหาออเดอร์ที่ถูกต้อง"); n++; }
    if (draft.tracking_return.trim() === "") { setFieldErr("back", "กรอกเลขแทร็คที่ตีกลับมา"); n++; }
    if (!photoOk(draft)) { setFieldErr("photo", draft.photo_url.trim() === "" ? "ใส่ลิงก์รูปกล่องตีกลับ" : "ลิงก์รูปไม่ถูกต้อง (ต้องขึ้นต้นด้วย http)"); n++; }
    if (!draft.inspection_result) { setInspectErr("เลือกผลการตรวจสอบ"); n++; }
    else if (needDetail(draft) && !damageOk(draft)) {
      const bothNeeded = kindsFor(draft.inspection_result).length > 1;
      setInspectErr(bothNeeded ? "ต้องระบุทั้งสินค้าที่เสียหาย และสินค้าที่ขาด อย่างละ ≥1" : "เลือกสินค้าที่เสียหาย/ขาด"); n++;
    }
    toastFn(`ข้อมูลไม่ครบ — โปรดแก้ ${n} จุดที่เป็นสีแดง`, false);
    return;
  }
  // ลิงก์รูปห้ามซ้ำ — เช็คในหน้านี้ + กับที่บันทึกใน DB (ห้ามเพิ่มเด็ดขาด)
  const photo = draft.photo_url.trim();
  if (queue.some((r) => r.photo_url.trim() === photo)) {
    setFieldErr("photo", "ลิงก์รูปนี้ซ้ำกับรายการที่ยืนยันแล้วในหน้านี้", true);
    toastFn("ลิงก์รูปซ้ำ — โปรดใช้รูปอื่น", false); return;
  }
  const addBtn = document.querySelector("#rtAdd") as HTMLButtonElement | null;
  if (addBtn) addBtn.disabled = true;   // กันกดซ้ำระหว่างเช็ค
  try {
    const res = await checkReturnPhoto(photo);
    if (res.authorized && res.ok && res.exists) {
      setFieldErr("photo", "ลิงก์รูปนี้ถูกใช้บันทึกไปแล้ว", true);
      toastFn("ลิงก์รูปซ้ำ — โปรดใช้รูปอื่น", false);
      if (addBtn) addBtn.disabled = false;
      return;
    }
  } catch { /* เช็คไม่ได้ (เน็ต) → ปล่อยผ่าน แล้วให้ server กันตอนบันทึกอีกชั้น */ }
  queue.push(draft);
  draft = newRow();
  syncForm();                          // เคลียร์ฟอร์มในที่ (ไม่สร้างใหม่ = ไม่กระพริบ)
  paintQueue(); paintCards(); updateStats();
  focusField("out");
  toastFn("เพิ่มเข้ารายการแล้ว");
}

// ---------- กองรายการที่กรอกแล้ว ----------
function paintQueue() {
  const badge = document.querySelector("#rtQBadge") as HTMLElement | null;
  const list = document.querySelector("#rtQList") as HTMLElement | null;
  if (!list) return;
  if (badge) badge.textContent = `${queue.length} รายการ`;
  list.innerHTML = "";
  if (!queue.length) {
    list.append(el("div", { class: "rtqempty" },
      el("div", {}, "ยังไม่มีรายการที่ยืนยัน"),
      el("small", {}, "กรอกข้อมูลทางขวา แล้วกด “เพิ่มเข้ารายการ”")));
    return;
  }
  queue.forEach((r, i) => {
    const ins = INSPECTIONS.find((x) => x.v === r.inspection_result);
    const open = expanded.has(r.id);
    const wrap = el("div", { class: `rtqwrap${open ? " open" : ""}` });
    const item = el("div", { class: "rtqitem", "data-row": String(r.id) },
      el("span", { class: "rtqcaret" }, open ? "▾" : "▸"),
      el("span", { class: "rtqno" }, String(i + 1)),
      el("b", { class: "rtqtr" }, r.tracking_out),
      el("span", { class: "rtqcust" }, r.order?.customer_name ?? ""),
      el("span", { class: `rtchip mini ${ins?.cls ?? ""} on` }, ins?.short ?? ""),
      ...(r.damage_detail ? [el("span", { class: "rtqdmg" }, r.damage_detail)] : []),
      ...(r.no_deduct ? [el("span", { class: "rtqnd" }, "ไม่หักยอด")] : []),
      ...(r.photo_url ? [el("span", { class: "rtqph", title: "มีรูปแนบ" }, icon("i-image"))] : []),
      el("span", { class: "rtgap" }),
    );
    const back = el("button", { class: "rtqbtn", type: "button", title: "แก้ไข" }, "แก้") as HTMLElement;
    back.addEventListener("click", () => {
      if (draft.tracking_out.trim()) queue.push(draft);
      queue.splice(i, 1);
      draft = r;
      syncForm(); paintQueue(); paintCards(); updateStats(); focusField("out");   // โหลดแถวมาแก้ ไม่กระพริบ
    });
    const rm = el("button", { class: "rtqbtn del", type: "button", title: "ลบ" }, icon("i-close")) as HTMLElement;
    rm.addEventListener("click", (e) => { e.stopPropagation(); queue.splice(i, 1); paintQueue(); paintCards(); updateStats(); });   // ลบกอง ไม่แตะฟอร์ม
    back.addEventListener("click", (e) => e.stopPropagation());
    item.append(back, rm);
    // กดที่แถวเพื่อขยาย/ย่อ ดูรายละเอียด
    item.addEventListener("click", () => {
      if (expanded.has(r.id)) expanded.delete(r.id); else expanded.add(r.id);
      paintQueue();
    });
    wrap.append(item);
    if (open) wrap.append(queueDetail(r));
    list.append(wrap);
  });
}

/** แผงรายละเอียดของรายการที่รอบันทึก (กดขยาย) */
function queueDetail(r: Row): HTMLElement {
  const kids: (Node | string)[] = [];
  if (r.order) kids.push(orderInfo(r.order));
  const meta = el("div", { class: "rtqmeta" });
  meta.append(el("span", {}, el("b", {}, "แทร็คตีกลับ: "), r.tracking_return || "—"));
  if (r.damage_items.length) {
    const chip = (d: DamageItem) =>
      el("span", { class: `rtqdi ${d.kind === "damaged" ? "dmg" : "miss"}` }, `${d.kind === "damaged" ? "เสียหาย" : "ขาด"} · ${d.name} ×${d.qty}`);
    meta.append(el("span", { class: "rtqdis" }, ...r.damage_items.map(chip)));
  }
  if (r.no_deduct) meta.append(el("span", { class: "rtqnd" }, "ไม่หักยอด"));
  kids.push(meta);
  if (r.photo_url) {
    const img = el("img", { class: "rtqimg", src: imageSrc(r.photo_url), alt: "รูปกล่องตีกลับ", loading: "lazy" }) as HTMLImageElement;
    img.addEventListener("click", (e) => { e.stopPropagation(); openLightbox(r.photo_url); });
    kids.push(img);
  }
  return el("div", { class: "rtqdetail" }, ...kids);
}

function updateStats() {
  const ready = queue.length;   // บันทึก = เฉพาะรายการที่ยืนยันแล้ว (ต้องกด "เพิ่มเข้ารายการ" ก่อน)
  const btn = document.querySelector("#rtSave") as HTMLButtonElement | null;
  const txt = document.querySelector("#rtSaveTxt") as HTMLElement | null;
  if (btn) btn.disabled = ready === 0;
  if (txt) txt.textContent = ready > 0 ? `บันทึก ${ready} รายการ` : "บันทึก";
}

// ---------- ค้นหา/ตรวจแทร็ค ----------
const LOOKUP_MSG: Record<string, string> = {
  already_recorded: "แทร็คนี้บันทึกตีกลับไปแล้ว",
  order_not_found: "ไม่พบออเดอร์ที่ใช้เลขแทร็คนี้",
  empty: "ยังไม่ได้กรอกเลขแทร็ค",
  forbidden: "ไม่มีสิทธิ์บันทึกรายการตีกลับ",
};

async function doLookup(input: HTMLInputElement) {
  const tr = input.value.trim();
  if (!tr) return;
  if (queue.some((x) => x.tracking_out.trim() === tr)) { rejectValue(input, "เลขแทร็คนี้อยู่ในรายการรอบันทึกแล้ว"); return; }
  input.classList.add("loading");
  try {
    const res = await lookupReturnTracking(tr);
    input.classList.remove("loading");
    if (!res.authorized) { toastFn("เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่", false); return; }
    if (!res.ok || !res.order) { rejectValue(input, LOOKUP_MSG[res.error ?? ""] ?? "ตรวจสอบเลขแทร็คไม่สำเร็จ"); return; }
    draft.tracking_out = tr;
    draft.order = res.order;
    renderOrderArea(true);   // อัปเดตเฉพาะโซนออเดอร์ + พิมพ์ดีดค่า (ไม่กระพริบ ไม่แตะช่องกรอก/รูป)
    updateStats(); paintCards(); saveDraft();
    focusField("back");
  } catch {
    input.classList.remove("loading");
    toastFn("เชื่อมต่อไม่ได้ ลองใหม่อีกครั้ง", false);
  }
}

/** ไม่รับค่า: เคลียร์ช่อง + เตือน (ตามสเปกเจ้านาย) */
function rejectValue(input: HTMLInputElement, msg: string) {
  draft.tracking_out = "";
  draft.order = null;
  input.value = "";
  input.classList.add("shake", "bad");
  window.setTimeout(() => input.classList.remove("shake"), 420);
  window.setTimeout(() => input.classList.remove("bad"), 1600);
  input.focus();
  toastFn(msg, false);
  updateStats();
  saveDraft();
}

function focusField(which: "out" | "back" | "photo") {
  (document.querySelector(`#rtFocus input[data-f="${which}"]`) as HTMLInputElement | null)?.focus();
}

function openLightbox(url: string) {
  const ov = el("div", { class: "rtlight" });
  const img = el("img", { src: imageSrc(url, true), alt: "รูปกล่องตีกลับ" });
  ov.addEventListener("click", () => ov.remove());
  ov.append(img, el("a", { class: "rtlopen", href: url, target: "_blank", rel: "noopener" }, "เปิดต้นฉบับ ↗"));
  document.body.append(ov);
}

// ---------- บันทึก ----------
async function doSave() {
  const rows = queue;   // บันทึกเฉพาะรายการที่ยืนยันแล้ว · draft (ใบที่กำลังกรอก) ไม่นับ
  if (!rows.length) return;
  const btn = document.querySelector("#rtSave") as HTMLButtonElement | null;
  if (btn) btn.disabled = true;
  try {
    const res = await saveReturns(rows.map((r) => ({
      tracking_out: r.tracking_out.trim(),
      tracking_return: r.tracking_return.trim() || undefined,
      inspection_result: r.inspection_result,
      damage_detail: r.damage_detail.trim() || undefined,
      damage_items: r.damage_items.length ? r.damage_items : undefined,
      photo_url: r.photo_url.trim() || undefined,
      no_deduct: r.no_deduct,
    })));
    if (!res.authorized) { toastFn("เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่", false); return; }
    if (!res.ok) {
      if (res.problems?.length) {
        markProblems(rows, res.problems);
        toastFn(`บันทึกไม่ได้ — มี ${res.problems.length} รายการต้องแก้ก่อน`, false);
      } else {
        toastFn(res.error === "forbidden" ? "ไม่มีสิทธิ์บันทึก" : "บันทึกไม่สำเร็จ", false);
      }
      return;
    }
    const clash = new Set((res.conflicts ?? []).map((c) => c.tracking));
    document.querySelectorAll(".rtqitem").forEach((n) => {
      const tr = (n.querySelector(".rtqtr") as HTMLElement | null)?.textContent ?? "";
      if (!clash.has(tr)) n.classList.add("saved");
    });
    await new Promise((ok) => window.setTimeout(ok, 460));
    queue = queue.filter((r) => clash.has(r.tracking_out.trim()));   // เก็บเฉพาะที่ชนไว้ให้แก้ · draft คงเดิม
    clearDraft();
    paintQueue(); paintCards(); updateStats();   // อัปเดตเฉพาะกอง/การ์ด (ไม่แตะฟอร์ม = ไม่กระพริบ)
    void loadStats();   // การ์ดนับจำนวนอัปเดตหลังบันทึกจริง
    window.dispatchEvent(new Event("fa:returns-saved"));   // ให้หน้าออเดอร์ดึงข้อมูลใหม่ (มาร์คตีกลับ)
    if (res.conflicts?.length) {
      toastFn(`บันทึก ${res.inserted} รายการ · ${res.conflicts.length} รายการชนกับคนอื่น ส่งให้ EDITH ตรวจสอบแล้ว`, false);
    } else {
      toastFn(`บันทึก ${res.inserted} รายการเรียบร้อย`);
    }
  } catch {
    toastFn("เชื่อมต่อไม่ได้ ลองใหม่อีกครั้ง", false);
  } finally {
    updateStats();
  }
}

function markProblems(sent: Row[], problems: { row: number; tracking: string; reason: string }[]) {
  for (const p of problems) {
    const r = sent[p.row - 1];
    if (!r) continue;
    const node = document.querySelector(`.rtqitem[data-row="${r.id}"]`) as HTMLElement | null;
    if (node) {
      node.classList.add("bad");
      node.querySelector(".rtqprob")?.remove();
      node.append(el("span", { class: "rtqprob" }, p.reason));
    } else {
      toastFn(`${p.tracking}: ${p.reason}`, false);
    }
  }
}
