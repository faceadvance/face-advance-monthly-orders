// จัดการผู้ใช้ (User Management) — พอร์ตจาก mock "fable v2" (ธีมหน้าออเดอร์ MO)
// modal เกือบเต็มจอ: side filter | list | drawer (create/edit/reveal) · wire API จริง
// เปิดจากปุ่มใน EDITH masthead · ซ่อน dock ระหว่างเปิด (body.umopen)
import {
  fetchAdminUsers, adminCreateUser, adminUpdateUser, adminResetPassword,
  type AdminUser, type AdminTeam,
} from "./api";

// ───────── shape ภายใน (มิเรอร์ mock user + เก็บ id จริง) ─────────
interface UUser {
  id: string; name: string; username: string; role: string;
  allTeams: boolean; teams: string[]; active: boolean;
  hours: number; idle: number; line: string | null;
  lastSeen: number | null; created: number | null;
}
function toUUser(a: AdminUser): UUser {
  return {
    id: a.id, name: a.display_name ?? "", username: a.username, role: a.role,
    allTeams: a.all_teams, teams: a.teams.slice(), active: a.is_active,
    hours: a.session_hours, idle: a.idle_minutes, line: a.line_user_id,
    lastSeen: a.last_seen_at ? Date.parse(a.last_seen_at) : null,
    created: a.created_at ? Date.parse(a.created_at) : null,
  };
}

// ───────── role meta ─────────
interface RoleMeta { label: string; desc: string; cls: string; allTeams: boolean; color: string; }
const ROLES: Record<string, RoleMeta> = {
  Adm:   { label: "ผู้ดูแลระบบ", desc: "จัดการทั้งระบบ · ทุกหน้า · จัดการผู้ใช้", cls: "Adm", allTeams: true,  color: "var(--r-adm)" },
  OM:    { label: "ผู้จัดการออเดอร์", desc: "ออเดอร์ + ค้นหา", cls: "OM", allTeams: true, color: "var(--r-om)" },
  Vm:    { label: "ผู้จัดการ", desc: "ดูอย่างเดียว", cls: "Vm", allTeams: true, color: "var(--r-vm)" },
  "RT+": { label: "ทีมตีกลับ (บันทึกได้)", desc: "บันทึกงานตีกลับของทีม", cls: "RTp", allTeams: false, color: "var(--r-rtp)" },
  RTs:   { label: "ทีมตีกลับ (ดูอย่างเดียว)", desc: "ดูเฉพาะทีมของตัวเอง", cls: "RTs", allTeams: false, color: "var(--r-rts)" },
};
const ROLE_ORDER = ["Adm", "OM", "Vm", "RT+", "RTs"];

// ───────── state ─────────
let toastFn: (msg: string, ok?: boolean) => void = () => {};
let overlay: HTMLElement | null = null;
let users: UUser[] = [];
let teams: AdminTeam[] = [];
let TEAMS: string[] = [];
let ME = "";

const F = { q: "", status: "all", roles: new Set<string>(), team: "", lineOnly: false };
let sort = "role";
let selectedId: string | null = null;
let drawerMode: "create" | "edit" | "reveal" | null = null;
let dirty = false;
let busy = false;

// ───────── helpers ─────────
const qs = <T extends HTMLElement = HTMLElement>(s: string) => overlay?.querySelector(s) as T | null;
const now = () => Date.now();
const m = 60e3, h = 3600e3, dms = 86400e3;
function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}
const nameOf = (u: { name: string; username: string }) => u.name.trim() || u.username;
function initials(n: string): string {
  const t = (n || "").trim(); if (!t) return "?";
  return /^[A-Za-z]/.test(t) ? t.slice(0, 2).toUpperCase() : t.slice(0, 1);
}
function rel(t: number | null): string {
  if (!t) return "ยังไม่เคยเข้าใช้";
  const s = (now() - t) / 1e3;
  if (s < 60) return "เมื่อสักครู่";
  if (s < 3600) return `${Math.floor(s / 60)} นาทีที่แล้ว`;
  if (s < 86400) return `${Math.floor(s / 3600)} ชม.ที่แล้ว`;
  return `${Math.floor(s / 86400)} วันที่แล้ว`;
}
const teamLabel = (u: UUser) => u.allTeams ? "ทุกทีม" : u.teams.join(", ");
const hasQ = (u: UUser, q: string) => [u.name, u.username, teamLabel(u), ROLES[u.role]?.label || "", u.role].join(" ").toLowerCase().includes(q);
const teamIds = (names: string[]): number[] => names.map((n) => teams.find((t) => t.name === n)?.id).filter((x): x is number => x != null);

function strength(p: string): number {
  if (!p) return 0; let s = 0;
  if (p.length >= 8) s++; if (p.length >= 12) s++;
  if (/[a-z]/.test(p) && /[A-Z]/.test(p)) s++;
  if (/\d/.test(p) && /[^A-Za-z0-9]/.test(p)) s++;
  return Math.min(4, s);
}
const STRENGTH_LABEL = ["", "อ่อน", "พอใช้", "ดี", "แข็งแรงมาก"];
function genPassword(len = 12): string {
  const sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789", "!@#$%&*?"];
  const all = sets.join("");
  const rnd = (n: number) => { const a = new Uint32Array(1); crypto.getRandomValues(a); return a[0] % n; };
  const out = sets.map((s) => s[rnd(s.length)]);
  while (out.length < len) out.push(all[rnd(all.length)]);
  for (let i = out.length - 1; i > 0; i--) { const j = rnd(i + 1); [out[i], out[j]] = [out[j], out[i]]; }
  return out.join("");
}
function umErr(code?: string): string {
  const map: Record<string, string> = {
    username_required: "กรุณาใส่ username", username_taken: "username นี้มีคนใช้แล้ว", bad_role: "บทบาทไม่ถูกต้อง",
    last_admin: "ปลด/ปิด Adm คนสุดท้ายไม่ได้", cannot_disable_self: "ปิดใช้งานบัญชีตัวเองไม่ได้",
    password_too_short: "รหัสผ่านอย่างน้อย 6 ตัว", forbidden: "ไม่มีสิทธิ์", not_found: "ไม่พบบัญชี",
  };
  return map[code || ""] || ("ทำไม่สำเร็จ: " + (code || "?"));
}
async function copyText(t: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(t); return true; }
  catch { try { const ta = document.createElement("textarea"); ta.value = t; ta.style.position = "fixed"; ta.style.opacity = "0"; document.body.appendChild(ta); ta.select(); const ok = document.execCommand("copy"); ta.remove(); return ok; } catch { return false; } }
}
// map toast (mock ok/err/warn → app toast boolean)
function toast(msg: string, type: "ok" | "err" | "warn" = "ok") { toastFn(msg, type !== "err"); }

// ───────── ไอคอน (inline SVG · จาก mock) ─────────
const I = {
  line: `<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M12 3C6.9 3 3 6.4 3 10.5c0 3.7 3.2 6.8 7.6 7.4.3.1.7.2.8.5.1.3 0 .7 0 1l-.1.8c0 .2-.2.9.8.5s5.3-3.1 7.2-5.3c1.3-1.4 1.7-2.9 1.7-4.9C21 6.4 17.1 3 12 3zm-3.6 9.7H6.6c-.3 0-.5-.2-.5-.5V8.7c0-.3.2-.5.5-.5s.5.2.5.5v3h1.3c.3 0 .5.2.5.5s-.2.5-.5.5zm1.7-.5c0 .3-.2.5-.5.5s-.5-.2-.5-.5V8.7c0-.3.2-.5.5-.5s.5.2.5.5v3.5zm4.3 0c0 .2-.1.4-.3.5h-.2c-.2 0-.3-.1-.4-.2l-1.8-2.5v2.2c0 .3-.2.5-.5.5s-.5-.2-.5-.5V8.7c0-.2.1-.4.3-.5h.2c.2 0 .3.1.4.2l1.8 2.5V8.7c0-.3.2-.5.5-.5s.5.2.5.5v3.5zm2.9-2.3c.3 0 .5.2.5.5s-.2.5-.5.5h-1.3v.8h1.3c.3 0 .5.2.5.5s-.2.5-.5.5h-1.8c-.3 0-.5-.2-.5-.5V8.7c0-.3.2-.5.5-.5h1.8c.3 0 .5.2.5.5s-.2.5-.5.5h-1.3v.8h1.3z"/></svg>`,
  chev: `<svg class="ic" viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg>`,
  x: `<svg class="ic" viewBox="0 0 24 24"><path d="M18 6 6 18M6 6l12 12"/></svg>`,
  check: `<svg class="ic" viewBox="0 0 24 24"><path d="m5 12 5 5L20 7"/></svg>`,
  copy: `<svg class="ic" viewBox="0 0 24 24"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`,
  eye: `<svg class="ic" viewBox="0 0 24 24"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>`,
  eyeOff: `<svg class="ic" viewBox="0 0 24 24"><path d="M17.9 17.9A10 10 0 0 1 12 19c-6.5 0-10-7-10-7a17 17 0 0 1 4.1-4.9M9.9 5.2A9 9 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-2 2.8M14.1 14.1a3 3 0 1 1-4.2-4.2M2 2l20 20"/></svg>`,
  dice: `<svg class="ic" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="4"/><path d="M8 8h.01M16 8h.01M12 12h.01M8 16h.01M16 16h.01"/></svg>`,
  info: `<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v4h1"/></svg>`,
  warn: `<svg class="ic" viewBox="0 0 24 24"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0zM12 9v4M12 17h.01"/></svg>`,
  key: `<svg class="ic" viewBox="0 0 24 24"><circle cx="8" cy="15" r="4"/><path d="m10.8 12.2 9.2-9.2M15 8l3 3M18 5l3 3"/></svg>`,
  search: `<svg class="ic" viewBox="0 0 24 24" style="width:26px;height:26px"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>`,
  shield: `<svg class="ic" viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>`,
  lock: `<svg class="ic" viewBox="0 0 24 24"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>`,
};

// ───────── shell (โครง modal) ─────────
const SHELL = `
<div class="u2-modal" role="dialog" aria-modal="true" aria-labelledby="u2mTitle">
  <div class="u2-mhead">
    <div class="u2-mtitle">
      <span class="u2-eyebrow">ตั้งค่าระบบ · บัญชีพนักงาน</span>
      <h2 id="u2mTitle">จัดการผู้ใช้ <small id="u2headCount"></small></h2>
    </div>
    <label class="u2-search" id="u2searchBox">
      <svg class="ic" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
      <input id="u2q" type="text" placeholder="ค้นหาชื่อ · username · ทีม" autocomplete="off" spellcheck="false">
      <span class="u2-kbd">/</span>
      <button class="u2-clear" id="u2qClear" title="ล้างคำค้น" type="button">${I.x}</button>
    </label>
    <button class="u2-btn u2-primary" id="u2newBtn"><svg class="ic" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>สร้างบัญชี</button>
    <button class="u2-close" id="u2closeBtn" title="ปิด (Esc)" aria-label="ปิด"><svg class="ic" viewBox="0 0 24 24" style="width:20px;height:20px"><path d="M18 6 6 18M6 6l12 12"/></svg></button>
  </div>
  <div class="u2-mbody" id="u2mBody">
    <aside class="u2-side">
      <div class="u2-fgroup">
        <h4>สถานะ</h4>
        <div class="u2-seg" id="u2segStatus">
          <button data-v="all" class="on">ทั้งหมด</button>
          <button data-v="active">ใช้งาน</button>
          <button data-v="inactive">ปิด</button>
        </div>
      </div>
      <div class="u2-fgroup">
        <h4>บทบาท <button id="u2roleReset">ล้าง</button></h4>
        <div class="u2-flist" id="u2roleList"></div>
      </div>
      <div class="u2-fgroup">
        <h4>ทีม</h4>
        <div class="u2-select">
          <select id="u2teamFilter"><option value="">ทุกทีม</option></select>
          <svg class="ic" viewBox="0 0 24 24"><path d="m6 9 6 6 6-6"/></svg>
        </div>
      </div>
      <div class="u2-fgroup">
        <h4>LINE</h4>
        <label class="u2-check"><input type="checkbox" id="u2lineOnly"> ยังไม่เชื่อม LINE เท่านั้น</label>
      </div>
      <div class="u2-sidefoot"><b>เคล็ดลับ</b><br>กด <span class="u2-kbd">/</span> เพื่อค้นหา · <span class="u2-kbd">N</span> สร้างบัญชี · <span class="u2-kbd">Esc</span> ปิด</div>
    </aside>
    <main class="u2-main">
      <div class="u2-listbar">
        <span class="u2-count" id="u2listCount"></span>
        <div class="u2-chips" id="u2activeChips"></div>
        <div class="u2-sort">
          <span>เรียงตาม</span>
          <select id="u2sortSel">
            <option value="role">บทบาท</option>
            <option value="name">ชื่อ ก-ฮ</option>
            <option value="recent">ใช้งานล่าสุด</option>
            <option value="status">สถานะ</option>
          </select>
        </div>
      </div>
      <div class="u2-cols"><span>ผู้ใช้</span><span>บทบาท</span><span>ทีม</span><span>Session</span><span>LINE</span><span>สถานะ</span><span></span></div>
      <div class="u2-list" id="u2list" role="list"></div>
    </main>
    <aside class="u2-drawer" id="u2drawer" aria-live="polite"><div class="u2-drawerin" id="u2drawerIn"></div></aside>
  </div>
</div>`;

// ───────── ตัวกรอง ─────────
function renderRoleFilter() {
  const box = qs("#u2roleList"); if (!box) return;
  box.innerHTML = ROLE_ORDER.map((r) => {
    const c = users.filter((u) => u.role === r).length;
    return `<button class="u2-frow ${F.roles.has(r) ? "on" : ""}" data-r="${esc(r)}"><span class="u2-dot" style="background:${ROLES[r].color}"></span><span class="u2-lbl">${esc(r)}<span class="u2-sub">${esc(ROLES[r].label)}</span></span><span class="u2-cnt">${c}</span></button>`;
  }).join("");
  (qs("#u2roleReset") as HTMLElement)?.classList.toggle("show", F.roles.size > 0);
}
function populateTeamFilter() {
  const sel = qs<HTMLSelectElement>("#u2teamFilter"); if (!sel) return;
  const cur = F.team;
  sel.innerHTML = `<option value="">ทุกทีม</option>` + TEAMS.map((t) => `<option value="${esc(t)}">${esc(t)}</option>`).join("");
  sel.value = cur;
}
function clearFilters() {
  F.q = ""; F.status = "all"; F.roles.clear(); F.team = ""; F.lineOnly = false;
  const qInput = qs<HTMLInputElement>("#u2q"); if (qInput) qInput.value = "";
  qs("#u2searchBox")?.classList.remove("has-q");
  qs("#u2segStatus")?.querySelectorAll("button").forEach((x) => x.classList.toggle("on", (x as HTMLElement).dataset.v === "all"));
  const tf = qs<HTMLSelectElement>("#u2teamFilter"); if (tf) tf.value = "";
  const lo = qs<HTMLInputElement>("#u2lineOnly"); if (lo) lo.checked = false;
  renderRoleFilter(); render();
}

// ───────── รายชื่อ ─────────
function filtered(): UUser[] {
  const list = users.filter((u) => {
    if (F.q && !hasQ(u, F.q)) return false;
    if (F.status === "active" && !u.active) return false;
    if (F.status === "inactive" && u.active) return false;
    if (F.roles.size && !F.roles.has(u.role)) return false;
    if (F.team && !(u.allTeams || u.teams.includes(F.team))) return false;
    if (F.lineOnly && u.line) return false;
    return true;
  });
  const coll = new Intl.Collator("th");
  list.sort((a, b) => {
    if (sort === "name") return coll.compare(nameOf(a), nameOf(b));
    if (sort === "recent") return (b.lastSeen || 0) - (a.lastSeen || 0);
    if (sort === "status") return (Number(b.active) - Number(a.active)) || coll.compare(nameOf(a), nameOf(b));
    return (ROLE_ORDER.indexOf(a.role) - ROLE_ORDER.indexOf(b.role)) || coll.compare(nameOf(a), nameOf(b));
  });
  return list;
}
function render() {
  if (!overlay) return;
  const list = filtered();
  const act = users.filter((u) => u.active).length;
  const hc = qs("#u2headCount"); if (hc) hc.textContent = `${users.length} บัญชี · ใช้งาน ${act}`;
  const lc = qs("#u2listCount"); if (lc) lc.innerHTML = `แสดง <b>${list.length}</b> จาก ${users.length}`;
  // chips
  const chips: [string, string][] = [];
  if (F.q) chips.push(["q", `“${F.q}”`]);
  if (F.status !== "all") chips.push(["status", F.status === "active" ? "ใช้งาน" : "ปิดใช้งาน"]);
  F.roles.forEach((r) => chips.push(["role:" + r, r]));
  if (F.team) chips.push(["team", "ทีม " + F.team]);
  if (F.lineOnly) chips.push(["line", "ยังไม่เชื่อม LINE"]);
  const ac = qs("#u2activeChips");
  if (ac) ac.innerHTML = chips.map(([k, l]) => `<span class="u2-chip">${esc(l)}<button data-k="${esc(k)}" title="เอาออก">${I.x}</button></span>`).join("") + (chips.length > 1 ? `<button class="u2-btn u2-ghost u2-sm" style="padding:2px 8px;font-size:11.5px" data-k="__all">ล้างทั้งหมด</button>` : "");

  const listEl = qs("#u2list"); if (!listEl) return;
  if (!list.length) {
    listEl.innerHTML = `<div class="u2-empty"><span class="u2-glyph">${I.search}</span><b>ไม่พบผู้ใช้ที่ตรงเงื่อนไข</b><span>ลองเปลี่ยนคำค้นหรือล้างตัวกรองดูนะคะ</span><button class="u2-btn u2-soft u2-sm" data-clear="1">ล้างตัวกรอง</button></div>`;
    return;
  }
  listEl.innerHTML = list.map((u, i) => {
    const R = ROLES[u.role] || ROLES.RTs;
    const teamsH = u.allTeams ? `<span class="u2-team all">ทุกทีม</span>`
      : u.teams.slice(0, 2).map((t) => `<span class="u2-team">${esc(t)}</span>`).join("") + (u.teams.length > 2 ? `<span class="u2-team more" title="${esc(u.teams.slice(2).join(", "))}">+${u.teams.length - 2}</span>` : "");
    const pct = Math.min(100, Math.round(u.hours / 24 * 100));
    return `<div class="u2-row ${u.id === selectedId ? "sel" : ""} ${u.active ? "" : "off"}" role="listitem" data-id="${esc(u.id)}" style="--i:${i}" tabindex="0">
      <div class="u2-who"><span class="u2-avatar ${u.id === ME ? "me" : ""}" style="background:${u.active ? `var(--r-${R.cls.toLowerCase()}-bg)` : "var(--paper-2)"};color:${u.active ? R.color : "var(--ink-3)"}">${esc(initials(nameOf(u)))}</span>
        <span class="u2-t"><span class="u2-n">${esc(nameOf(u))}</span><span class="u2-u u2-mono">${esc(u.username)}</span></span></div>
      <div class="u2-meta">
      <span><span class="u2-badge ${R.cls}" title="${esc(R.label)}"><i></i>${esc(u.role)}</span></span>
      <div class="u2-teams">${teamsH}</div>
      <div class="u2-sess"><span class="u2-v"><b>${u.hours}</b><span>ชม.</span><span class="sep">·</span><span>idle</span><b>${u.idle}</b><span>น.</span></span><span class="u2-bar"><i style="width:${pct}%"></i></span><span class="u2-lastseen">${esc(rel(u.lastSeen))}</span></div>
      <span class="u2-line ${u.line ? "yes" : "no"}" title="${u.line ? "เชื่อม LINE แล้ว" : "ยังไม่เชื่อม LINE"}">${I.line}</span>
      </div>
      <span class="u2-status ${u.active ? "on" : ""}"><i></i>${u.active ? "ใช้งาน" : "ปิดใช้งาน"}</span>
      <span class="u2-go">${I.chev}</span>
    </div>`;
  }).join("");
}

// ───────── drawer เปิด/ปิด ─────────
function setDrawer(open: boolean) {
  qs("#u2mBody")?.classList.toggle("u2-dopen", open);
  if (!open) { selectedId = null; drawerMode = null; dirty = false; render(); }
}
function closeDrawer(force = false) {
  if (!force && dirty) {
    qs("#u2dirtyConfirm")?.remove();
    const box = document.createElement("div");
    box.className = "u2-confirm danger"; box.id = "u2dirtyConfirm";
    box.innerHTML = `<span>มีการแก้ไขที่ยังไม่ได้บันทึก — ปิดแล้วข้อมูลจะหาย</span><div class="acts"><button class="u2-btn u2-ghost u2-sm" data-a="stay">กลับไปแก้ต่อ</button><button class="u2-btn u2-danger u2-sm" data-a="discard">ทิ้งการแก้ไข</button></div>`;
    box.addEventListener("click", (e) => {
      const a = (e.target as HTMLElement).closest("button")?.getAttribute("data-a");
      if (a === "stay") box.remove();
      if (a === "discard") closeDrawer(true);
    });
    qs("#u2drawerIn .u2-dbody")?.prepend(box);
    box.scrollIntoView({ behavior: "smooth", block: "nearest" });
    return;
  }
  setDrawer(false);
  setTimeout(() => { if (!drawerMode) { const di = qs("#u2drawerIn"); if (di) di.innerHTML = ""; } }, 380);
}

// ───────── ฟอร์ม (create/edit) ─────────
function formHTML(u: UUser, mode: "create" | "edit"): string {
  const isMe = u.id === ME;
  const roleCards = ROLE_ORDER.map((r) => `<label class="u2-role ${u.role === r ? "on" : ""}" data-r="${esc(r)}"><input type="radio" name="role" value="${esc(r)}" ${u.role === r ? "checked" : ""} ${isMe ? "disabled" : ""}><span class="u2-rt"><b>${esc(ROLES[r].label)}</b><span>${esc(ROLES[r].desc)}</span></span><span class="u2-badge ${ROLES[r].cls}"><i></i>${esc(r)}</span></label>`).join("");
  const teamChips = TEAMS.map((t) => `<button type="button" class="u2-tchip ${u.teams.includes(t) ? "on" : ""}" data-t="${esc(t)}">${esc(t)}</button>`).join("");
  const presetsH = [4, 8, 12, 24].map((v) => `<button type="button" class="u2-preset ${u.hours === v ? "on" : ""}" data-h="${v}">${v} ชม.</button>`).join("");
  const presetsI = [10, 15, 30, 60].map((v) => `<button type="button" class="u2-preset ${u.idle === v ? "on" : ""}" data-i="${v}">${v} น.</button>`).join("");
  const headName = u.name.trim() || (mode === "edit" ? u.username : "") || "ผู้ใช้ใหม่";
  return `
  <div class="u2-dhead">
    <span class="u2-avatar" id="u2dAvatar" style="width:40px;height:40px;background:var(--r-${ROLES[u.role].cls.toLowerCase()}-bg);color:${ROLES[u.role].color}">${esc(initials(headName))}</span>
    <div class="u2-t"><small>${mode === "create" ? "บัญชีใหม่" : "แก้ไขบัญชี"}</small><h3 id="u2dName">${esc(headName)}</h3></div>
    <button class="u2-close" style="margin-left:auto" data-a="close" title="ปิด">${I.x}</button>
  </div>
  <div class="u2-dbody">
    <form id="u2uf" class="u2-sec" novalidate autocomplete="off">
      <h5>ข้อมูลบัญชี</h5>
      <div class="u2-field" data-f="username">
        <label>Username <span class="u2-req">*</span><em>a-z 0-9 . _ - · 3–24 ตัว</em></label>
        <div class="u2-inp ${mode === "edit" ? "ro" : ""}"><span class="pre">@</span><input name="username" class="u2-mono" value="${esc(u.username)}" placeholder="เช่น sup-a-nan" ${mode === "edit" ? "readonly" : ""} maxlength="24"><span class="ok" id="u2uOk" style="display:none">${I.check}</span></div>
        <span class="u2-msg">${mode === "edit" ? "เปลี่ยน username ไม่ได้หลังสร้างแล้ว" : ""}</span>
      </div>
      <div class="u2-field" data-f="name">
        <label>ชื่อที่แสดง <span class="u2-req">*</span></label>
        <div class="u2-inp"><input name="name" value="${esc(u.name)}" placeholder="ชื่อเล่นที่ทีมเรียก" maxlength="40"></div>
        <span class="u2-msg"></span>
      </div>
      <div class="u2-field" data-f="line">
        <label>LINE user id <em>ไม่บังคับ · U + 32 hex</em></label>
        <div class="u2-inp"><input name="line" class="u2-mono" value="${esc(u.line || "")}" placeholder="Uxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" maxlength="33" spellcheck="false">${u.line ? `<span class="ok"><svg class="ic" viewBox="0 0 24 24" fill="currentColor" stroke="none" style="width:16px;height:16px"><path d="M12 3C6.9 3 3 6.4 3 10.5c0 3.7 3.2 6.8 7.6 7.4.3.1.7.2.8.5.1.3 0 .7 0 1l-.1.8c0 .2-.2.9.8.5s5.3-3.1 7.2-5.3c1.3-1.4 1.7-2.9 1.7-4.9C21 6.4 17.1 3 12 3z"/></svg></span>` : ""}</div>
        <span class="u2-msg">${u.line ? "เชื่อม LINE แล้ว — ใช้รับ OTP เข้าระบบ" : "ยังไม่เชื่อม — ผู้ใช้จะรับ OTP ไม่ได้"}</span>
      </div>

      <h5 style="margin-top:6px">บทบาท</h5>
      <div class="u2-roles" id="u2roleCards">${roleCards}</div>
      ${isMe ? `<div class="u2-hint warn">${I.lock}<span>เปลี่ยนบทบาทของตัวเองไม่ได้ ป้องกันล็อกตัวเองออกจากระบบ</span></div>` : ""}

      <h5 style="margin-top:6px">ทีมที่สังกัด</h5>
      <div class="u2-switch"><span class="u2-st"><b>ทุกทีม</b><span id="u2allTeamsHint"></span></span><button type="button" class="u2-tog ${u.allTeams ? "on" : ""}" id="u2allTeams" aria-pressed="${u.allTeams}"></button></div>
      <div class="u2-tchips ${u.allTeams ? "dim" : ""}" id="u2teamChips">${teamChips}</div>
      <div class="u2-field" data-f="teams" style="gap:0"><span class="u2-msg"></span></div>

      <h5 style="margin-top:6px">Session</h5>
      <div class="u2-grid2">
        <div class="u2-field" data-f="hours">
          <label>อายุ session <em>ชั่วโมง 1–72</em></label>
          <div class="u2-stepper"><button type="button" data-step="hours" data-d="-1">−</button><input name="hours" type="number" min="1" max="72" value="${u.hours}"><button type="button" data-step="hours" data-d="1">+</button></div>
          <div class="u2-presets" id="u2phours">${presetsH}</div>
          <span class="u2-msg"></span>
        </div>
        <div class="u2-field" data-f="idle">
          <label>Idle timeout <em>นาที 5–480</em></label>
          <div class="u2-stepper"><button type="button" data-step="idle" data-d="-5">−</button><input name="idle" type="number" min="5" max="480" value="${u.idle}"><button type="button" data-step="idle" data-d="5">+</button></div>
          <div class="u2-presets" id="u2pidle">${presetsI}</div>
          <span class="u2-msg"></span>
        </div>
      </div>
      <div class="u2-sesspreview" id="u2sessPreview">${I.info}<span></span></div>

      ${mode === "edit" ? `
      <h5 style="margin-top:6px">สถานะ</h5>
      <div class="u2-switch"><span class="u2-st"><b>เปิดใช้งานบัญชี</b><span>${isMe ? "ปิดบัญชีตัวเองไม่ได้" : "ปิดแล้วเข้าสู่ระบบไม่ได้ทันที · session ปัจจุบันถูกตัด"}</span></span><button type="button" class="u2-tog ${u.active ? "on" : ""}" id="u2activeTog" ${isMe ? "disabled" : ""} aria-pressed="${u.active}"></button></div>
      <div id="u2deactWrap"></div>

      <h5 style="margin-top:6px">รหัสผ่าน</h5>
      <div class="u2-pwbox" id="u2pwBox">
        <div class="u2-rowh"><div><b>รีเซ็ตรหัสผ่าน</b><br><span>ตั้งรหัสใหม่ให้ผู้ใช้ · รหัสเดิมใช้ไม่ได้ทันที</span></div><button type="button" class="u2-btn u2-ghost u2-sm" id="u2pwOpen">${I.key} ตั้งรหัสใหม่</button></div>
        <div id="u2pwArea" style="display:none;flex-direction:column;gap:10px">
          <div class="u2-field" data-f="pw">
            <div class="u2-inp"><input name="pw" type="text" class="u2-mono" placeholder="รหัสผ่านใหม่ (อย่างน้อย 8 ตัว)" spellcheck="false" autocomplete="new-password"><button type="button" id="u2pwEye" title="ซ่อน/แสดง">${I.eye}</button><button type="button" id="u2pwGen" title="สุ่มรหัสผ่าน">${I.dice}</button></div>
            <div class="u2-strength" id="u2pwStrength" data-s="0"><i></i><i></i><i></i><i></i></div>
            <span class="u2-stlabel"><span class="u2-msg"></span><span id="u2pwStLabel"></span></span>
          </div>
          <div class="acts" style="display:flex;gap:6px;justify-content:flex-end"><button type="button" class="u2-btn u2-ghost u2-sm" id="u2pwCancel">ยกเลิก</button><button type="button" class="u2-btn u2-primary u2-sm" id="u2pwSave">${I.check} ตั้งรหัสใหม่</button></div>
          <div id="u2pwConfirmWrap"></div>
        </div>
      </div>
      <div class="u2-hint" style="margin-top:-6px">${I.info}<span>${u.created ? "สร้างเมื่อ " + new Date(u.created).toLocaleDateString("th-TH", { day: "numeric", month: "short", year: "2-digit" }) + " · " : ""}เข้าใช้ล่าสุด ${esc(rel(u.lastSeen))}</span></div>
      ` : `
      <div class="u2-hint" style="margin-top:-4px">${I.shield}<span>ระบบจะ<b>สุ่มรหัสผ่านให้อัตโนมัติ</b>ตอนกดสร้าง และแสดงให้เห็น<b>ครั้งเดียว</b> — เตรียมช่องทางส่งให้ผู้ใช้ไว้ก่อนนะคะ</span></div>
      `}
    </form>
  </div>
  <div class="u2-dfoot">
    <span id="u2footHint" style="font-size:12px;color:var(--ink-3)"></span>
    <span class="u2-spacer"></span>
    <button class="u2-btn u2-ghost" data-a="close">ยกเลิก</button>
    <button class="u2-btn u2-primary" id="u2saveBtn" ${mode === "edit" ? "disabled" : ""}>${mode === "create" ? I.dice + " สร้างบัญชี + สุ่มรหัส" : I.check + " บันทึก"}</button>
  </div>`;
}

function openCreate() {
  selectedId = null; drawerMode = "create"; dirty = false;
  mountForm({ id: "", name: "", username: "", role: "RTs", allTeams: false, teams: [], active: true, hours: 8, idle: 30, line: null, lastSeen: null, created: null }, "create");
  render(); setDrawer(true);
  setTimeout(() => (qs<HTMLInputElement>('#u2uf input[name=username]'))?.focus(), 380);
}
function openEdit(id: string) {
  if (selectedId === id && drawerMode === "edit") return;
  if (dirty) { closeDrawer(); return; }
  const u = users.find((x) => x.id === id); if (!u) return;
  selectedId = id; drawerMode = "edit"; dirty = false;
  mountForm(structuredClone(u), "edit"); render(); setDrawer(true);
}

// ───────── mount form + validate + save ─────────
function mountForm(draft: UUser, mode: "create" | "edit") {
  const host = qs("#u2drawerIn"); if (!host) return;
  host.innerHTML = formHTML(draft, mode);
  const f = qs<HTMLFormElement>("#u2uf")!;
  let pwPending: string | null = null;
  const touched = new Set<string>();

  const DEFAULT_MSG: Record<string, string | (() => string)> = {
    username: mode === "edit" ? "เปลี่ยน username ไม่ได้หลังสร้างแล้ว" : "",
    line: () => draft.line ? "เชื่อม LINE แล้ว — ใช้รับ OTP เข้าระบบ" : "ยังไม่เชื่อม — ผู้ใช้จะรับ OTP ไม่ได้",
  };
  const setErr = (key: string, msg?: string) => {
    const fd = host.querySelector(`.u2-field[data-f="${key}"]`); if (!fd) return;
    fd.classList.toggle("err", !!msg);
    const mEl = fd.querySelector(".u2-msg"); if (!mEl) return;
    const def = DEFAULT_MSG[key];
    mEl.textContent = msg || (typeof def === "function" ? def() : (def || ""));
  };
  const markDirty = () => {
    if (mode === "edit") { dirty = true; (qs("#u2saveBtn") as HTMLButtonElement).disabled = false; const fh = qs("#u2footHint"); if (fh) fh.textContent = "มีการแก้ไขที่ยังไม่บันทึก"; }
  };

  function validate(showAll = false): Record<string, string> {
    const errs: Record<string, string> = {};
    // username ตรวจเฉพาะตอนสร้าง — ตอนแก้ไข username readonly เปลี่ยนไม่ได้ (บัญชีเดิมบางอันมีพิมพ์ใหญ่ เช่น sup-c-BN ไม่ควรโดนบล็อก)
    if (mode === "create") {
      const un = draft.username.trim();
      if (!un) errs.username = "กรุณากรอก username";
      else if (!/^[a-z0-9][a-z0-9._-]{2,23}$/.test(un)) errs.username = "ใช้ได้เฉพาะ a-z 0-9 . _ - ความยาว 3–24";
      else if (users.some((x) => x.username.toLowerCase() === un.toLowerCase() && x.id !== draft.id)) errs.username = "username นี้มีคนใช้แล้ว";
    }
    if (!draft.name.trim()) errs.name = "กรุณากรอกชื่อที่แสดง";
    else if (/[​-‍﻿⁠]/.test(draft.name)) errs.name = "มีอักขระล่องหนปนอยู่ในชื่อ";
    if (draft.line && !/^U[0-9a-f]{32}$/.test(draft.line)) errs.line = "รูปแบบไม่ถูกต้อง — ต้องขึ้นต้นด้วย U ตามด้วย hex 32 ตัว";
    if (!draft.allTeams && !draft.teams.length) errs.teams = 'เลือกอย่างน้อย 1 ทีม หรือเปิด "ทุกทีม"';
    if (!(draft.hours >= 1 && draft.hours <= 72)) errs.hours = "1–72 ชั่วโมง";
    if (!(draft.idle >= 5 && draft.idle <= 480)) errs.idle = "5–480 นาที";
    else if (draft.idle > draft.hours * 60) errs.idle = "idle ต้องไม่เกินอายุ session";
    ["username", "name", "line", "teams", "hours", "idle"].forEach((k) => { if (showAll || touched.has(k)) setErr(k, errs[k]); });
    const uOk = qs<HTMLElement>("#u2uOk"); if (uOk) uOk.style.display = (!errs.username && draft.username.trim() && mode === "create") ? "" : "none";
    return errs;
  }

  const updatePreview = () => {
    const elp = host.querySelector("#u2sessPreview span") as HTMLElement | null; if (!elp) return;
    const hh = draft.hours, ii = draft.idle;
    elp.innerHTML = (hh >= 1 && ii >= 5) ? `ล็อกอินค้างได้สูงสุด <b>${hh} ชม.</b> · ไม่ขยับ <b>${ii} นาที</b> จะถูกออกจากระบบอัตโนมัติ` : "กรอกค่า session ให้ครบ";
  };
  const syncPresets = () => {
    host.querySelectorAll("#u2phours .u2-preset").forEach((p) => p.classList.toggle("on", Number((p as HTMLElement).dataset.h) === draft.hours));
    host.querySelectorAll("#u2pidle .u2-preset").forEach((p) => p.classList.toggle("on", Number((p as HTMLElement).dataset.i) === draft.idle));
  };

  // inputs
  f.addEventListener("input", (e) => {
    const t = e.target as HTMLInputElement; const n = t.name; if (!n) return; touched.add(n);
    if (n === "username") { t.value = t.value.toLowerCase().replace(/[^a-z0-9._-]/g, ""); draft.username = t.value; }
    else if (n === "name") { draft.name = t.value; const dn = qs("#u2dName"); if (dn) dn.textContent = draft.name.trim() || "ผู้ใช้ใหม่"; const da = qs("#u2dAvatar"); if (da) da.textContent = initials(draft.name || "?"); }
    else if (n === "line") { t.value = t.value.trim(); draft.line = t.value || null; }
    else if (n === "hours") { draft.hours = +t.value; syncPresets(); }
    else if (n === "idle") { draft.idle = +t.value; syncPresets(); }
    else if (n === "pw") { const s = strength(t.value); const st = qs<HTMLElement>("#u2pwStrength"); if (st) st.dataset.s = String(s); const lb = qs("#u2pwStLabel"); if (lb) lb.textContent = t.value ? STRENGTH_LABEL[s] : ""; setErr("pw", ""); return; }
    markDirty(); validate(); updatePreview();
  });
  f.addEventListener("submit", (e) => e.preventDefault());

  // role
  host.querySelector("#u2roleCards")!.addEventListener("change", (e) => {
    const t = e.target as HTMLInputElement; if (t.name !== "role") return;
    draft.role = t.value; touched.add("teams");
    host.querySelectorAll(".u2-role").forEach((r) => r.classList.toggle("on", (r as HTMLElement).dataset.r === draft.role));
    const R = ROLES[draft.role];
    const da = qs<HTMLElement>("#u2dAvatar"); if (da) { da.style.background = `var(--r-${R.cls.toLowerCase()}-bg)`; da.style.color = R.color; }
    if (R.allTeams && !draft.allTeams) { draft.allTeams = true; syncTeams(); }
    if (!R.allTeams && draft.allTeams && mode === "create") { draft.allTeams = false; syncTeams(); }
    markDirty(); validate(); updatePreview();
  });

  // teams
  const syncTeams = () => {
    const R = ROLES[draft.role];
    const at = qs<HTMLElement>("#u2allTeams")!; at.classList.toggle("on", draft.allTeams); at.setAttribute("aria-pressed", String(draft.allTeams));
    qs("#u2teamChips")?.classList.toggle("dim", draft.allTeams);
    host.querySelectorAll(".u2-tchip").forEach((c) => c.classList.toggle("on", draft.teams.includes((c as HTMLElement).dataset.t || "")));
    const hint = qs("#u2allTeamsHint"); if (hint) hint.textContent = draft.allTeams ? (R.allTeams ? `บทบาท ${draft.role} เห็นทุกทีมโดยธรรมชาติ` : "เห็นงานตีกลับของทุกทีม") : `เลือกได้หลายทีม · เลือกแล้ว ${draft.teams.length}`;
  };
  qs("#u2allTeams")!.addEventListener("click", () => { draft.allTeams = !draft.allTeams; touched.add("teams"); syncTeams(); markDirty(); validate(); });
  qs("#u2teamChips")!.addEventListener("click", (e) => {
    const c = (e.target as HTMLElement).closest(".u2-tchip") as HTMLElement | null; if (!c) return;
    const t = c.dataset.t || ""; draft.teams = draft.teams.includes(t) ? draft.teams.filter((x) => x !== t) : [...draft.teams, t];
    touched.add("teams"); syncTeams(); markDirty(); validate();
  });
  syncTeams();

  // session steppers/presets + close buttons
  host.addEventListener("click", (e) => {
    const tgt = e.target as HTMLElement;
    const st = tgt.closest("[data-step]") as HTMLElement | null;
    if (st) { const k = st.dataset.step as "hours" | "idle"; const inp = f.elements.namedItem(k) as HTMLInputElement; const v = Math.min(+inp.max, Math.max(+inp.min, (+inp.value || 0) + (+(st.dataset.d || 0)))); inp.value = String(v); draft[k] = v; touched.add(k); syncPresets(); markDirty(); validate(); updatePreview(); return; }
    const ph = tgt.closest("#u2phours .u2-preset") as HTMLElement | null;
    if (ph) { draft.hours = +(ph.dataset.h || 0); (f.elements.namedItem("hours") as HTMLInputElement).value = String(draft.hours); touched.add("hours"); syncPresets(); markDirty(); validate(); updatePreview(); return; }
    const pi = tgt.closest("#u2pidle .u2-preset") as HTMLElement | null;
    if (pi) { draft.idle = +(pi.dataset.i || 0); (f.elements.namedItem("idle") as HTMLInputElement).value = String(draft.idle); touched.add("idle"); syncPresets(); markDirty(); validate(); updatePreview(); return; }
    const a = (tgt.closest("[data-a]") as HTMLElement | null)?.dataset.a;
    if (a === "close") closeDrawer();
  });
  updatePreview();

  // status (edit)
  const tog = qs<HTMLButtonElement>("#u2activeTog");
  if (tog) tog.addEventListener("click", () => {
    if (draft.active) {
      const w = qs<HTMLElement>("#u2deactWrap")!;
      w.innerHTML = `<div class="u2-confirm"><span>ปิดใช้งาน <b>${esc(nameOf(draft))}</b>? ผู้ใช้จะเข้าสู่ระบบไม่ได้จนกว่าจะเปิดอีกครั้ง (ข้อมูลไม่หาย)</span><div class="acts"><button type="button" class="u2-btn u2-ghost u2-sm" data-c="no">ยกเลิก</button><button type="button" class="u2-btn u2-danger u2-sm" data-c="yes">ปิดใช้งาน</button></div></div>`;
      w.onclick = (e) => { const c = (e.target as HTMLElement).closest("[data-c]")?.getAttribute("data-c"); if (!c) return; if (c === "yes") { draft.active = false; tog.classList.remove("on"); markDirty(); } w.innerHTML = ""; };
    } else { draft.active = true; tog.classList.add("on"); qs<HTMLElement>("#u2deactWrap")!.innerHTML = ""; markDirty(); }
  });

  // reset password (edit)
  const pwArea = qs<HTMLElement>("#u2pwArea");
  if (pwArea) {
    const pwInp = f.elements.namedItem("pw") as HTMLInputElement;
    const stEl = qs<HTMLElement>("#u2pwStrength")!, stLb = qs<HTMLElement>("#u2pwStLabel")!;
    const pwUpdate = (v: string) => { const s = strength(v); stEl.dataset.s = String(s); stLb.textContent = v ? STRENGTH_LABEL[s] : ""; setErr("pw", ""); };
    qs("#u2pwOpen")!.addEventListener("click", () => { pwArea.style.display = "flex"; (qs<HTMLElement>("#u2pwOpen"))!.style.visibility = "hidden"; pwInp.focus(); });
    qs("#u2pwCancel")!.addEventListener("click", () => { pwArea.style.display = "none"; (qs<HTMLElement>("#u2pwOpen"))!.style.visibility = ""; pwInp.value = ""; pwUpdate(""); qs<HTMLElement>("#u2pwConfirmWrap")!.innerHTML = ""; });
    qs("#u2pwGen")!.addEventListener("click", () => { pwInp.type = "text"; pwInp.value = genPassword(12); pwUpdate(pwInp.value); pwInp.focus(); pwInp.select(); });
    qs("#u2pwEye")!.addEventListener("click", (e) => { pwInp.type = pwInp.type === "text" ? "password" : "text"; (e.currentTarget as HTMLElement).innerHTML = pwInp.type === "text" ? I.eye : I.eyeOff; });
    qs("#u2pwSave")!.addEventListener("click", () => {
      const v = pwInp.value;
      if (v.length < 8) return setErr("pw", "อย่างน้อย 8 ตัวอักษร");
      if (/\s/.test(v)) return setErr("pw", "ห้ามมีช่องว่าง");
      if (strength(v) < 2) return setErr("pw", "รหัสอ่อนเกินไป — ผสมตัวพิมพ์ใหญ่/เล็ก ตัวเลข สัญลักษณ์");
      const w = qs<HTMLElement>("#u2pwConfirmWrap")!;
      w.innerHTML = `<div class="u2-confirm"><span>ยืนยันตั้งรหัสใหม่ให้ <b>${esc(nameOf(draft))}</b>? รหัสเดิมจะใช้ไม่ได้ทันที และ session ที่เปิดอยู่จะถูกตัด</span><div class="acts"><button type="button" class="u2-btn u2-ghost u2-sm" data-c="no">ยกเลิก</button><button type="button" class="u2-btn u2-primary u2-sm" data-c="yes">ยืนยัน</button></div></div>`;
      w.onclick = (e) => {
        const c = (e.target as HTMLElement).closest("[data-c]")?.getAttribute("data-c"); if (!c) return; w.innerHTML = "";
        if (c === "yes") {
          pwPending = v; pwArea.style.display = "none";
          const po = qs<HTMLElement>("#u2pwOpen")!; po.style.visibility = ""; po.innerHTML = `${I.check} รหัสใหม่พร้อมบันทึก`; po.classList.add("u2-soft");
          markDirty(); toast(`ตั้งรหัสใหม่ให้ ${nameOf(draft)} แล้ว — กด "บันทึก" เพื่อยืนยัน`, "warn");
        }
      };
    });
  }

  // save
  qs("#u2saveBtn")!.addEventListener("click", async () => {
    const errs = validate(true);
    const first = Object.keys(errs)[0];
    if (first) { host.querySelector(`.u2-field[data-f="${first}"]`)?.scrollIntoView({ behavior: "smooth", block: "center" }); toast("กรอกข้อมูลไม่ครบ/ไม่ถูกต้อง ตรวจช่องที่ขีดแดงนะคะ", "err"); return; }
    if (busy) return; busy = true;
    const btn = qs<HTMLButtonElement>("#u2saveBtn")!; btn.disabled = true;
    btn.innerHTML = `<span class="u2-spin"></span> กำลังบันทึก…`;
    draft.name = draft.name.trim(); draft.username = draft.username.trim();
    if (draft.allTeams) draft.teams = [];
    const payload = {
      display_name: draft.name, role: draft.role, all_teams: draft.allTeams,
      team_ids: draft.allTeams ? [] : teamIds(draft.teams),
      idle_minutes: draft.idle, session_hours: draft.hours, line_user_id: draft.line || "",
    };
    try {
      if (mode === "create") {
        const r = await adminCreateUser({ ...payload, username: draft.username });
        if (!r.ok) { toast(umErr(r.error), "err"); btn.disabled = false; btn.innerHTML = `${I.dice} สร้างบัญชี + สุ่มรหัส`; return; }
        await reload();
        selectedId = r.user_id || null; drawerMode = "reveal"; dirty = false; render();
        mountReveal({ ...draft, username: r.username || draft.username }, r.password || "");
        toast(`สร้างบัญชี ${nameOf(draft)} สำเร็จ`);
      } else {
        const r = await adminUpdateUser(draft.id, { ...payload, is_active: draft.active });
        if (!r.ok) { toast(umErr(r.error), "err"); btn.disabled = false; btn.innerHTML = `${I.check} บันทึก`; return; }
        if (pwPending) { const rp = await adminResetPassword(draft.id, pwPending); if (!rp.ok) toast("บันทึกแล้ว แต่รีเซ็ตรหัสไม่ผ่าน: " + umErr(rp.error), "err"); }
        await reload();
        dirty = false; drawerMode = "edit";
        const fresh = users.find((x) => x.id === draft.id);
        toast(pwPending ? `บันทึก + รีเซ็ตรหัส ${nameOf(draft)} แล้ว` : `บันทึกการแก้ไข ${nameOf(draft)} แล้ว`);
        if (fresh) mountForm(structuredClone(fresh), "edit"); else closeDrawer(true);
      }
    } catch {
      toast("เชื่อมต่อไม่ได้", "err");
      btn.disabled = false; btn.innerHTML = mode === "create" ? `${I.dice} สร้างบัญชี + สุ่มรหัส` : `${I.check} บันทึก`;
    } finally { busy = false; }
  });
}

// ───────── reveal (รหัสครั้งเดียว หลังสร้าง) ─────────
function mountReveal(u: UUser, pw: string) {
  const host = qs("#u2drawerIn"); if (!host) return;
  let copied = false, hidden = false;
  host.innerHTML = `
  <div class="u2-dhead"><div class="u2-t"><small>สร้างสำเร็จ</small><h3>${esc(nameOf(u))} · <span class="u2-mono" style="font-weight:500;color:var(--ink-2)">@${esc(u.username)}</span></h3></div></div>
  <div class="u2-dbody">
    <div class="u2-reveal">
      <span class="u2-okmark"><svg class="ic" viewBox="0 0 24 24" style="width:28px;height:28px;stroke-width:2.5"><path d="m5 12 5 5L20 7"/></svg></span>
      <h4>บัญชีพร้อมใช้งานแล้ว</h4>
      <p>ส่ง username และรหัสผ่านชั่วคราวนี้ให้ <b>${esc(nameOf(u))}</b> ผ่านช่องทางที่ปลอดภัย</p>
      <div class="u2-cred">
        <div class="u2-cr"><span class="u2-k">Username</span><span class="u2-v">${esc(u.username)}</span><button class="u2-cp" data-cp="user">${I.copy} คัดลอก</button></div>
        <div class="u2-cr"><span class="u2-k">รหัสผ่าน</span><span class="u2-v pw" id="u2pwText">${esc(pw)}</span><button class="u2-cp" data-cp="pw">${I.copy} คัดลอก</button></div>
        <div class="u2-cr"><span class="u2-k">บทบาท / ทีม</span><span class="u2-v" style="font-family:var(--sans);font-size:13px"><span class="u2-badge ${ROLES[u.role].cls}"><i></i>${esc(u.role)}</span> &nbsp;${esc(teamLabel(u))}</span><button class="u2-cp" data-cp="all">${I.copy} ทั้งชุด</button></div>
      </div>
      <div class="u2-notice">${I.warn}<span><b>แสดงครั้งเดียว</b> — ปิดหน้านี้แล้วจะดูรหัสผ่านอีกไม่ได้ ถ้าหาย ให้ใช้ "รีเซ็ตรหัสผ่าน" ในหน้าแก้ไขแทน</span></div>
      <label class="u2-check" style="justify-content:center"><input type="checkbox" id="u2hidePw"> ซ่อนรหัสบนจอ (กันคนมองข้ามไหล่)</label>
      <div id="u2revealConfirm"></div>
    </div>
  </div>
  <div class="u2-dfoot"><span id="u2cpState" style="font-size:12px;color:var(--ink-3)">ยังไม่ได้คัดลอกรหัสผ่าน</span><span class="u2-spacer"></span><button class="u2-btn u2-soft" id="u2editNew">แก้ไขบัญชีนี้</button><button class="u2-btn u2-primary" id="u2doneBtn">เสร็จสิ้น</button></div>`;
  qs("#u2hidePw")!.addEventListener("change", (e) => { hidden = (e.target as HTMLInputElement).checked; const pt = qs("#u2pwText"); if (pt) pt.textContent = hidden ? "•".repeat(pw.length) : pw; });
  host.addEventListener("click", async (e) => {
    const b = (e.target as HTMLElement).closest("[data-cp]") as HTMLElement | null; if (!b) return;
    const k = b.dataset.cp; const txt = k === "user" ? u.username : k === "pw" ? pw : `username: ${u.username}\nรหัสผ่าน: ${pw}\nบทบาท: ${u.role} (${ROLES[u.role].label})\nทีม: ${teamLabel(u)}`;
    const ok = await copyText(txt);
    if (!ok) { toast("คัดลอกไม่สำเร็จ — เบราว์เซอร์ไม่อนุญาต", "err"); return; }
    b.classList.add("done"); b.innerHTML = `${I.check} คัดลอกแล้ว`;
    setTimeout(() => { b.classList.remove("done"); b.innerHTML = `${I.copy} ${k === "all" ? "ทั้งชุด" : "คัดลอก"}`; }, 1800);
    if (k !== "user") { copied = true; const cs = qs<HTMLElement>("#u2cpState"); if (cs) { cs.innerHTML = `${I.check} คัดลอกรหัสผ่านแล้ว`; cs.style.color = "var(--green)"; } }
    toast(k === "all" ? "คัดลอกข้อมูลทั้งชุดแล้ว" : "คัดลอกแล้ว");
  });
  qs("#u2editNew")!.addEventListener("click", () => { drawerMode = null; openEdit(u.id); });
  qs("#u2doneBtn")!.addEventListener("click", () => {
    if (copied) { closeDrawer(true); return; }
    const w = qs<HTMLElement>("#u2revealConfirm")!;
    w.innerHTML = `<div class="u2-confirm danger"><span>ยังไม่ได้คัดลอกรหัสผ่าน — ปิดแล้วดูอีกไม่ได้นะคะ</span><div class="acts"><button class="u2-btn u2-ghost u2-sm" data-c="back">กลับไปคัดลอก</button><button class="u2-btn u2-danger u2-sm" data-c="close">ปิดเลย</button></div></div>`;
    w.onclick = (e) => { const c = (e.target as HTMLElement).closest("[data-c]")?.getAttribute("data-c"); if (c === "back") w.innerHTML = ""; if (c === "close") closeDrawer(true); };
  });
}

// ───────── โหลด/รีโหลดข้อมูล ─────────
async function reload() {
  const res = await fetchAdminUsers();
  if (!overlay) return;
  if (res.ok) {
    users = (res.users || []).map(toUUser);
    teams = res.teams || []; TEAMS = teams.map((t) => t.name);
    ME = res.me || ME;
  }
  renderRoleFilter(); populateTeamFilter(); render();
}

// ───────── wire static shell ─────────
function wireStatic() {
  qs("#u2closeBtn")!.addEventListener("click", closeModal);
  qs("#u2newBtn")!.addEventListener("click", () => { if (dirty) { closeDrawer(); return; } openCreate(); });
  qs("#u2roleList")!.addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest(".u2-frow") as HTMLElement | null; if (!b) return;
    const r = b.dataset.r || ""; F.roles.has(r) ? F.roles.delete(r) : F.roles.add(r); renderRoleFilter(); render();
  });
  qs("#u2roleReset")!.addEventListener("click", () => { F.roles.clear(); renderRoleFilter(); render(); });
  qs("#u2segStatus")!.addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest("button") as HTMLElement | null; if (!b) return;
    F.status = b.dataset.v || "all"; qs("#u2segStatus")!.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === b)); render();
  });
  qs<HTMLSelectElement>("#u2teamFilter")!.addEventListener("change", (e) => { F.team = (e.target as HTMLSelectElement).value; render(); });
  qs<HTMLInputElement>("#u2lineOnly")!.addEventListener("change", (e) => { F.lineOnly = (e.target as HTMLInputElement).checked; render(); });
  qs<HTMLSelectElement>("#u2sortSel")!.addEventListener("change", (e) => { sort = (e.target as HTMLSelectElement).value; render(); });
  const qInput = qs<HTMLInputElement>("#u2q")!;
  qInput.addEventListener("input", () => { F.q = qInput.value.trim().toLowerCase(); qs("#u2searchBox")!.classList.toggle("has-q", !!F.q); render(); });
  qs("#u2qClear")!.addEventListener("click", () => { qInput.value = ""; qInput.dispatchEvent(new Event("input")); qInput.focus(); });

  qs("#u2list")!.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    if (t.closest("[data-clear]")) { clearFilters(); return; }
    const r = t.closest(".u2-row") as HTMLElement | null; if (r) openEdit(r.dataset.id!);
  });
  qs("#u2list")!.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") { const r = (e.target as HTMLElement).closest(".u2-row") as HTMLElement | null; if (r) openEdit(r.dataset.id!); }
  });
  qs("#u2activeChips")!.addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest("button") as HTMLElement | null; if (!b) return;
    const k = b.dataset.k || "";
    if (k === "__all") { clearFilters(); return; }
    if (k === "q") { qInput.value = ""; F.q = ""; qs("#u2searchBox")!.classList.remove("has-q"); }
    else if (k === "status") { F.status = "all"; qs("#u2segStatus")!.querySelectorAll("button").forEach((x) => x.classList.toggle("on", (x as HTMLElement).dataset.v === "all")); }
    else if (k.startsWith("role:")) { F.roles.delete(k.slice(5)); renderRoleFilter(); }
    else if (k === "team") { F.team = ""; qs<HTMLSelectElement>("#u2teamFilter")!.value = ""; }
    else if (k === "line") { F.lineOnly = false; qs<HTMLInputElement>("#u2lineOnly")!.checked = false; }
    render();
  });
}

// ───────── keydown (global · guard ด้วย overlay) ─────────
function onKey(e: KeyboardEvent) {
  if (!overlay) return;
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test((document.activeElement as HTMLElement)?.tagName || "");
  const qInput = qs<HTMLInputElement>("#u2q");
  if (e.key === "Escape") {
    e.preventDefault();
    if (typing && document.activeElement === qInput && qInput!.value) { qs<HTMLButtonElement>("#u2qClear")!.click(); return; }
    if (qs("#u2mBody")!.classList.contains("u2-dopen")) closeDrawer(); else closeModal();
  } else if (e.key === "/" && !typing) { e.preventDefault(); qInput!.focus(); qInput!.select(); }
  else if ((e.key === "n" || e.key === "N" || e.key === "ื") && !typing) { e.preventDefault(); qs<HTMLButtonElement>("#u2newBtn")!.click(); }
}

// ───────── open/close modal ─────────
function closeModal() {
  if (dirty) { closeDrawer(); return; }
  const o = overlay; if (!o) return;
  o.classList.remove("open");
  document.body.classList.remove("umopen");
  document.removeEventListener("keydown", onKey);
  overlay = null;
  resetState();
  setTimeout(() => o.remove(), 260);
}
function resetState() {
  F.q = ""; F.status = "all"; F.roles.clear(); F.team = ""; F.lineOnly = false;
  sort = "role"; selectedId = null; drawerMode = null; dirty = false; busy = false;
}

/** เปิด modal จัดการผู้ใช้ (เรียกจาก EDITH) */
export async function openUserModal(toast: (msg: string, ok?: boolean) => void) {
  if (overlay) return;
  toastFn = toast;
  resetState();
  overlay = document.createElement("div");
  overlay.className = "u2-overlay";
  overlay.innerHTML = SHELL;
  document.body.append(overlay);
  document.body.classList.add("umopen");
  wireStatic();
  document.addEventListener("keydown", onKey);
  // คลิกฉากหลังไม่ปิด (boss สั่ง: ปิดจากปุ่ม/Esc เท่านั้น) — ต่างจาก mock ที่คลิกนอกแล้วปิด
  requestAnimationFrame(() => overlay?.classList.add("open"));
  setTimeout(() => (qs<HTMLInputElement>("#u2q"))?.focus(), 300);

  const res = await fetchAdminUsers();
  if (!overlay) return;
  if (!res.ok) {
    const listEl = qs("#u2list");
    if (listEl) listEl.innerHTML = `<div class="u2-empty"><span class="u2-glyph">${I.warn}</span><b>${res.authorized === false ? "session หมดอายุ" : "โหลดรายชื่อผู้ใช้ไม่ได้"}</b></div>`;
    return;
  }
  users = (res.users || []).map(toUUser);
  teams = res.teams || []; TEAMS = teams.map((t) => t.name);
  ME = res.me || "";
  renderRoleFilter(); populateTeamFilter(); render();
}

/** บังคับปิด/ล้าง (เรียกตอน renderEdith เข้าใหม่) */
export function resetUserModal() {
  overlay?.remove(); overlay = null;
  document.body.classList.remove("umopen");
  document.removeEventListener("keydown", onKey);
  resetState();
}
