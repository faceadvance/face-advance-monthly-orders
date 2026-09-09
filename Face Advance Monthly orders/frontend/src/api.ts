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

export interface MonthsResponse { authorized: boolean; idle_minutes?: number; role?: string; months?: string[]; months_error?: string[]; months_done?: string[]; }

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
// ---- Stage 8: บันทึกตีกลับ ----
export interface ReturnOrder {
  id: number; order_no: string | null; customer_name: string; phone: string;
  total_sales: number; items: string; carrier: string;
  delivery_status: string; payment_status: string; payment_method: string;
  ordered_date: string; seller_code: string | null; seller_name: string | null;
}
export interface LookupResp { authorized: boolean; ok?: boolean; error?: string; order?: ReturnOrder }
export interface SaveReturnsResp {
  authorized: boolean; ok?: boolean; error?: string; inserted?: number;
  problems?: { row: number; tracking: string; reason: string }[];
  conflicts?: { row: number; tracking: string; with: string }[];
}
export interface ReturnRowPayload {
  tracking_out: string; tracking_return?: string; inspection_result: string;
  damage_detail?: string; photo_url?: string; no_deduct: boolean;
}

export interface ReturnsStats {
  authorized: boolean; ok?: boolean; error?: string;
  cycle_label?: string; cycle_short?: string; cycle_range?: string;
  deduct?: number; no_deduct?: number;
}
export function fetchReturnsStats(): Promise<ReturnsStats> {
  return restRpc<ReturnsStats>("app_returns_stats", { p_token: getToken() });
}
export interface ReturnsSignal { authorized: boolean; ok?: boolean; count?: number }
export function fetchReturnsSignal(): Promise<ReturnsSignal> {
  return restRpc<ReturnsSignal>("app_returns_signal", { p_token: getToken() });
}
export interface NotifItem { at: string; by_name: string; n: number; trackings: string }
export interface NotifResp { authorized: boolean; ok?: boolean; items?: NotifItem[] }
export function fetchNotifications(): Promise<NotifResp> {
  return restRpc<NotifResp>("app_notifications", { p_token: getToken() });
}

// ---- Stage 9: หน้ารายการตีกลับ ----
export interface ReturnListRow {
  id: number;
  ordered_at: string; return_date: string | null;
  order_no: string | null; customer_name: string | null; phone: string | null; address: string | null;
  seller_code: string | null; seller_name: string | null; team_name: string | null;
  carrier: string | null; total_sales: number;
  payment_method: string | null; payment_status: string | null; delivery_status: string | null; return_arrived: boolean;
  items: string | null;
  inspection_result: string | null; tracking_return: string | null; tracking_out: string | null;
  no_deduct: boolean; has_recon: boolean;
}
export interface ReturnCycleOpt { value: string; label: string; range: string; }
export interface ReturnTeamOpt { id: number; name: string; }
export interface ReturnSellerOpt { code: string; name: string | null; team_id: number | null; }
export interface ReturnsListResp {
  authorized: boolean; ok?: boolean; error?: string;
  role?: string; all_teams?: boolean; mode?: string;
  cycle?: ReturnCycleOpt; cycles?: ReturnCycleOpt[];
  teams?: ReturnTeamOpt[]; sellers?: ReturnSellerOpt[];
  stats?: { orders: number; sales: number };
  prev?: { orders: number; sales: number };
  rows?: ReturnListRow[];
}
export function fetchReturnsList(
  cycle: string | null, mode: string, teamId: number | null, sellerCode: string | null,
): Promise<ReturnsListResp> {
  return restRpc<ReturnsListResp>("app_returns_list", {
    p_token: getToken(), p_cycle: cycle, p_mode: mode, p_team_id: teamId, p_seller_code: sellerCode,
  });
}

export function lookupReturnTracking(tracking: string): Promise<LookupResp> {
  return restRpc<LookupResp>("app_lookup_return_tracking", { p_token: getToken(), p_tracking: tracking });
}
export interface PhotoCheckResp { authorized: boolean; ok?: boolean; exists?: boolean; error?: string }
export function checkReturnPhoto(photo: string): Promise<PhotoCheckResp> {
  return restRpc<PhotoCheckResp>("app_check_return_photo", { p_token: getToken(), p_photo: photo });
}
export function saveReturns(rows: ReturnRowPayload[]): Promise<SaveReturnsResp> {
  return restRpc<SaveReturnsResp>("app_save_returns", { p_token: getToken(), p_rows: rows });
}

// ---- Stage 9b: EDITH — ศูนย์รวมปัญหาทั้งระบบ (Adm only) ----
export type EdithIssueType = "error" | "conflict" | "recon" | "dedup";
export interface EdithIssue {
  type: EdithIssueType; ref: number; key: string; severity: string;
  opened_at: string; age_minutes: number; summary: string;
  extra: Record<string, unknown>;
}
export interface EdithCounts { error: number; conflict: number; recon: number; dedup: number; total: number; }
export interface EdithIssuesResp {
  authorized: boolean; ok?: boolean; error?: string;
  issues?: EdithIssue[]; counts?: EdithCounts;
}
export function fetchEdithIssues(): Promise<EdithIssuesResp> {
  return restRpc<EdithIssuesResp>("app_edith_issues", { p_token: getToken() });
}

export interface EdithDetailResp {
  authorized: boolean; ok?: boolean; error?: string;
  order?: Record<string, unknown>;
  conflict?: Record<string, unknown>;
  review?: Record<string, unknown>;
}
export function fetchEdithDetail(type: EdithIssueType, ref: number): Promise<EdithDetailResp> {
  const fn = type === "error" ? "app_edith_error_detail"
    : type === "conflict" ? "app_edith_conflict_detail"
    : type === "recon" ? "app_edith_recon_detail"
    : "app_edith_dedup_detail";
  const arg = type === "conflict" ? { p_conflict_id: ref }
    : type === "dedup" ? { p_review_id: ref }
    : { p_order_id: ref };
  return restRpc<EdithDetailResp>(fn, { p_token: getToken(), ...arg });
}

export interface EdithActionResp {
  authorized: boolean; ok?: boolean; error?: string;
  payment_status?: string; delivery_status?: string;
  kind?: string; deleted?: Record<string, unknown>;
}
export function edithFixCod(orderId: number, newAmount: number): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_fix_cod_amount", { p_token: getToken(), p_order_id: orderId, p_new_amount: newAmount });
}
// แก้ Error โดยเลือกว่าใช้ค่าไหน: "order"=ยึดยอดออเดอร์ · "received"=ยึดยอดรับเงิน (ระบบปรับอีกฝั่ง)
export function edithResolveError(orderId: number, use: "order" | "received"): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_resolve_error", { p_token: getToken(), p_order_id: orderId, p_use: use });
}
// เปลี่ยนสถานะชำระด้วยตนเอง (เผื่อเคสไม่มี COD record / override)
export function edithSetPaymentStatus(orderId: number, status: string): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_set_payment_status", { p_token: getToken(), p_order_id: orderId, p_status: status });
}

// ---- จัดการผู้ใช้ (Adm only · อยู่ใน EDITH) ----
export interface AdminUser {
  id: string; username: string; display_name: string | null; role: string;
  is_active: boolean; all_teams: boolean; idle_minutes: number; session_hours: number;
  has_line: boolean; line_user_id: string | null; teams: string[];
  created_at: string | null; last_seen_at: string | null;
}
export interface AdminTeam { id: number; name: string; is_active: boolean; }
export interface AdminUsersResp {
  authorized: boolean; ok?: boolean; error?: string; me?: string;
  users?: AdminUser[]; teams?: AdminTeam[];
}
export function fetchAdminUsers(): Promise<AdminUsersResp> {
  return restRpc<AdminUsersResp>("app_admin_list_users", { p_token: getToken() });
}
export interface AdminActionResp { authorized: boolean; ok?: boolean; error?: string; user_id?: string; username?: string; password?: string; }
export function adminCreateUser(u: { username: string; display_name: string; role: string; all_teams: boolean; team_ids: number[]; idle_minutes: number; session_hours: number; line_user_id: string; }): Promise<AdminActionResp> {
  return restRpc<AdminActionResp>("app_admin_create_user", {
    p_token: getToken(), p_username: u.username, p_display_name: u.display_name, p_role: u.role,
    p_all_teams: u.all_teams, p_team_ids: u.team_ids, p_idle_minutes: u.idle_minutes, p_session_hours: u.session_hours, p_line_user_id: u.line_user_id });
}
export function adminUpdateUser(id: string, u: { display_name: string; role: string; all_teams: boolean; team_ids: number[]; is_active: boolean; idle_minutes: number; session_hours: number; line_user_id: string; }): Promise<AdminActionResp> {
  return restRpc<AdminActionResp>("app_admin_update_user", {
    p_token: getToken(), p_user_id: id, p_display_name: u.display_name, p_role: u.role,
    p_all_teams: u.all_teams, p_team_ids: u.team_ids, p_is_active: u.is_active, p_idle_minutes: u.idle_minutes, p_session_hours: u.session_hours, p_line_user_id: u.line_user_id });
}
export function adminResetPassword(id: string, newPassword: string): Promise<AdminActionResp> {
  return restRpc<AdminActionResp>("app_admin_reset_password", { p_token: getToken(), p_user_id: id, p_new_password: newPassword });
}
export function edithDeleteRecon(kind: "cod" | "return", orderId: number): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_delete_recon", { p_token: getToken(), p_kind: kind, p_order_id: orderId });
}
export function edithRestoreRecon(kind: "cod" | "return", payload: Record<string, unknown>): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_restore_recon", { p_token: getToken(), p_kind: kind, p_payload: payload });
}
export function edithResolveConflict(conflictId: number, chosenIdx: number): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_resolve_conflict", { p_token: getToken(), p_conflict_id: conflictId, p_chosen_idx: chosenIdx });
}
export function edithMerge(keep: number, dup: number): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_merge_customers", { p_token: getToken(), p_keep: keep, p_dup: dup });
}
export function edithDismissDup(a: number, b: number): Promise<EdithActionResp> {
  return restRpc<EdithActionResp>("app_edith_dismiss_dup", { p_token: getToken(), p_a: a, p_b: b });
}

export interface EdithLogRow {
  id: number; username: string; event: string;
  detail: Record<string, unknown> | null; ip: string | null; geo: Record<string, unknown> | null; at: string;
}
export interface EdithLogResp {
  authorized: boolean; ok?: boolean; error?: string;
  rows?: EdithLogRow[]; total?: number; users?: string[]; events?: string[];
}
export function fetchEdithLog(filter: Record<string, unknown> = {}): Promise<EdithLogResp> {
  return restRpc<EdithLogResp>("app_edith_log", { p_token: getToken(), p_filter: filter });
}

// ---- Stage 9c: หน้าค้นหา (global search · ข้ามรอบเดือน · ตามสิทธิ์) ----
export interface SearchRow {
  id: number;
  ordered_at: string; return_date?: string | null;
  order_no: string | null; customer_name: string | null; phone: string | null; address: string | null;
  seller_code: string | null; seller_name: string | null; team_name: string | null;
  carrier: string | null; total_sales: number;
  payment_method: string | null; payment_status: string | null; delivery_status: string | null; return_arrived: boolean;
  tracking_out: string | null; items: string | null; note?: string | null;
  inspection_result?: string | null; tracking_return?: string | null; no_deduct?: boolean; has_recon?: boolean;
  cycle_label?: string; cycle_value?: string;
  matched_fields: string[];
}
export interface SearchResp {
  authorized: boolean; ok?: boolean; error?: string;
  view?: "order" | "deduct"; query?: string; too_short?: boolean;
  rows?: SearchRow[]; count?: number;
}
export function searchOrders(query: string, view: "order" | "deduct"): Promise<SearchResp> {
  return restRpc<SearchResp>("app_search_orders", { p_token: getToken(), p_query: query, p_view: view });
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
