-- =========================================================================
-- PHẦN 1: KHỞI TẠO CƠ SỞ DỮ LIỆU VÀ CÁC BẢNG (16 TABLES)
-- =========================================================================

DROP DATABASE IF EXISTS smart_ev_parking;
CREATE DATABASE smart_ev_parking
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE smart_ev_parking;

-- -------------------------------------------------------------------------
-- NHÓM 1: NGƯỜI DÙNG & PHƯƠNG TIỆN (USER & VEHICLE HIERARCHY)
-- -------------------------------------------------------------------------

-- 1. Bảng USER: Lưu trữ tài khoản người dùng đã đăng ký (BR04)
CREATE TABLE USER (
    user_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(150) NOT NULL,
    phone       VARCHAR(15)  NOT NULL,
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_user_email UNIQUE (email),
    CONSTRAINT uq_user_phone UNIQUE (phone)
) ENGINE=InnoDB;

-- 2. Bảng VEHICLE (Bảng cha): Lưu thuộc tính chung của mọi phương tiện
CREATE TABLE VEHICLE (
    vehicle_id    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    brand         VARCHAR(50) NOT NULL,
    model         VARCHAR(50) NOT NULL,
    license_plate VARCHAR(20) NOT NULL,
    user_id       INT UNSIGNED NULL, -- NULL nếu là xe khách vãng lai (BR01)

    CONSTRAINT uq_vehicle_plate UNIQUE (license_plate),
    CONSTRAINT fk_vehicle_user  FOREIGN KEY (user_id)
        REFERENCES USER(user_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 3. Bảng ELECTRIC_VEHICLE (Bảng con kế thừa VEHICLE - Disjoint & Total)
CREATE TABLE ELECTRIC_VEHICLE (
    vehicle_id       INT UNSIGNED PRIMARY KEY, -- PK kiêm FK trỏ về VEHICLE
    battery_capacity DECIMAL(6, 2) NOT NULL,
    connector_type   VARCHAR(30)   NOT NULL,

    CONSTRAINT chk_ev_battery CHECK (battery_capacity > 0.0), -- BR03
    CONSTRAINT fk_ev_vehicle  FOREIGN KEY (vehicle_id)
        REFERENCES VEHICLE(vehicle_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 4. Bảng INTERNAL_COMBUSTION_VEHICLE (Bảng con xe xăng/dầu)
CREATE TABLE INTERNAL_COMBUSTION_VEHICLE (
    vehicle_id INT UNSIGNED PRIMARY KEY, -- PK kiêm FK trỏ về VEHICLE
    fuel_type  VARCHAR(30) NOT NULL,

    CONSTRAINT fk_icv_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES VEHICLE(vehicle_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- -------------------------------------------------------------------------
-- NHÓM 2: HẠ TẦNG BÃI ĐỖ (PARKING_AREA & PARKING_SLOT HIERARCHY)
-- -------------------------------------------------------------------------

-- 5. Bảng PARKING_AREA: Khu vực đỗ xe (total_capacity là thuộc tính dẫn xuất nên không lưu cứng)
CREATE TABLE PARKING_AREA (
    area_id   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    area_name VARCHAR(100) NOT NULL,
    address   VARCHAR(255) NOT NULL
) ENGINE=InnoDB;

-- 6. Bảng PARKING_SLOT (Bảng cha): Vị trí đỗ vật lý
CREATE TABLE PARKING_SLOT (
    slot_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    slot_number VARCHAR(20) NOT NULL,
    status      ENUM('AVAILABLE', 'RESERVED', 'OCCUPIED', 'MAINTENANCE') NOT NULL DEFAULT 'AVAILABLE',
    area_id     INT UNSIGNED NOT NULL,

    CONSTRAINT uq_slot_area_number UNIQUE (area_id, slot_number), -- UC4
    CONSTRAINT fk_slot_area        FOREIGN KEY (area_id)
        REFERENCES PARKING_AREA(area_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 7. Bảng REGULAR_SLOT (Bảng con kế thừa PARKING_SLOT): Ô đỗ thường
CREATE TABLE REGULAR_SLOT (
    slot_id    INT UNSIGNED PRIMARY KEY,
    is_covered BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT fk_reg_slot FOREIGN KEY (slot_id)
        REFERENCES PARKING_SLOT(slot_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 8. Bảng EV_SLOT (Bảng con kế thừa PARKING_SLOT): Ô đỗ tích hợp trụ sạc
CREATE TABLE EV_SLOT (
    slot_id           INT UNSIGNED PRIMARY KEY,
    charger_type      ENUM('AC', 'DC') NOT NULL,
    max_power_kw      DECIMAL(6, 2)    NOT NULL,
    support_connector VARCHAR(30)      NOT NULL,

    CONSTRAINT chk_ev_slot_power CHECK (max_power_kw > 0.0), -- BR07
    CONSTRAINT fk_ev_slot        FOREIGN KEY (slot_id)
        REFERENCES PARKING_SLOT(slot_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- -------------------------------------------------------------------------
-- NHÓM 3: BIỂU GIÁ ĐỖ XE & BIỂU GIÁ ĐIỆN (RATES)
-- -------------------------------------------------------------------------

-- 9. Bảng PARKING_RATE: Đơn giá gửi xe theo giờ
CREATE TABLE PARKING_RATE (
    parking_rate_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    rate_type       VARCHAR(50)    NOT NULL,
    rate_per_hour   DECIMAL(10, 2) NOT NULL,
    valid_from      DATETIME       NOT NULL,
    valid_to        DATETIME       NULL, -- NULL nếu biểu giá đang hiện hành

    CONSTRAINT chk_parking_rate_val   CHECK (rate_per_hour >= 0.0),
    CONSTRAINT chk_parking_rate_dates CHECK (valid_to IS NULL OR valid_to >= valid_from)
) ENGINE=InnoDB;

-- 10. Bảng TARIFF_RATE: Đơn giá điện theo khung giờ (Cao điểm/Bình thường/Thấp điểm)
CREATE TABLE TARIFF_RATE (
    tariff_id      INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    rate_type      ENUM('PEAK', 'NORMAL', 'OFF_PEAK') NOT NULL,
    start_hour     TIME           NOT NULL,
    end_hour       TIME           NOT NULL,
    rate_per_kwh   DECIMAL(10, 2) NOT NULL,
    effective_date DATE           NOT NULL,
    expire_date    DATE           NULL, -- NULL nếu biểu giá đang hiện hành

    CONSTRAINT chk_tariff_rate_val   CHECK (rate_per_kwh >= 0.0),
    CONSTRAINT chk_tariff_rate_dates CHECK (expire_date IS NULL OR expire_date >= effective_date)
) ENGINE=InnoDB;

-- -------------------------------------------------------------------------
-- NHÓM 4: ĐẶT CHỖ, PHIÊN ĐỖ & PHIÊN SẠC (TRANSACTIONS)
-- -------------------------------------------------------------------------

-- 11. Bảng RESERVATION: Lịch đặt chỗ trước của Registered User
CREATE TABLE RESERVATION (
    reservation_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    start_time     DATETIME NOT NULL,
    end_time       DATETIME NOT NULL,
    created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status         ENUM('PENDING', 'CHECKED_IN', 'CANCELLED_BY_USER', 'CANCELLED_TIMEOUT') NOT NULL DEFAULT 'PENDING',
    user_id        INT UNSIGNED NOT NULL,
    vehicle_id     INT UNSIGNED NOT NULL,
    slot_id        INT UNSIGNED NOT NULL,

    CONSTRAINT chk_res_time    CHECK (end_time > start_time), -- NFR02
    CONSTRAINT fk_res_user     FOREIGN KEY (user_id)    REFERENCES USER(user_id)         ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_res_vehicle  FOREIGN KEY (vehicle_id) REFERENCES VEHICLE(vehicle_id)   ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_res_slot     FOREIGN KEY (slot_id)    REFERENCES PARKING_SLOT(slot_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 12. Bảng PARKING_SESSION (Bảng cha): Phiên lưu bãi thực tế
CREATE TABLE PARKING_SESSION (
    session_id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    actual_start          DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actual_end            DATETIME       NULL, -- NULL khi xe đang đỗ trong bãi
    applied_rate_per_hour DECIMAL(10, 2) NOT NULL, -- Snapshot đơn giá giờ (BR20)
    parking_fee           DECIMAL(12, 2) NOT NULL DEFAULT 0.00,
    session_status        ENUM('ACTIVE', 'COMPLETED') NOT NULL DEFAULT 'ACTIVE',
    payment_status        ENUM('UNPAID', 'PAID', 'REFUNDED') NOT NULL DEFAULT 'UNPAID',
    vehicle_id            INT UNSIGNED   NOT NULL,
    parking_rate_id       INT UNSIGNED   NOT NULL,
    reservation_id        INT UNSIGNED   NULL, -- NULL đối với khách vãng lai

    CONSTRAINT uq_session_res      UNIQUE (reservation_id), -- 1 đặt chỗ tối đa 1 phiên (UC5)
    CONSTRAINT chk_session_time    CHECK (actual_end IS NULL OR actual_end > actual_start),
    CONSTRAINT chk_session_amounts CHECK (applied_rate_per_hour >= 0.0 AND parking_fee >= 0.0),

    CONSTRAINT fk_sess_vehicle     FOREIGN KEY (vehicle_id)      REFERENCES VEHICLE(vehicle_id)           ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_rate        FOREIGN KEY (parking_rate_id) REFERENCES PARKING_RATE(parking_rate_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sess_reservation FOREIGN KEY (reservation_id)  REFERENCES RESERVATION(reservation_id)   ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 13. Bảng REGULAR_SESSION (Bảng con): Phiên đỗ tại ô thường
CREATE TABLE REGULAR_SESSION (
    session_id INT UNSIGNED PRIMARY KEY,
    slot_id    INT UNSIGNED NOT NULL,

    CONSTRAINT fk_reg_sess_parent FOREIGN KEY (session_id) REFERENCES PARKING_SESSION(session_id) ON DELETE CASCADE  ON UPDATE CASCADE,
    CONSTRAINT fk_reg_sess_slot   FOREIGN KEY (slot_id)    REFERENCES REGULAR_SLOT(slot_id)       ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 14. Bảng EV_SESSION (Bảng con): Phiên đỗ tại ô sạc điện
CREATE TABLE EV_SESSION (
    session_id INT UNSIGNED PRIMARY KEY,
    slot_id    INT UNSIGNED NOT NULL,

    CONSTRAINT fk_ev_sess_parent FOREIGN KEY (session_id) REFERENCES PARKING_SESSION(session_id) ON DELETE CASCADE  ON UPDATE CASCADE,
    CONSTRAINT fk_ev_sess_slot   FOREIGN KEY (slot_id)    REFERENCES EV_SLOT(slot_id)            ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 15. Bảng CHARGING_SESSION: Phiên sạc điện vật lý (gắn 1:1 với EV_SESSION)
CREATE TABLE CHARGING_SESSION (
    charging_id   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    plug_in_time  DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    plug_out_time DATETIME       NULL, -- NULL khi đang cắm sạc
    meter_start   DECIMAL(10, 3) NOT NULL,
    meter_end     DECIMAL(10, 3) NULL,
    charging_fee  DECIMAL(12, 2) NOT NULL DEFAULT 0.00,
    session_id    INT UNSIGNED   NOT NULL,

    CONSTRAINT uq_charging_session UNIQUE (session_id), -- UC6
    CONSTRAINT chk_charging_time   CHECK (plug_out_time IS NULL OR plug_out_time > plug_in_time),
    CONSTRAINT chk_charging_meter  CHECK (meter_start >= 0.000 AND (meter_end IS NULL OR meter_end >= meter_start)), -- BR18
    CONSTRAINT chk_charging_fee    CHECK (charging_fee >= 0.00),

    CONSTRAINT fk_charging_ev_sess FOREIGN KEY (session_id)
        REFERENCES EV_SESSION(session_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 16. Bảng APPLIES_ELECTRIC_TARIFF: Bảng kết hợp N:N phân bổ điện năng theo khung giờ
CREATE TABLE APPLIES_ELECTRIC_TARIFF (
    charging_id          INT UNSIGNED   NOT NULL,
    tariff_id            INT UNSIGNED   NOT NULL,
    kwh_in_period        DECIMAL(10, 3) NOT NULL,
    applied_rate_per_kwh DECIMAL(10, 2) NOT NULL, -- Snapshot đơn giá điện (BR20)

    PRIMARY KEY (charging_id, tariff_id),

    CONSTRAINT chk_tariff_applied CHECK (kwh_in_period > 0.000 AND applied_rate_per_kwh >= 0.00),
    CONSTRAINT fk_app_charging    FOREIGN KEY (charging_id) REFERENCES CHARGING_SESSION(charging_id) ON DELETE CASCADE  ON UPDATE CASCADE,
    CONSTRAINT fk_app_tariff      FOREIGN KEY (tariff_id)   REFERENCES TARIFF_RATE(tariff_id)        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;