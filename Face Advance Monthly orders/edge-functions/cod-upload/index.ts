// Edge Function `cod-upload` — รับไฟล์หลักฐาน COD (รูป/pdf/excel) → เก็บ Storage (service role)
// verify_jwt=false · ตรวจ session ผ่าน app_session_uid + role=editor · คืน path ไว้เก็บใน recon_cod_payments.source
// env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const URL = Deno.env.get("SUPABASE_URL")!;
const SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "cod-evidence";
const MAX_BYTES = 10 * 1024 * 1024;
// รับหลักฐานทุกชนิด (boss: ไฟล์มีหลายแบบ) — เช็คแค่ไม่ว่าง/ไม่เกินขนาด

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

async function roleOf(uid: string): Promise<string | null> {
  const r = await fetch(`${URL}/rest/v1/app_users?id=eq.${uid}&select=role`, {
    headers: { apikey: SVC, Authorization: `Bearer ${SVC}` },
  });
  if (!r.ok) return null;
  const rows = await r.json();
  return Array.isArray(rows) && rows[0] ? rows[0].role ?? null : null;
}

// ชื่อไฟล์สำหรับ storage key: ต้อง ASCII เท่านั้น (อักษรไทย = InvalidKey) → เก็บนามสกุล ตัดที่เหลือ
function safeName(name: string): string {
  const dot = name.lastIndexOf(".");
  const rawExt = dot >= 0 ? name.slice(dot + 1).toLowerCase().replace(/[^a-z0-9]/g, "") : "";
  const ext = rawExt ? "." + rawExt.slice(0, 8) : "";
  const base = (dot >= 0 ? name.slice(0, dot) : name)
    .replace(/[^a-zA-Z0-9_-]/g, "_").replace(/_+/g, "_").replace(/^_|_$/g, "").slice(0, 50) || "file";
  return base + ext;
}
function ym(): string {
  const d = new Date(new Date().toLocaleString("en-US", { timeZone: "Asia/Bangkok" }));
  return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return json({ ok: false, error: "bad_form" }, 400);
  }
  const token = String(form.get("token") ?? "");
  const file = form.get("file");
  if (!token) return json({ ok: false, error: "no_token" }, 401);
  if (!(file instanceof File)) return json({ ok: false, error: "no_file" }, 400);

  // ตรวจ session + role
  let uid: string | null = null;
  try {
    uid = await rpc("app_session_uid", { p_token: token });
  } catch {
    return json({ ok: false, error: "server" }, 500);
  }
  if (!uid) return json({ ok: false, error: "unauthorized" }, 401);
  const role = await roleOf(uid);
  if (role !== "editor") return json({ ok: false, error: "forbidden_viewer" }, 403);

  // ตรวจไฟล์ — รับทุกชนิด แค่ไม่ว่าง/ไม่เกินขนาด
  if (file.size === 0) return json({ ok: false, error: "empty_file" }, 400);
  if (file.size > MAX_BYTES) return json({ ok: false, error: "too_large" }, 400);

  const path = `${ym()}/${uid}/${Date.now()}-${safeName(file.name)}`;
  const buf = await file.arrayBuffer();
  const up = await fetch(`${URL}/storage/v1/object/${BUCKET}/${encodeURI(path)}`, {
    method: "POST",
    headers: {
      apikey: SVC, Authorization: `Bearer ${SVC}`,
      "Content-Type": file.type || "application/octet-stream", "x-upsert": "false",
    },
    body: buf,
  });
  if (!up.ok) return json({ ok: false, error: "upload_failed", detail: await up.text() }, 502);

  return json({ ok: true, path });
});
