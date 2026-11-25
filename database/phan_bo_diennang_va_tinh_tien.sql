USE smart_ev_parking;

DROP PROCEDURE IF EXISTS sp_complete_charging_session;

DELIMITER $$

CREATE PROCEDURE sp_complete_charging_session(
    IN p_charging_id   INT UNSIGNED,
    IN p_plug_out_time DATETIME,
    IN p_meter_end     DECIMAL(10, 3)
)
BEGIN
    DECLARE v_plug_in_time  DATETIME;
    DECLARE v_meter_start   DECIMAL(10, 3);
    DECLARE v_total_kwh     DECIMAL(10, 3);
    DECLARE v_total_seconds BIGINT;
    DECLARE v_curr_date     DATE;
    DECLARE v_end_date      DATE;

    -- 1. Lấy thông tin lúc bắt đầu cắm sạc
    SELECT plug_in_time, meter_start 
    INTO v_plug_in_time, v_meter_start
    FROM CHARGING_SESSION
    WHERE charging_id = p_charging_id;

    -- Kiểm tra dữ liệu đầu vào cơ bản
    IF v_plug_in_time IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Không tìm thấy phiên sạc.';
    END IF;

    IF p_plug_out_time <= v_plug_in_time OR p_meter_end < v_meter_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Thời gian rút sạc hoặc chỉ số công tơ cuối không hợp lệ.';
    END IF;

    -- 2. Cập nhật thời gian rút sạc và chỉ số công tơ cuối (Trigger kiểm tra giờ đỗ sẽ tự chạy)
    UPDATE CHARGING_SESSION
    SET plug_out_time = p_plug_out_time,
        meter_end     = p_meter_end
    WHERE charging_id   = p_charging_id;

    -- Xóa dữ liệu phân bổ cũ (nếu có) để tránh trùng lặp khi chạy lại
    DELETE FROM APPLIES_ELECTRIC_TARIFF WHERE charging_id = p_charging_id;

    SET v_total_kwh     = p_meter_end - v_meter_start;
    SET v_total_seconds = TIMESTAMPDIFF(SECOND, v_plug_in_time, p_plug_out_time);
    SET v_curr_date     = DATE(v_plug_in_time);
    SET v_end_date      = DATE(p_plug_out_time);

    -- 3. Bảng tạm gom số giây sạc theo từng tariff_id (xử lý trường hợp sạc qua nhiều ngày)
    DROP TEMPORARY TABLE IF EXISTS tmp_tariff_usage;
    CREATE TEMPORARY TABLE tmp_tariff_usage (
        tariff_id            INT UNSIGNED PRIMARY KEY,
        applied_rate_per_kwh DECIMAL(10, 2),
        seconds_used         BIGINT DEFAULT 0
    );

    -- 4. Vòng lặp duyệt từng ngày từ ngày cắm sạc đến ngày rút sạc
    WHILE v_curr_date <= v_end_date DO
        INSERT INTO tmp_tariff_usage (tariff_id, applied_rate_per_kwh, seconds_used)
        SELECT 
            t.tariff_id,
            t.rate_per_kwh,
            -- Tính phần giao nhau (tính bằng giây) giữa [plug_in, plug_out] và khung giờ [start_hour, end_hour] của ngày đó
            TIMESTAMPDIFF(
                SECOND,
                GREATEST(v_plug_in_time, TIMESTAMP(v_curr_date, t.start_hour)),
                LEAST(
                    p_plug_out_time, 
                    -- Nếu end_hour là 23:59:59 thì cộng thêm 1 giây (thành 00:00 ngày hôm sau) để không hụt 1 giây giao thừa
                    IF(t.end_hour = '23:59:59', DATE_ADD(TIMESTAMP(v_curr_date, '00:00:00'), INTERVAL 1 DAY), TIMESTAMP(v_curr_date, t.end_hour))
                )
            ) AS overlap_sec
        FROM TARIFF_RATE t
        WHERE t.effective_date <= v_curr_date
          AND (t.expire_date IS NULL OR t.expire_date >= v_curr_date)
        HAVING overlap_sec > 0
        ON DUPLICATE KEY UPDATE 
            seconds_used = seconds_used + VALUES(seconds_used);

        SET v_curr_date = DATE_ADD(v_curr_date, INTERVAL 1 DAY);
    END WHILE;

    -- 5. Tự động chia tỷ lệ kWh và chèn vào APPLIES_ELECTRIC_TARIFF
    -- (Trigger trg_after_insert_applied_tariff sẽ tự động cộng tiền vào CHARGING_SESSION.charging_fee)
    INSERT INTO APPLIES_ELECTRIC_TARIFF (charging_id, tariff_id, kwh_in_period, applied_rate_per_kwh)
    SELECT 
        p_charging_id,
        tariff_id,
        ROUND(v_total_kwh * (seconds_used / v_total_seconds), 3),
        applied_rate_per_kwh
    FROM tmp_tariff_usage;

    DROP TEMPORARY TABLE IF EXISTS tmp_tariff_usage;
END$$

DELIMITER ;