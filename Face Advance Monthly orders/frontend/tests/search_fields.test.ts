import { test } from "node:test";
import assert from "node:assert/strict";
import { SEARCH_FIELDS, normalizeField, searchPlaceholder, searchHint } from "../src/search_fields.ts";

test("SEARCH_FIELDS: ทั้งหมดมาก่อน + 5 ช่องตรงกับ RPC", () => {
  assert.deepEqual(SEARCH_FIELDS.map((f) => f.value), ["all", "phone", "name", "address", "tracking", "note"]);
  assert.equal(SEARCH_FIELDS[0].label, "ทั้งหมด");
});

test("normalizeField: ค่าแปลก/ว่าง → all", () => {
  assert.equal(normalizeField("phone"), "phone");
  assert.equal(normalizeField("tracking"), "tracking");
  assert.equal(normalizeField(""), "all");
  assert.equal(normalizeField("seller"), "all");
  assert.equal(normalizeField(null), "all");
});

test("searchPlaceholder: ทั้งหมด = ข้อความเดิม · เลือกช่อง = บอกช่อง", () => {
  assert.equal(searchPlaceholder("all"), "ค้นหา เบอร์ · ชื่อ · ที่อยู่ · แทร็ค · หมายเหตุ…");
  assert.equal(searchPlaceholder("phone"), "ค้นหาเฉพาะเบอร์โทร…");
  assert.equal(searchPlaceholder("note"), "ค้นหาเฉพาะหมายเหตุ…");
});

test("searchHint: ข้อความหน้าว่างตามช่องที่เลือก", () => {
  assert.equal(searchHint("all"), "พิมพ์ เบอร์ · ชื่อ · ที่อยู่ · แทร็คส่งออก · หมายเหตุ (อย่างน้อย 2 ตัว)");
  assert.equal(searchHint("address"), "พิมพ์ที่อยู่ที่ต้องการค้นหา (อย่างน้อย 2 ตัว)");
});
