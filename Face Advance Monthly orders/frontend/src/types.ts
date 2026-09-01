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
  items: OrderItem[];        // รายการสินค้าในออเดอร์
  note: string;
}

export interface Kpi {
  exported_count: number;
  sales_total: number;
  sales_paid: number;
  sales_unpaid: number;
  returned_count: number;
  returned_amount: number;
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
  month: string;         // YYYY-MM
  days_in_month: number;
  today: string;         // YYYY-MM-DD (เวลาไทย)
  orders: Order[];
  kpi: Kpi;              // คำนวณฝั่ง frontend จาก orders
  daily: Daily;         // คำนวณฝั่ง frontend จาก orders
}
