import { test } from "node:test";
import assert from "node:assert/strict";
import { includeNewValues } from "../src/filter_sync.ts";

type O = { id: number; problem: string; status: string };
const val = (o: O, c: "problem" | "status") => o[c];

test("รายละเอียดปัญหาคำใหม่ → เติมเข้าตัวกรอง (แถวไม่หาย · ตัวเลือกใหม่ติ๊กไว้)", () => {
  const rows: O[] = [{ id: 1, problem: "ลูกค้าไม่รับสาย", status: "มีปัญหา" }, { id: 2, problem: "ที่อยู่ผิด", status: "มีปัญหา" }];
  const f = new Map([["problem" as const, new Set(["ลูกค้าไม่รับสาย", "ที่อยู่ผิด"])]]);
  rows[0].problem = "พัสดุเปียกน้ำ";   // พนักงานพิมพ์คำใหม่แล้วบันทึก
  const added = includeNewValues(f, rows, rows[0], val);
  assert.deepEqual(added, ["problem"]);
  assert.ok(f.get("problem")!.has("พัสดุเปียกน้ำ"));
});

test("ค่าที่มีอยู่แล้วในแถวอื่นแต่ไม่ได้ติ๊ก → ไม่เติม (เคารพตัวกรองที่ตั้งใจไว้)", () => {
  const rows: O[] = [{ id: 1, problem: "", status: "กำลังส่ง" }, { id: 2, problem: "", status: "ส่งสำเร็จ" }];
  const f = new Map([["status" as const, new Set(["กำลังส่ง"])]]);
  rows[0].status = "ส่งสำเร็จ";
  assert.deepEqual(includeNewValues(f, rows, rows[0], val), []);
  assert.ok(!f.get("status")!.has("ส่งสำเร็จ"));
});

test("ค่าอยู่ในตัวกรองอยู่แล้ว → ไม่ทำอะไร", () => {
  const rows: O[] = [{ id: 1, problem: "ที่อยู่ผิด", status: "มีปัญหา" }];
  const f = new Map([["problem" as const, new Set(["ที่อยู่ผิด"])]]);
  assert.deepEqual(includeNewValues(f, rows, rows[0], val), []);
});

test("สถานะที่เดือนนั้นยังไม่เคยมี (เช่น มีปัญหา ครั้งแรก) → เติม · หลายคอลัมน์พร้อมกัน", () => {
  const rows: O[] = [{ id: 1, problem: "—", status: "กำลังส่ง" }, { id: 2, problem: "—", status: "กำลังส่ง" }];
  const f = new Map<"problem" | "status", Set<string>>([["status", new Set(["กำลังส่ง"])], ["problem", new Set(["—"])]]);
  rows[1].status = "มีปัญหา"; rows[1].problem = "กล่องแตก";
  assert.deepEqual(includeNewValues(f, rows, rows[1], val).sort(), ["problem", "status"]);
});

test("ไม่มีตัวกรอง → ไม่ทำอะไร", () => {
  const rows: O[] = [{ id: 1, problem: "x", status: "y" }];
  assert.deepEqual(includeNewValues(new Map(), rows, rows[0], val), []);
});
