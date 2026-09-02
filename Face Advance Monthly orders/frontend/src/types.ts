export interface OrderItem { name: string; qty: number; }

export interface Order {
  id: number;
  date: string;          // YYYY-MM-DD (เวลาไทย)
  ordered_at: string;
  phone: string;
  customer_name: string;
  address: string;
  address_parts: string[];   // ส่วนย่อยที่อยู่ [รายละเอียด, ตำบล, อำเภอ, จังหวัด, ไปรษณีย์] (ตอนขยายแยกบรรทัด)
  carrier: string;
  tracking_no: string;
  payment_method: string;
  total_sales: number;
  delivery_status: string;
  payment_status: string;
  return_arrived: boolean;   // ตีกลับถึงแล้ว (ลอจิกเฟสถัดไป)
  return_reason: string;     // เหตุผลตีกลับ (dropdown) — "" ถ้าไม่มี
  status_detail: string;     // ข้อความเพิ่มเติม/รายละเอียดปัญหา — "" ถ้าไม่มี
  seller_code: string;       // รหัสผู้ขาย (sellers.employee_code) — "" ถ้าไม่ระบุ
  seller_name: string;       // ชื่อผู้ขาย (sellers.name) — "" ถ้าไม่ระบุ
  items: OrderItem[];        // รายการสินค้าในออเดอร์
  note: string;
}

// รายการในไทม์ไลน์บันทึกการติดตาม (โน้ต + log เปลี่ยนสถานะ)
export interface TrackingEntry {
  id: number;
  type: "note" | "delivery_change" | "payment_change";
  note: string | null;
  old: string | null;
  new: string | null;
  detail: string | null;
  by: string;                // ชื่อผู้ทำ (snapshot)
  at: string;                // "YYYY-MM-DDTHH:MM:SS" เวลาไทย
}

export interface Kpi {
  exported_count: number;
  sales_total: number;
  sales_paid: number;
  sales_unpaid: number;
  returned_count: number;
  returned_amount: number;          // ยอดที่ตีกลับถึงแล้ว (return_arrived)
  returned_amount_status: number;   // ยอดตีกลับจากสถานะจัดส่ง = ตีกลับ
}

export interface Daily {
  exported: number[];
  sales_paid: number[];
  sales_unpaid: number[];
  returned: number[];
}

export interface OrdersResponse {
  authorized: boolean;
  error?: string;
  role?: string;         // editor | viewer (viewer = ดูอย่างเดียว)
  month: string;         // YYYY-MM
  days_in_month: number;
  today: string;         // YYYY-MM-DD (เวลาไทย)
  orders: Order[];
  kpi: Kpi;              // คำนวณฝั่ง frontend จาก orders
  daily: Daily;         // คำนวณฝั่ง frontend จาก orders
}
