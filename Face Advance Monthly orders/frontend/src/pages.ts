// โครงระบบหลายหน้า + สิทธิ์ตาม role (Stage 8)
// หน้า: orders (ปัจจุบัน) · record-returns · returns-list · edith (แอดมิน)

export type PageKey = "orders" | "record-returns" | "returns-list" | "search" | "edith";

export interface PageDef {
  key: PageKey;
  title: string;   // ชื่อหน้า (แสดงบน header + tooltip Dock)
  icon: string;    // id ไอคอนใน <defs> ของ index.html
  logo?: boolean;  // true = ใช้โลโก้ระบบ (fmark.png) แทน svg ไอคอน
  built: boolean;  // false = ยังเป็นหน้า "กำลังก่อสร้าง"
}

export const PAGES: PageDef[] = [
  { key: "orders",         title: "ออเดอร์",        icon: "i-truck-solid", built: true  },
  { key: "record-returns", title: "บันทึกตีกลับ",   icon: "i-boxret-solid", built: true  },
  { key: "returns-list",   title: "ออเดอร์ตีกลับ",   icon: "i-clip-solid",  built: true  },
  { key: "search",         title: "ค้นหา",          icon: "i-search-solid", built: true  },
  { key: "edith",          title: "EDITH",          icon: "i-editbox", logo: true, built: true },
];

export function pageDef(key: PageKey): PageDef {
  return PAGES.find((p) => p.key === key) ?? PAGES[0];
}

// role → หน้าที่เข้าถึงได้ (เรียงตามลำดับใน PAGES เสมอเมื่อ render)
export const ROLE_PAGES: Record<string, PageKey[]> = {
  Adm:   ["orders", "record-returns", "returns-list", "search", "edith"],
  OM:    ["orders", "search"],
  "RT+": ["record-returns", "returns-list", "search"],
  RTs:   ["returns-list", "search"],
  Vm:    ["orders", "returns-list", "search"],
};

// role → แก้ไขข้อมูลได้ไหม (Vm/RTs = ดูอย่างเดียว)
export const ROLE_CAN_EDIT: Record<string, boolean> = {
  Adm: true, OM: true, "RT+": true, RTs: false, Vm: false,
};

/** หน้าที่ role เข้าถึงได้ (เรียงตามลำดับ PAGES) — ไม่รู้จัก role → ปลอดภัยไว้ก่อน = ไม่มีหน้า */
export function pagesFor(role: string): PageKey[] {
  const allowed = new Set(ROLE_PAGES[role] ?? []);
  return PAGES.filter((p) => allowed.has(p.key)).map((p) => p.key);
}

export function canEdit(role: string): boolean {
  return ROLE_CAN_EDIT[role] ?? false;
}
