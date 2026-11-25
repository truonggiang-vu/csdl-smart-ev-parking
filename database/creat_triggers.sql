-- =========================================================================
-- FILE: 04_triggers.sql
-- MÔ TẢ: TOÀN BỘ 13 TRIGGERS & 1 EVENT THỰC THI RÀNG BUỘC NGHIỆP VỤ (SMART EV PARKING)
-- =========================================================================

USE smart_ev_parking;

-- Xóa toàn bộ Trigger & Event cũ nếu đã tồn tại để chạy lại file không bị lỗi trùng tên
DROP TRIGGER IF EXISTS trg_before_insert_reservation;
DROP TRIGGER IF EXISTS trg_after_insert_reservation;
DROP TRIGGER IF EXISTS trg_after_update_reservation;
DROP TRIGGER IF EXISTS trg_before_insert_parking_session_snapshot;
DROP TRIGGER IF EXISTS trg_before_insert_ev_session;
DROP TRIGGER IF EXISTS trg_after_insert_ev_session;
DROP TRIGGER IF EXISTS trg_before_insert_regular_session;
DROP TRIGGER IF EXISTS trg_after_insert_regular_session;
DROP TRIGGER IF EXISTS trg_validate_charging_time_insert;
DROP TRIGGER IF EXISTS trg_validate_charging_time;
DROP TRIGGER IF EXISTS trg_after_insert_applied_tariff;
DROP TRIGGER IF EXISTS trg_before_update_parking_session;
DROP TRIGGER IF EXISTS trg_after_update_parking_session;
DROP EVENT   IF EXISTS evt_auto_cancel_timeout_reservations;

DELIMITER $$

-- =========================================================================
-- CỤM 1: NGHIỆP VỤ ĐẶT CHỖ TRƯỚC (RESERVATION) - 3 TRIGGERS
-- =========================================================================

-- -------------------------------------------------------------------------
-- Trigger 1.1: Kiểm tra toàn bộ điều kiện hợp lệ TRƯỚC KHI tạo đơn đặt chỗ
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_before_insert_reservation
BEFORE INSERT ON RESERVATION
FOR EACH ROW
BEGIN
    DECLARE v_slot_status   VARCHAR(20);
    DECLARE v_owner_id      INT UNSIGNED;
    DECLARE v_is_icv        INT DEFAULT 0;
    DECLARE v_is_ev_slot    INT DEFAULT 0;
    DECLARE v_overlap_count INT DEFAULT 0;

    -- Bước 1: CHỈ cho phép đặt chỗ khi ô đỗ đang trống hoàn toàn ('AVAILABLE')
    -- Khóa cứng cả trạng thái 'RESERVED', 'OCCUPIED' và 'MAINTENANCE'
    SELECT status INTO v_slot_status
    FROM PARKING_SLOT
    WHERE slot_id = NEW.slot_id;

    IF v_slot_status <> 'AVAILABLE' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi nghiệp vụ: Ô đỗ này hiện không trống (đang RESERVED, OCCUPIED hoặc MAINTENANCE), không thể đặt trước.';
    END IF;

    -- Bước 2: Kiểm tra xe đặt chỗ có đúng thuộc quyền sở hữu của người đặt không
    SELECT user_id INTO v_owner_id
    FROM VEHICLE
    WHERE vehicle_id = NEW.vehicle_id;

    IF v_owner_id IS NULL OR v_owner_id <> NEW.user_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi nghiệp vụ: Phương tiện đặt chỗ không thuộc quyền sở hữu của người dùng này.';
    END IF;

    -- Bước 3: Kiểm tra quy tắc BR11 (Chỉ được đặt trước tối đa 12 giờ)
    IF NEW.start_time > DATE_ADD(NEW.created_at, INTERVAL 12 HOUR) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi BR11: Chỉ được phép đặt chỗ trước tối đa 12 giờ.';
    END IF;

    -- Bước 4: Kiểm tra quy tắc BR07/BR08 (Cấm xe xăng đặt chỗ vào ô sạc xe điện)
    SELECT COUNT(*) INTO v_is_icv
    FROM INTERNAL_COMBUSTION_VEHICLE
    WHERE vehicle_id = NEW.vehicle_id;

    SELECT COUNT(*) INTO v_is_ev_slot
    FROM EV_SLOT
    WHERE slot_id = NEW.slot_id;

    IF v_is_icv > 0 AND v_is_ev_slot > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi BR08: Xe động cơ đốt trong nghiêm cấm đặt chỗ tại vị trí sạc xe điện (EV_SLOT).';
    END IF;

    -- Bước 5: Kiểm tra quy tắc BR12 (Chống đặt trùng khung giờ trên cùng một ô đỗ)
    SELECT COUNT(*) INTO v_overlap_count
    FROM RESERVATION
    WHERE slot_id = NEW.slot_id
      AND status IN ('PENDING', 'CHECKED_IN')
      AND (NEW.start_time < end_time AND NEW.end_time > start_time);

    IF v_overlap_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi BR12: Khung thời gian đặt chỗ bị trùng lặp với một lịch đặt trước khác.';
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 1.2: Tự động khóa ô đỗ thành 'RESERVED' SAU KHI đặt chỗ thành công
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_after_insert_reservation
AFTER INSERT ON RESERVATION
FOR EACH ROW
BEGIN
    IF NEW.status = 'PENDING' THEN
        UPDATE PARKING_SLOT
        SET status = 'RESERVED'
        WHERE slot_id = NEW.slot_id;
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 1.3: Tự động mở khóa ô đỗ về 'AVAILABLE' SAU KHI đơn đặt chỗ bị hủy/quá hạn
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_after_update_reservation
AFTER UPDATE ON RESERVATION
FOR EACH ROW
BEGIN
    IF OLD.status = 'PENDING' AND NEW.status IN ('CANCELLED_BY_USER', 'CANCELLED_TIMEOUT') THEN
        UPDATE PARKING_SLOT
        SET status = 'AVAILABLE'
        WHERE slot_id = NEW.slot_id
          AND status = 'RESERVED';
    END IF;
END$$


-- =========================================================================
-- CỤM 2: NGHIỆP VỤ XE VÀO BÃI / CHECK-IN (SESSION) - 5 TRIGGERS
-- =========================================================================

-- -------------------------------------------------------------------------
-- Trigger 2.1: Kiểm tra xe trùng phiên ACTIVE, chặn giờ vào ở tương lai & Snapshot đơn giá
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_before_insert_parking_session_snapshot
BEFORE INSERT ON PARKING_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_current_rate    DECIMAL(10, 2);
    DECLARE v_active_sessions INT DEFAULT 0;

    -- Bước 1: Chặn giờ xe vào bãi vượt quá thời gian thực tế hiện tại (NOW())
    IF NEW.actual_start > NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi thời gian: Thời điểm xe vào bãi (actual_start) không thể ở tương lai.';
    END IF;

    -- Bước 2: Chặn tạo phiên mới nếu phương tiện này đang có phiên đỗ ACTIVE chưa kết thúc
    IF NEW.session_status = 'ACTIVE' THEN
        SELECT COUNT(*) INTO v_active_sessions
        FROM PARKING_SESSION
        WHERE vehicle_id = NEW.vehicle_id
          AND session_status = 'ACTIVE';

        IF v_active_sessions > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Lỗi nghiệp vụ: Phương tiện này đang ở trong bãi (ACTIVE), không thể tạo thêm phiên đỗ mới.';
        END IF;
    END IF;

    -- Bước 3: Lấy đúng đơn giá từ bảng PARKING_RATE và chốt snapshot (BR20)
    SELECT rate_per_hour INTO v_current_rate
    FROM PARKING_RATE
    WHERE parking_rate_id = NEW.parking_rate_id;

    IF v_current_rate IS NOT NULL THEN
        SET NEW.applied_rate_per_hour = v_current_rate;
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 2.2: Kiểm tra điều kiện TRƯỚC KHI gán xe vào ô sạc điện (EV_SESSION)
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_before_insert_ev_session
BEFORE INSERT ON EV_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_vehicle_id     INT UNSIGNED;
    DECLARE v_reservation_id INT UNSIGNED;
    DECLARE v_is_ev          INT DEFAULT 0;
    DECLARE v_slot_status    VARCHAR(20);

    SELECT vehicle_id, reservation_id INTO v_vehicle_id, v_reservation_id
    FROM PARKING_SESSION
    WHERE session_id = NEW.session_id;

    -- Kiểm tra quy tắc BR08: Xe vào ô sạc bắt buộc phải thuộc bảng ELECTRIC_VEHICLE
    SELECT COUNT(*) INTO v_is_ev
    FROM ELECTRIC_VEHICLE
    WHERE vehicle_id = v_vehicle_id;

    IF v_is_ev = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi BR08: Chỉ phương tiện xe điện mới được phép sử dụng ô sạc (EV_SESSION).';
    END IF;

    -- Kiểm tra quy tắc FR04: Nếu là khách vãng lai (reservation_id IS NULL), ô sạc phải đang AVAILABLE
    SELECT status INTO v_slot_status
    FROM PARKING_SLOT
    WHERE slot_id = NEW.slot_id;

    IF v_reservation_id IS NULL AND v_slot_status <> 'AVAILABLE' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi FR04: Ô sạc này đã được đặt trước hoặc đang bận, khách vãng lai không thể sử dụng.';
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 2.3: Chuyển ô sạc sang 'OCCUPIED' SAU KHI xe điện vào vị trí thành công
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_after_insert_ev_session
AFTER INSERT ON EV_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_session_status VARCHAR(20);

    SELECT session_status INTO v_session_status
    FROM PARKING_SESSION
    WHERE session_id = NEW.session_id;

    IF v_session_status = 'ACTIVE' THEN
        UPDATE PARKING_SLOT
        SET status = 'OCCUPIED'
        WHERE slot_id = NEW.slot_id;
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 2.4: Kiểm tra điều kiện TRƯỚC KHI gán xe vào ô đỗ thường (REGULAR_SESSION)
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_before_insert_regular_session
BEFORE INSERT ON REGULAR_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_vehicle_id     INT UNSIGNED;
    DECLARE v_reservation_id INT UNSIGNED;
    DECLARE v_is_ev          INT DEFAULT 0;
    DECLARE v_area_id        INT UNSIGNED;
    DECLARE v_free_ev_slots  INT DEFAULT 0;
    DECLARE v_slot_status    VARCHAR(20);

    SELECT vehicle_id, reservation_id INTO v_vehicle_id, v_reservation_id
    FROM PARKING_SESSION
    WHERE session_id = NEW.session_id;

    SELECT status, area_id INTO v_slot_status, v_area_id
    FROM PARKING_SLOT
    WHERE slot_id = NEW.slot_id;

    -- Kiểm tra quy tắc FR04: Khách vãng lai chỉ được vào ô đang AVAILABLE
    IF v_reservation_id IS NULL AND v_slot_status <> 'AVAILABLE' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi FR04: Ô đỗ này đã được đặt trước hoặc đang bận, khách vãng lai không thể sử dụng.';
    END IF;

    -- Kiểm tra quy tắc BR09: Xe điện không được chiếm ô thường nếu khu vực đó vẫn còn ô sạc trống
    SELECT COUNT(*) INTO v_is_ev
    FROM ELECTRIC_VEHICLE
    WHERE vehicle_id = v_vehicle_id;

    IF v_is_ev > 0 THEN
        SELECT COUNT(*) INTO v_free_ev_slots
        FROM PARKING_SLOT ps
        JOIN EV_SLOT ev ON ps.slot_id = ev.slot_id
        WHERE ps.area_id = v_area_id
          AND ps.status = 'AVAILABLE';

        IF v_free_ev_slots > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Lỗi BR09: Khu vực này vẫn còn trụ sạc trống, xe điện không được chiếm dụng ô đỗ thường.';
        END IF;
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 2.5: Chuyển ô thường sang 'OCCUPIED' SAU KHI xe vào vị trí thành công
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_after_insert_regular_session
AFTER INSERT ON REGULAR_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_session_status VARCHAR(20);

    SELECT session_status INTO v_session_status
    FROM PARKING_SESSION
    WHERE session_id = NEW.session_id;

    IF v_session_status = 'ACTIVE' THEN
        UPDATE PARKING_SLOT
        SET status = 'OCCUPIED'
        WHERE slot_id = NEW.slot_id;
    END IF;
END$$


-- =========================================================================
-- CỤM 3: NGHIỆP VỤ SẠC ĐIỆN & TÍNH TIỀN ĐIỆN (CHARGING) - 3 TRIGGERS
-- =========================================================================

-- -------------------------------------------------------------------------
-- Trigger 3.1: Ràng buộc thời gian cắm sạc hợp lệ TRƯỚC KHI tạo phiên sạc (INSERT)
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_validate_charging_time_insert
BEFORE INSERT ON CHARGING_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_actual_start DATETIME;
    DECLARE v_actual_end   DATETIME;

    SELECT actual_start, actual_end INTO v_actual_start, v_actual_end
    FROM PARKING_SESSION
    WHERE session_id = NEW.session_id;

    IF NEW.plug_in_time < v_actual_start THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi toàn vẹn thời gian: Thời điểm cắm sạc không thể sớm hơn lúc xe vào bãi.';
    END IF;

    IF NEW.plug_out_time IS NOT NULL AND v_actual_end IS NOT NULL AND NEW.plug_out_time > v_actual_end THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi toàn vẹn thời gian: Thời điểm rút sạc phải trước hoặc bằng lúc xe rời bãi.';
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 3.2: Ràng buộc thời gian sạc phải nằm trọn trong thời gian lưu bãi (UPDATE)
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_validate_charging_time
BEFORE UPDATE ON CHARGING_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_actual_start DATETIME;
    DECLARE v_actual_end   DATETIME;

    SELECT actual_start, actual_end INTO v_actual_start, v_actual_end
    FROM PARKING_SESSION
    WHERE session_id = NEW.session_id;

    IF NEW.plug_in_time < v_actual_start THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi toàn vẹn thời gian: Thời điểm cắm sạc không thể sớm hơn lúc xe vào bãi.';
    END IF;

    IF NEW.plug_out_time IS NOT NULL AND v_actual_end IS NOT NULL AND NEW.plug_out_time > v_actual_end THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi toàn vẹn thời gian: Thời điểm rút sạc phải trước hoặc bằng lúc xe rời bãi.';
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 3.3: Tự động cộng dồn tiền điện (charging_fee) theo bậc thang (BR19)
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_after_insert_applied_tariff
AFTER INSERT ON APPLIES_ELECTRIC_TARIFF
FOR EACH ROW
BEGIN
    UPDATE CHARGING_SESSION
    SET charging_fee = (
        SELECT COALESCE(SUM(kwh_in_period * applied_rate_per_kwh), 0.00)
        FROM APPLIES_ELECTRIC_TARIFF
        WHERE charging_id = NEW.charging_id
    )
    WHERE charging_id = NEW.charging_id;
END$$


-- =========================================================================
-- CỤM 4: NGHIỆP VỤ RỜI BÃI, TÍNH TIỀN ĐỖ & CHỐT HÓA ĐƠN - 2 TRIGGERS
-- =========================================================================

-- -------------------------------------------------------------------------
-- Trigger 4.1: Khóa bất biến hóa đơn (BR20), kiểm tra giờ ra hợp lệ & tự tính tiền
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_before_update_parking_session
BEFORE UPDATE ON PARKING_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_minutes INT;
    DECLARE v_hours   INT;

    -- Phần 1: Kiểm tra quy tắc BR20 - Hóa đơn đã COMPLETED thì cấm sửa giờ và tiền
    IF OLD.session_status = 'COMPLETED' THEN
        IF NEW.applied_rate_per_hour <> OLD.applied_rate_per_hour
           OR NEW.parking_fee <> OLD.parking_fee
           OR NEW.actual_start <> OLD.actual_start
           OR NEW.actual_end <> OLD.actual_end THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Lỗi BR20: Hóa đơn đã hoàn tất (COMPLETED) mang tính bất biến, không được phép chỉnh sửa.';
        END IF;
    END IF;

    -- Phần 2: Kiểm tra hợp lệ, tự động tính tiền đỗ xe và chốt trạng thái khi nhập giờ ra bãi (actual_end)
    IF OLD.actual_end IS NULL AND NEW.actual_end IS NOT NULL THEN
        IF NEW.actual_end < NEW.actual_start THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Lỗi thời gian: Giờ ra bãi (actual_end) không thể sớm hơn giờ vào bãi.';
        END IF;

        IF NEW.actual_end > NOW() THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Lỗi thời gian: Giờ ra bãi (actual_end) không thể lớn hơn thời điểm hiện tại.';
        END IF;

        SET v_minutes = TIMESTAMPDIFF(MINUTE, NEW.actual_start, NEW.actual_end);
        SET v_hours   = GREATEST(1, CEIL(v_minutes / 60.0));

        SET NEW.parking_fee    = v_hours * NEW.applied_rate_per_hour;
        SET NEW.session_status = 'COMPLETED';
    END IF;
END$$

-- -------------------------------------------------------------------------
-- Trigger 4.2: Tự động giải phóng ô đỗ SAU KHI xe rời bãi (COMPLETED)
-- -------------------------------------------------------------------------
CREATE TRIGGER trg_after_update_parking_session
AFTER UPDATE ON PARKING_SESSION
FOR EACH ROW
BEGIN
    DECLARE v_slot_id       INT UNSIGNED;
    DECLARE v_pending_count INT DEFAULT 0;

    IF OLD.session_status = 'ACTIVE' AND NEW.session_status = 'COMPLETED' THEN
        SELECT slot_id INTO v_slot_id
        FROM (
            SELECT slot_id FROM REGULAR_SESSION WHERE session_id = NEW.session_id
            UNION ALL
            SELECT slot_id FROM EV_SESSION WHERE session_id = NEW.session_id
        ) AS t
        LIMIT 1;

        IF v_slot_id IS NOT NULL THEN
            SELECT COUNT(*) INTO v_pending_count
            FROM RESERVATION
            WHERE slot_id = v_slot_id AND status = 'PENDING';

            IF v_pending_count > 0 THEN
                UPDATE PARKING_SLOT SET status = 'RESERVED' WHERE slot_id = v_slot_id;
            ELSE
                UPDATE PARKING_SLOT SET status = 'AVAILABLE' WHERE slot_id = v_slot_id;
            END IF;
        END IF;
    END IF;
END$$


-- =========================================================================
-- CỤM 5: TỰ ĐỘNG HÓA THEO THỜI GIAN (MYSQL EVENT SCHEDULER - BR13)
-- =========================================================================
SET GLOBAL event_scheduler = ON$$

CREATE EVENT evt_auto_cancel_timeout_reservations
ON SCHEDULE EVERY 1 MINUTE
DO
BEGIN
    -- Tự động hủy các đơn đặt chỗ quá 15 phút kể từ start_time mà chưa check-in
    -- Hành động UPDATE này tự động kích hoạt Trigger 1.3 để giải phóng ô về AVAILABLE
    UPDATE RESERVATION
    SET status = 'CANCELLED_TIMEOUT'
    WHERE status = 'PENDING'
      AND NOW() > DATE_ADD(start_time, INTERVAL 15 MINUTE);
END$$

DELIMITER ;

-- Liệt kê toàn bộ 13 Triggers và 1 Event vừa khởi tạo để kiểm tra
SHOW TRIGGERS FROM smart_ev_parking;
SHOW EVENTS FROM smart_ev_parking;