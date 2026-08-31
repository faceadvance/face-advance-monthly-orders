import { el, icon } from "./util";
import { authLogin, authVerify } from "./api";
import { setSession } from "./session";

const $ = <T extends HTMLElement>(s: string) => document.querySelector(s) as T;

/** แสดงหน้า login (ครอบทั้งจอ) · เรียก onSuccess เมื่อ login+OTP ผ่าน */
export function renderLogin(onSuccess: () => void) {
  document.body.classList.remove("authed");
  const root = $("#authRoot");
  // ก้อนแสงเคลื่อนที่ (aurora) — สร้างครั้งเดียว
  if (!root.querySelector(".login-glow")) {
    root.append(el("div", { class: "login-glow glow-blue" }), el("div", { class: "login-glow glow-gold" }));
  }
  // อนุภาคลอย (สร้างครั้งเดียว, ไม่ถูกลบตอนสลับ step)
  if (!root.querySelector(".login-particles")) {
    const p = el("div", { class: "login-particles" });
    for (let i = 0; i < 42; i++) {
      const s = (Math.random() * 2.4 + 1).toFixed(1);
      const dur = (9 + Math.random() * 15).toFixed(1);
      const delay = (Math.random() * -22).toFixed(1);
      const o = (Math.random() * 0.5 + 0.2).toFixed(2);
      p.append(el("span", { class: "login-dot",
        style: `width:${s}px;height:${s}px;left:${(Math.random() * 100).toFixed(1)}%;--o:${o};opacity:${o};animation-duration:${dur}s;animation-delay:${delay}s` }));
    }
    root.append(p);
  }
  root.querySelector(".authcard")?.remove();

  // เก็บระหว่าง flow (ไม่ persist)
  let username = "";
  let password = "";
  let ticketId = "";

  function brand(sub?: string) {
    const b = el("div", { class: "authbrand" },
      el("img", { class: "authlogo", src: "fmark.png", alt: "F", width: "62", height: "60" }),
      el("div", { class: "authbname" }, "Face Advance"));
    if (sub) b.append(el("div", { class: "authtag" }, sub));
    return b;
  }
  function errBox(): HTMLElement {
    const e = el("div", { class: "autherr" }, icon("i-close"), el("span", {}));
    e.hidden = true;
    return e;
  }
  function showErr(box: HTMLElement, msg: string) {
    (box.querySelector("span") as HTMLElement).textContent = msg;
    box.hidden = false;
  }

  // ---------- STEP 1: username + password ----------
  function step1() {
    root.querySelector(".authcard")?.remove();
    const card = el("div", { class: "authcard" });
    const err = errBox();
    const uInput = el("input", { autocomplete: "username", value: username }) as HTMLInputElement;
    const pInput = el("input", { type: "password", autocomplete: "current-password" }) as HTMLInputElement;

    const eye = icon("i-eye"); eye.classList.add("autheye");
    eye.addEventListener("click", () => {
      pInput.type = pInput.type === "password" ? "text" : "password";
    });

    const btn = el("button", { class: "btn authbtn" }, icon("i-login"), "เข้าสู่ระบบ") as HTMLButtonElement;

    async function submit() {
      username = uInput.value.trim();
      password = pInput.value;
      if (!username || !password) { showErr(err, "กรอกชื่อผู้ใช้และรหัสผ่าน"); return; }
      err.hidden = true;
      btn.disabled = true; btn.textContent = ""; btn.append(spinner(), "กำลังส่ง OTP...");
      const r = await authLogin(username, password);
      btn.disabled = false;
      if (!r.ok) {
        btn.textContent = ""; btn.append(icon("i-login"), "เข้าสู่ระบบ");
        showErr(err, r.message || "เข้าสู่ระบบไม่สำเร็จ");
        return;
      }
      ticketId = r.ticket_id!;
      step2();
    }
    btn.addEventListener("click", submit);
    pInput.addEventListener("keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") submit(); });

    card.append(
      brand("ระบบจัดการออเดอร์"),
      el("div", { class: "authtitle" }, "เข้าสู่ระบบ"),
      el("div", { class: "authsub" }, "สำหรับพนักงานที่ได้รับสิทธิ์เท่านั้น"),
      err,
      field("ชื่อผู้ใช้ (username)", el("div", { class: "authinp" }, icon("i-user"), uInput)),
      field("รหัสผ่าน", el("div", { class: "authinp" }, icon("i-lock"), pInput, eye)),
      btn,
      el("div", { class: "authnote" }, iconGreen("i-shield"), "ยืนยันตัวตน 2 ชั้นด้วย OTP ผ่าน LINE"),
    );
    root.append(card);
    uInput.focus();
  }

  // ---------- STEP 2: OTP ----------
  function step2() {
    root.querySelector(".authcard")?.remove();
    const card = el("div", { class: "authcard" });
    const err = errBox();
    const boxes: HTMLInputElement[] = [];
    const row = el("div", { class: "otpboxes" });
    for (let i = 0; i < 6; i++) {
      const d = el("input", { class: "otpd", inputmode: "numeric", maxlength: "1" }) as HTMLInputElement;
      boxes.push(d);
      row.append(d);
    }
    const btn = el("button", { class: "btn authbtn", style: "margin-top:1.1rem" }, icon("i-shield"), "ยืนยัน") as HTMLButtonElement;

    function code() { return boxes.map((b) => b.value).join(""); }
    function wireBoxes() {
      boxes.forEach((b, i) => {
        b.addEventListener("input", () => {
          b.value = b.value.replace(/\D/g, "").slice(0, 1);
          if (b.value && i < 5) boxes[i + 1].focus();
          if (code().length === 6) submit();
        });
        b.addEventListener("keydown", (e) => {
          const k = (e as KeyboardEvent).key;
          if (k === "Backspace" && !b.value && i > 0) boxes[i - 1].focus();
        });
        b.addEventListener("paste", (e) => {
          e.preventDefault();
          const t = ((e as ClipboardEvent).clipboardData?.getData("text") || "").replace(/\D/g, "").slice(0, 6);
          t.split("").forEach((c, j) => { if (boxes[j]) boxes[j].value = c; });
          if (t.length === 6) submit();
          else boxes[Math.min(t.length, 5)].focus();
        });
      });
    }

    async function submit() {
      const c = code();
      if (c.length !== 6) { showErr(err, "กรอกรหัส 6 หลักให้ครบ"); return; }
      err.hidden = true;
      btn.disabled = true; btn.textContent = ""; btn.append(spinner(), "กำลังยืนยัน...");
      const r = await authVerify(ticketId, c);
      if (!r.ok) {
        btn.disabled = false; btn.textContent = ""; btn.append(icon("i-shield"), "ยืนยัน");
        showErr(err, r.message || "ยืนยันไม่สำเร็จ");
        boxes.forEach((b) => (b.value = ""));
        boxes[0].focus();
        return;
      }
      setSession(r.session_token!, r.display_name || username);
      onSuccess();
    }
    btn.addEventListener("click", submit);
    wireBoxes();

    // resend / back
    const resend = el("a", {}, "ส่งรหัสใหม่");
    let left = 60;
    const resendWrap = el("div", { class: "authresend" }, "ยังไม่ได้รับรหัส? ", resend);
    resend.classList.add("disabled");
    const tick = window.setInterval(() => {
      left--;
      resend.textContent = left > 0 ? `ส่งรหัสใหม่ (${left})` : "ส่งรหัสใหม่";
      if (left <= 0) { resend.classList.remove("disabled"); window.clearInterval(tick); }
    }, 1000);
    resend.textContent = `ส่งรหัสใหม่ (${left})`;
    resend.addEventListener("click", async () => {
      if (resend.classList.contains("disabled")) return;
      window.clearInterval(tick);
      const r = await authLogin(username, password);
      if (r.ok) { ticketId = r.ticket_id!; step2(); }
      else showErr(err, r.message || "ส่งรหัสใหม่ไม่สำเร็จ");
    });

    const back = el("div", { class: "authback" }, icon("i-back"), "กลับไปหน้าเข้าสู่ระบบ");
    back.addEventListener("click", () => { window.clearInterval(tick); step1(); });

    card.append(
      brand(),
      el("div", { class: "authtitle" }, "ยืนยันตัวตน"),
      el("div", { class: "authsub" }, "กรอกรหัส 6 หลักที่ส่งไปยังกลุ่ม LINE"),
      err,
      row,
      btn,
      resendWrap,
      back,
    );
    root.append(card);
    boxes[0].focus();
  }

  step1();
}

// ---- helpers ----
function field(label: string, control: HTMLElement): HTMLElement {
  return el("div", { class: "authfield" }, el("span", { class: "authlbl" }, label), control);
}
function iconGreen(id: string): SVGSVGElement { const s = icon(id); s.classList.add("g"); return s; }
function spinner(): HTMLElement { return el("span", { class: "authspin" }); }
