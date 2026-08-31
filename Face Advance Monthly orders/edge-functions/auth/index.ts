// Edge Function `auth` — login / verify-otp / logout (custom auth, verify_jwt=false)
// เรียก RPC ด้วย service role · ส่ง OTP เป็น LINE Flex เข้ากลุ่ม · geo + parse UA
// env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto) · LINE_CHANNEL_TOKEN, LINE_GROUP_ID (ตั้งเอง)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const URL = Deno.env.get("SUPABASE_URL")!;
const SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const LINE_TOKEN = Deno.env.get("LINE_CHANNEL_TOKEN") ?? "";
const LINE_GROUP = Deno.env.get("LINE_GROUP_ID") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

async function rpc(fn: string, args: Record<string, unknown>): Promise<any> {
  const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`rpc ${fn} ${r.status}: ${await r.text()}`);
  const txt = await r.text();
  return txt ? JSON.parse(txt) : null;
}

function parseUA(ua: string): string {
  let b = "ไม่ทราบ", os = "ไม่ทราบ";
  if (/edg/i.test(ua)) b = "Edge";
  else if (/chrome|crios/i.test(ua)) b = "Chrome";
  else if (/firefox|fxios/i.test(ua)) b = "Firefox";
  else if (/safari/i.test(ua)) b = "Safari";
  if (/windows/i.test(ua)) os = "Windows";
  else if (/mac os|macintosh/i.test(ua)) os = "macOS";
  else if (/android/i.test(ua)) os = "Android";
  else if (/iphone|ipad|ipod|ios/i.test(ua)) os = "iOS";
  else if (/linux/i.test(ua)) os = "Linux";
  return `${b} · ${os}`;
}

function isPrivate(ip: string): boolean {
  return !ip || /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1|fc|fd|localhost)/i.test(ip);
}

async function lookupGeo(ip: string): Promise<Record<string, unknown>> {
  if (isPrivate(ip)) return { local: true, city: null, region: null, country: null };
  try {
    const r = await fetch(`https://ipwho.is/${ip}`, { signal: AbortSignal.timeout(4000) });
    const j = await r.json();
    if (j && j.success) return { city: j.city ?? null, region: j.region ?? null, country: j.country ?? null, isp: j?.connection?.isp ?? null };
  } catch { /* ignore */ }
  return { city: null, region: null, country: null };
}

function bkk(): Date {
  return new Date(new Date().toLocaleString("en-US", { timeZone: "Asia/Bangkok" }));
}
function whenText(): string {
  const d = bkk();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getDate())}/${d.getMonth() + 1}/${d.getFullYear()} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function refStamp(username: string): string {
  const d = bkk();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${username}-${p(d.getFullYear() % 100)}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}-LOGIN`;
}

function locText(ip: string, geo: any): string {
  if (geo?.local) return "ในเครื่อง (local)";
  const parts = [geo?.city, geo?.region].filter(Boolean) as string[];
  const place = [...new Set(parts)].join(" "); // dedupe "Bangkok Bangkok" → "Bangkok"
  return [ip || "—", place].filter(Boolean).join(" · ");
}

function kv(k: string, v: string, color = "#E6ECF5") {
  return {
    type: "box", layout: "horizontal", contents: [
      { type: "text", text: k, color: "#7C8AA3", size: "sm", weight: "bold", flex: 4 },
      { type: "text", text: v || "—", color, size: "sm", weight: "bold", align: "end", flex: 6, wrap: true },
    ],
  };
}

function buildFlex(otp: string, username: string, device: string, loc: string, when: string, ref: string) {
  return {
    type: "flex",
    altText: `OTP เข้าสู่ระบบ Face Advance: ${otp}`,
    contents: {
      type: "bubble", size: "kilo",
      body: {
        type: "box", layout: "vertical", backgroundColor: "#0F1826", paddingAll: "15px", contents: [
          { type: "box", layout: "horizontal", contents: [
            { type: "text", text: "แจ้งเตือนความปลอดภัย", color: "#F59E0B", size: "xxs", weight: "bold", flex: 1 },
            { type: "text", text: "ต้องดำเนินการ", color: "#F87171", size: "xxs", weight: "bold", align: "end" },
          ] },
          { type: "text", text: "OTP เข้าสู่ระบบ", color: "#FFFFFF", size: "lg", weight: "bold", margin: "sm" },
          { type: "separator", margin: "lg", color: "#25344A" },
          { type: "box", layout: "vertical", margin: "lg", spacing: "sm", contents: [
            kv("ผู้ใช้", username, "#5AA9FF"),
            kv("อุปกรณ์", device),
            kv("ตำแหน่ง (IP)", loc),
            kv("เวลา", when),
          ] },
          { type: "text", text: "รหัสผ่านชั่วคราว (หมดอายุใน 5 นาที)", color: "#8595AE", size: "xs", align: "center", margin: "lg" },
          { type: "text", text: otp, color: "#22D3A5", size: "3xl", weight: "bold", align: "center", margin: "md", adjustMode: "shrink-to-fit" },
          { type: "text", text: `Ref: ${ref}`, color: "#5E6B82", size: "xxs", align: "center", margin: "md", wrap: true },
        ],
      },
      footer: {
        type: "box", layout: "vertical", backgroundColor: "#0F1826", paddingAll: "lg", paddingTop: "none", contents: [
          { type: "button", style: "primary", color: "#2F6BFF", height: "md",
            action: { type: "clipboard", label: "คัดลอก OTP", clipboardText: otp } },
        ],
      },
      styles: { body: { backgroundColor: "#0F1826" }, footer: { backgroundColor: "#0F1826" } },
    },
  };
}

async function sendOtpFlex(otp: string, username: string, ip: string, geo: any, device: string): Promise<boolean> {
  if (!LINE_TOKEN || !LINE_GROUP) return false;
  const flex = buildFlex(otp, username, device, locText(ip, geo), whenText(), refStamp(username));
  const r = await fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST",
    headers: { Authorization: `Bearer ${LINE_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ to: LINE_GROUP, messages: [flex] }),
  });
  if (!r.ok) { console.error("LINE push failed", r.status, await r.text()); return false; }
  return true;
}

async function doLogin(b: any, ip: string, ua: string): Promise<Response> {
  if (!b.username || !b.password) return json({ ok: false, message: "กรอกข้อมูลไม่ครบ" });
  const rows = await rpc("app_auth_login", { p_username: b.username, p_password: b.password, p_ip: ip, p_ua: ua });
  if (!rows || rows.length === 0) return json({ ok: false, message: "ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง (หรือขอรหัสถี่เกินไป)" });
  const { ticket_id, otp, display_name } = rows[0];
  const geo = await lookupGeo(ip);
  const sent = await sendOtpFlex(otp, b.username, ip, geo, parseUA(ua));
  if (!sent) return json({ ok: false, message: "ส่ง OTP เข้า LINE ไม่สำเร็จ ลองใหม่อีกครั้ง" });
  return json({ ok: true, ticket_id, display_name });
}

async function doVerify(b: any, ip: string, ua: string): Promise<Response> {
  if (!b.ticket_id || !b.code) return json({ ok: false, message: "กรอกรหัสไม่ครบ" });
  const geo = await lookupGeo(ip);
  const rows = await rpc("app_auth_verify", { p_ticket: b.ticket_id, p_code: String(b.code), p_ip: ip, p_ua: ua, p_geo: geo });
  if (!rows || rows.length === 0) return json({ ok: false, message: "รหัส OTP ไม่ถูกต้องหรือหมดอายุ" });
  return json({ ok: true, session_token: rows[0].session_token, display_name: rows[0].display_name });
}

async function doLogout(b: any): Promise<Response> {
  if (b.token) { try { await rpc("app_auth_logout", { p_token: b.token }); } catch { /* ignore */ } }
  return json({ ok: true });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  try {
    const b = await req.json();
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
    const ua = req.headers.get("user-agent") ?? "";
    if (b.action === "login") return await doLogin(b, ip, ua);
    if (b.action === "verify") return await doVerify(b, ip, ua);
    if (b.action === "logout") return await doLogout(b);
    return json({ ok: false, error: "unknown action" }, 400);
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: "server" }, 500);
  }
});
