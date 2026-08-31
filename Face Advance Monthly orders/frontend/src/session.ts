const TOKEN_KEY = "fa_session";
const NAME_KEY = "fa_display";

export function getToken(): string { return localStorage.getItem(TOKEN_KEY) ?? ""; }
export function setSession(token: string, displayName: string) {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(NAME_KEY, displayName || "");
}
export function clearSession() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(NAME_KEY);
}
export function displayName(): string { return localStorage.getItem(NAME_KEY) ?? ""; }
