// ---------------------------------------------------------------
//  ตรวจเวอร์ชั่นแอป — กันพนักงานใช้โค้ดเก่าค้างหลังมีการ deploy
//  เวอร์ชั่นที่โหลดมา = __APP_VERSION__ (ฝังตอน build · git commit hash)
//  เวอร์ชั่นบนเซิร์ฟเวอร์ = version.json (ไฟล์จิ๋ว ~20 bytes · no-store)
//  เจอไม่ตรง → บล็อกการบันทึก + popup ให้รีเฟรช (ร่างที่กรอกไว้กู้คืนได้)
// ---------------------------------------------------------------
declare const __APP_VERSION__: string;

export const APP_VERSION = __APP_VERSION__;

const CHECK_EVERY_MS = 5 * 60 * 1000;   // เช็คทุก 5 นาที (ข้ามถ้าแท็บอยู่เบื้องหลัง)
const MIN_GAP_MS = 30 * 1000;           // กันยิงถี่: เช็คไปแล้วไม่เกิน 30 วิ → ใช้ผลเดิม

let lastCheckAt = 0;
let serverVersion: string | null = null;   // เวอร์ชั่นล่าสุดที่อ่านได้จากเซิร์ฟเวอร์
let inflight: Promise<string | null> | null = null;
let modalShown = false;

/** ดึงเวอร์ชั่นจากเซิร์ฟเวอร์ (คืน null ถ้าอ่านไม่ได้ — เน็ตหลุด/ไฟล์หาย ⇒ ถือว่าไม่ stale) */
async function fetchServerVersion(): Promise<string | null> {
  if (inflight) return inflight;
  const url = new URL("version.json", document.baseURI);
  url.searchParams.set("t", String(Date.now()));   // กัน cache ของ CDN/เบราว์เซอร์
  inflight = fetch(url.toString(), { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : null))
    .then((j: { v?: string } | null) => {
      const v = j && typeof j.v === "string" ? j.v : null;
      if (v) { serverVersion = v; lastCheckAt = Date.now(); }
      return v;
    })
    .catch(() => null)
    .finally(() => { inflight = null; });
  return inflight;
}

/** เวอร์ชั่นบนเซิร์ฟเวอร์ใหม่กว่าที่โหลดมาไหม
 *  force=false → ถ้าเช็คไปแล้วไม่เกิน 30 วิ ใช้ผลเดิม (เบา ไม่ยิงซ้ำ) */
export async function isStale(force = false): Promise<boolean> {
  if (APP_VERSION === "dev") return false;   // ตอน dev ไม่ต้องกวน
  if (!force && Date.now() - lastCheckAt < MIN_GAP_MS && serverVersion) {
    return serverVersion !== APP_VERSION;
  }
  const v = await fetchServerVersion();
  return v != null && v !== APP_VERSION;
}

/** รีเฟรชเงียบๆ (ไม่ต้องถาม) — ใช้ตอนไม่มีงานค้าง เช่น session หลุด / หลังล็อกอิน */
export function reloadForUpdate() { location.reload(); }

/** popup บล็อก: ปิดไม่ได้ (ไม่มี × · คลิกนอกไม่ปิด · Esc ไม่ปิด) → ปุ่มเดียว "ตกลง" = รีเฟรช */
export function showUpdateModal(note?: string) {
  if (modalShown) return;
  modalShown = true;
  const ov = document.createElement("div");
  ov.className = "modal-ov vupd-ov";
  ov.innerHTML = `
    <div class="modal vupd" role="alertdialog" aria-modal="true">
      <div class="vupd-body">
        <span class="vupd-ic"><svg class="ic" viewBox="0 0 24 24"><use href="#i-refresh"></use></svg></span>
        <div class="vupd-txt">
          <div class="vupd-t">ระบบมีการอัปเดต</div>
          <div class="vupd-d">กรุณารีเฟรชระบบก่อนใช้งานต่อ${note ? ` — ${note}` : ""}</div>
          <div class="vupd-v">เวอร์ชั่นที่เปิดอยู่ <b>${APP_VERSION}</b> → ใหม่ <b>${serverVersion ?? "?"}</b></div>
        </div>
      </div>
      <div class="vupd-foot"><button type="button" class="fbtn p vupd-ok">ตกลง</button></div>
    </div>`;
  ov.addEventListener("click", (e) => e.stopPropagation());   // คลิกฉากหลังไม่ปิด
  document.body.append(ov);
  const ok = ov.querySelector(".vupd-ok") as HTMLButtonElement;
  ok.addEventListener("click", () => { ok.disabled = true; ok.textContent = "กำลังรีเฟรช…"; reloadForUpdate(); });
  ok.focus();
  // กัน Esc / Tab หลุดออกจาก modal
  ov.addEventListener("keydown", (e) => { if (e.key === "Escape") e.preventDefault(); });
}

/** เรียกก่อน "บันทึก" ทุกจุด — true = ไปต่อได้ · false = โค้ดเก่า (บล็อก + เด้ง popup แล้ว)
 *  onStale: ให้ผู้เรียกเซฟร่าง/จำสิ่งที่ค้างไว้ก่อนรีเฟรช */
export async function guardSaveVersion(onStale?: () => void): Promise<boolean> {
  if (!(await isStale())) return true;
  try { onStale?.(); } catch { /* เซฟร่างไม่ได้ก็ต้องเด้งเตือนอยู่ดี */ }
  showUpdateModal("ข้อมูลที่กรอกไว้ถูกเก็บให้แล้ว");
  return false;
}

/** เริ่มเฝ้า: ทุก 5 นาที (ข้ามตอนแท็บเบื้องหลัง) + ตอนกลับมาโฟกัสแท็บ
 *  onStale = สิ่งที่จะทำเมื่อเจอเวอร์ชั่นใหม่ตอนกำลังใช้งาน (ปกติ = เด้ง popup) */
export function startVersionWatch(onStale: () => void) {
  if (APP_VERSION === "dev") return;
  const tick = async () => { if (await isStale()) onStale(); };
  window.setInterval(() => { if (!document.hidden) void tick(); }, CHECK_EVERY_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) void tick(); });
}
