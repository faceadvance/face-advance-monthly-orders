const TOKEN_KEY = "fa_session";
const NAME_KEY = "fa_display";
const ROLE_KEY = "fa_role";

export function getToken(): string { return localStorage.getItem(TOKEN_KEY) ?? ""; }
export function setSession(token: string, displayName: string, role = "editor") {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(NAME_KEY, displayName || "");
  localStorage.setItem(ROLE_KEY, role || "editor");
}
export function clearSession() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(NAME_KEY);
  localStorage.removeItem(ROLE_KEY);
}
export function displayName(): string { return localStorage.getItem(NAME_KEY) ?? ""; }
export function getRole(): string { return localStorage.getItem(ROLE_KEY) ?? "editor"; }
export function setRole(role: string) { localStorage.setItem(ROLE_KEY, role || "editor"); }
