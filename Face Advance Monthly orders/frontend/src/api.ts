import { SUPABASE_URL, ANON_KEY, FUNCTIONS_URL } from "./config";
import { getToken } from "./session";
import type { OrdersResponse, TrackingEntry } from "./types";

// ---- data: เรียก RPC ตรงด้วย anon key + session token (RPC ตรวจ token ในตัว) ----
async function restRpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${ANON_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${fn}: HTTP ${res.status}`);
  return res.json() as Promise<T>;
}

export interface MonthsResponse { authorized: boolean; months?: string[]; months_error?: string[]; months_done?: string[]; }

export function fetchMonths(): Promise<MonthsResponse> {
  return restRpc<MonthsResponse>("get_months", { p_token: getToken() });
}
export function fetchOrders(month: string): Promise<OrdersResponse> {
  return restRpc<OrdersResponse>("get_orders", { p_token: getToken(), p_month: month });
}

// ---- import (Stage 2): rows ถูก parse ที่ browser แล้ว → RPC ตรวจ+เขียน ----
export interface ImportResp {
  authorized: boolean;
  ok?: boolean;
  mode?: string;
  error?: string | null;
  problems?: { order_no: string; reason: string }[];
  warnings?: string[];
  orders_total?: number;
  orders_ok?: number;
  items_total?: number;
  total_sales?: number;
  dates?: string[];
  new_customers?: number;
  inserted?: number;
}
export function importOrders(rows: unknown[], mode: "preflight" | "confirm"): Promise<ImportResp> {
  return restRpc<ImportResp>("app_import_orders", { p_token: getToken(), p_rows: rows, p_mode: mode });
}

// ---- import COD รับเงินแล้ว ----
export interface CodProblem { tracking: string; reason: string; }
export interface CodMismatch {
  tracking: string; order_no: string | null; order_id: number;
  order_amount: number; received_amount: number | null; fixable: boolean;
}
export interface CodImportResp {
  authorized: boolean;
  ok?: boolean;
  mode?: string;
  error?: string | null;
  problems?: CodProblem[];
  mismatches?: CodMismatch[];
  rows_total?: number;
  rows_ok?: number;
  inserted?: number;
  fixed?: number;
  paid?: number;
  err?: number;
}
export function importCodPayments(
  rows: unknown[], mode: "preflight" | "confirm",
  fixTrackings: string[] = [], source: string | null = null,
): Promise<CodImportResp> {
  return restRpc<CodImportResp>("app_import_cod_payments", {
    p_token: getToken(), p_rows: rows, p_mode: mode,
    p_fix_trackings: fixTrackings, p_source: source,
  });
}

// อัปโหลดไฟล์หลักฐาน COD → Edge Function (service role) → คืน path เก็บใน source
export interface CodUploadResp { ok: boolean; path?: string; error?: string; }
export async function uploadCodEvidence(file: File): Promise<CodUploadResp> {
  try {
    const fd = new FormData();
    fd.append("token", getToken() ?? "");
    fd.append("file", file);
    // multipart = CORS-safelisted → ไม่ trigger preflight (ไม่ใส่ apikey/authorization header)
    const res = await fetch(`${FUNCTIONS_URL}/cod-upload`, { method: "POST", body: fd });
    return (await res.json()) as CodUploadResp;
  } catch {
    return { ok: false, error: "network" };
  }
}

// ---- tracking (Stage 5): แก้สถานะ + โน้ตติดตาม ----
export interface SaveTrackingArgs {
  delivery_status?: string;
  payment_status?: string;
  return_reason?: string;
  status_detail?: string;
  note?: string;
}
export interface TrackingResp {
  authorized: boolean;
  ok?: boolean;
  noop?: boolean;
  error?: string;
  delivery_status?: string;
  payment_status?: string;
  return_reason?: string;
  status_detail?: string;
  timeline?: TrackingEntry[];
}
export function saveOrderTracking(orderId: number, a: SaveTrackingArgs): Promise<TrackingResp> {
  return restRpc<TrackingResp>("app_save_order_tracking", {
    p_token: getToken(),
    p_order_id: orderId,
    p_delivery_status: a.delivery_status ?? null,
    p_payment_status: a.payment_status ?? null,
    p_return_reason: a.return_reason ?? null,
    p_status_detail: a.status_detail ?? null,
    p_note: a.note ?? null,
  });
}
export interface GetTrackingResp { authorized: boolean; timeline?: TrackingEntry[]; }
export function getOrderTracking(orderId: number): Promise<GetTrackingResp> {
  return restRpc<GetTrackingResp>("app_get_order_tracking", { p_token: getToken(), p_order_id: orderId });
}

// ---- คำ default "รายละเอียดปัญหา" (จาก DB · ชุดกลาง ลบไม่ได้) ----
// คำใหม่ที่พนักงานพิมพ์เอง + ลำดับชิป เก็บที่ localStorage ฝั่ง main.ts
export interface DetailPreset { id: number; label: string; use_count: number; }
export interface PresetsResp { authorized: boolean; ok?: boolean; presets?: DetailPreset[]; }
export function getDetailPresets(kind = "problem"): Promise<PresetsResp> {
  return restRpc<PresetsResp>("app_get_detail_presets", { p_token: getToken(), p_kind: kind });
}

// ---- auth: Edge Function ----
export interface AuthResp {
  ok: boolean; message?: string;
  ticket_id?: string; display_name?: string; session_token?: string; role?: string;
}
async function authFn(body: Record<string, unknown>): Promise<AuthResp> {
  try {
    // Edge Function auth = public (verify_jwt=false) → ส่งแค่ content-type
    // (ไม่ใส่ apikey/authorization เพราะจะ trigger CORS preflight ที่ function ไม่ได้อนุญาต header นั้น)
    const res = await fetch(`${FUNCTIONS_URL}/auth`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return (await res.json()) as AuthResp;
  } catch {
    return { ok: false, message: "เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ ลองใหม่อีกครั้ง" };
  }
}
export function authLogin(username: string, password: string): Promise<AuthResp> {
  return authFn({ action: "login", username, password });
}
export function authVerify(ticket_id: string, code: string): Promise<AuthResp> {
  return authFn({ action: "verify", ticket_id, code });
}
export function authLogout(token: string): Promise<AuthResp> {
  return authFn({ action: "logout", token });
}
