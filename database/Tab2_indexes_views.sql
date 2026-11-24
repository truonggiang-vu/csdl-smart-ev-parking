-- =========================================================================
-- PHẦN 2: CHỈ MỤC TỐI ƯU HIỆU NĂNG (INDEXES - ĐÁP ỨNG NFR01)
-- =========================================================================

-- 1. Tối ưu tìm kiếm ô đỗ đang trống theo từng khu vực (UR02, BR09)

USE smart_ev_parking;

CREATE INDEX idx_slot_area_status
    ON PARKING_SLOT (area_id, status);

-- 2. Tối ưu kiểm tra xung đột khoảng thời gian đặt chỗ trên cùng 1 ô đỗ (FR02, BR12)
-- Và hỗ trợ job quét tự động hủy lịch quá hạn 15 phút (FR03, BR13)
CREATE INDEX idx_res_slot_status_time
    ON RESERVATION (slot_id, status, start_time, end_time);

-- 3. Tối ưu tra cứu phiên đỗ đang hoạt động và thống kê doanh thu theo thời gian
CREATE INDEX idx_session_status_time
    ON PARKING_SESSION (session_status, payment_status, actual_start);

-- 4. Tối ưu tìm kiếm biểu giá đỗ xe và biểu giá điện đang có hiệu lực (BR16, BR19)
CREATE INDEX idx_parking_rate_valid
    ON PARKING_RATE (valid_from, valid_to);

CREATE INDEX idx_tariff_rate_valid
    ON TARIFF_RATE (effective_date, expire_date, start_hour, end_hour);
    
-- =========================================================================
-- PHẦN 3: CÁC KHUNG NHÌN NGHIỆP VỤ & THUỘC TÍNH DẪN XUẤT (VIEWS)
-- =========================================================================

-- 1. View thống kê sức chứa và tình trạng chỗ trống theo từng khu vực (Tính total_capacity)

USE smart_ev_parking;

CREATE OR REPLACE VIEW v_parking_area_status AS
SELECT
    pa.area_id,
    pa.area_name,
    pa.address,
    COUNT(ps.slot_id)                                            AS total_capacity,
    SUM(CASE WHEN ps.status = 'AVAILABLE' THEN 1 ELSE 0 END)     AS available_slots,
    SUM(CASE WHEN ps.status = 'OCCUPIED'  THEN 1 ELSE 0 END)     AS occupied_slots,
    SUM(CASE WHEN ps.status = 'RESERVED'  THEN 1 ELSE 0 END)     AS reserved_slots,
    -- Đếm riêng số ô sạc EV đang trống phục vụ kiểm tra BR09
    SUM(CASE WHEN ev.slot_id IS NOT NULL AND ps.status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available_ev_slots
FROM PARKING_AREA pa
LEFT JOIN PARKING_SLOT ps ON pa.area_id = ps.area_id
LEFT JOIN EV_SLOT ev      ON ps.slot_id = ev.slot_id
GROUP BY pa.area_id, pa.area_name, pa.address;

-- 2. View chi tiết hóa đơn phiên đỗ & sạc (Tính kwh_consumed và total_cost - Đáp ứng UR04)
CREATE OR REPLACE VIEW v_session_invoice_details AS
SELECT
    ps.session_id,
    u.user_id,
    u.full_name                                                  AS customer_name,
    v.license_plate,
    CASE
        WHEN ev_v.vehicle_id IS NOT NULL THEN 'Electric Vehicle'
        ELSE 'ICE Vehicle'
    END                                                          AS vehicle_category,
    pa.area_name,
    sl.slot_number,
    ps.actual_start,
    ps.actual_end,
    TIMESTAMPDIFF(MINUTE, ps.actual_start, COALESCE(ps.actual_end, NOW())) AS duration_minutes,
    ps.applied_rate_per_hour,
    ps.parking_fee,
    cs.charging_id,
    cs.plug_in_time,
    cs.plug_out_time,
    -- Thuộc tính dẫn xuất kwh_consumed = meter_end - meter_start (BR18)
    COALESCE(cs.meter_end - cs.meter_start, 0.000)               AS kwh_consumed,
    COALESCE(cs.charging_fee, 0.00)                              AS charging_fee,
    -- Thuộc tính dẫn xuất total_cost = parking_fee + charging_fee (BR19)
    (ps.parking_fee + COALESCE(cs.charging_fee, 0.00))           AS total_cost,
    ps.session_status,
    ps.payment_status
FROM PARKING_SESSION ps
JOIN VEHICLE v             ON ps.vehicle_id   = v.vehicle_id
LEFT JOIN USER u           ON v.user_id       = u.user_id
LEFT JOIN ELECTRIC_VEHICLE ev_v ON v.vehicle_id = ev_v.vehicle_id
-- Xác định vị trí đỗ từ 1 trong 2 bảng con REGULAR_SESSION hoặc EV_SESSION
LEFT JOIN REGULAR_SESSION rs ON ps.session_id = rs.session_id
LEFT JOIN EV_SESSION es      ON ps.session_id = es.session_id
JOIN PARKING_SLOT sl         ON sl.slot_id    = COALESCE(rs.slot_id, es.slot_id)
JOIN PARKING_AREA pa         ON sl.area_id    = pa.area_id
LEFT JOIN CHARGING_SESSION cs ON es.session_id = cs.session_id;