import { SUPABASE_URL, ANON_KEY, FUNCTIONS_URL } from "./config";
import { getToken } from "./session";
import type { OrdersResponse } from "./types";

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

export interface MonthsResponse { authorized: boolean; months?: string[]; }

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

// ---- auth: Edge Function ----
export interface AuthResp {
  ok: boolean; message?: string;
  ticket_id?: string; display_name?: string; session_token?: string;
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
