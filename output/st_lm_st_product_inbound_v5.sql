-- ============================================================
-- 存储过程: st_lm_st_product_inbound (v5 - 性能优化版)
-- 导出时间: 2026-06-05
-- 修改说明:
--   【v4变更】
--   1. lm_st_product_inbound 表新增字段 c_lot_quantity
--   2. Q2/Q4(发货出库) c_lot_quantity 计算逻辑变更:
--      v3: 通过 wdod.lot_att02 关联 whm_reservoir_area (WGTH时lot_att02全NULL→c_lot=0)
--      v4: 通过 wms_pick_detail + wms_stock_attr 获取实际库区
--          wdod → wpd(dispatch_order_detail_id) → wsa(lot_code) → wsa.lot_att02
--          再关联 whm_reservoir_area 判断 is_ng_sub_library
--   3. Q2/Q4 quantity 改用 wpd.qty (拣货数量) 替代 wdod.qty
--      注意: wdod:wpd = 1:N，展开后行数增加但 GROUP BY 聚合后总量不变
--   4. Q1/Q3(ASN入库) 不变，仍使用 warod.lot_att02 关联库区
--
--   【v5优化 - SQL层面】
--   V5-1: Q2/Q4 wms_stock_attr JOIN 改用 FORCE INDEX(idx_wms_stock_attr_002)
--         调整ON列顺序为 (warehouse_id, lot_code) 匹配索引前缀
--         原: idx_001(lot_code) UNIQUE → warehouse_id在WHERE过滤(filtered=5%)
--         新: idx_002(warehouse_id, lot_code) → 两列都走索引，无需回表过滤
--
--   【v5优化 - 需手动执行DDL】
--   V5-I1: item_ext_prop ADD INDEX idx_item_id_prop_name (item_id, ext_prop_name)
--          收益最大: 每次JOIN从扫描20万行→1行，预估整体提速30%+
--   V5-I2: wms_dispatch_order_detail ADD INDEX idx_wh_dispatch_order_id (warehouse_id, dispatch_order_id)
--          Q2/Q4 wdod JOIN优化，预估提速10-15%
--   V5-I3: st_materialbatch_workorder_fg ADD INDEX idx_wmwf_type_date (workorder_type, plan_begin_date, material_batch)
--          Q1/Q3 wmwf过滤优化，预估提速5-10%
--
--   【v4已有优化 - 保留】
--   P0-1: 删除 st_water_pct_code 的4处无用 LEFT JOIN
--   P0-2: Q1/Q2(常规共享表)提出游标循环外，一次执行
--   P0-I1~I6: 索引优化（详见v4注释）
-- ============================================================

DROP PROCEDURE IF EXISTS `st_lm_st_product_inbound`;
delimiter ;;
CREATE PROCEDURE `st_lm_st_product_inbound`()
BEGIN
    DECLARE error_message VARCHAR(255);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    begin
        GET DIAGNOSTICS CONDITION 1 error_message = MESSAGE_TEXT;
        INSERT INTO event_logs (event_name, start_execution_time,end_execution_time, status, message)
        VALUES ('daily_lm_st_product_inbound_event', NOW(),NOW(), 'ERROR', error_message);
    END;

BEGIN
    DECLARE start_execution_time DATETIME ;
    DECLARE end_execution_time DATETIME ;
    DECLARE done INT DEFAULT FALSE;
    DECLARE ids VARCHAR(255);
    DECLARE curid CURSOR FOR 
        SELECT enterprise_id FROM st_enterprise_online;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    SET start_execution_time = NOW();

    DELETE FROM lm_st_product_inbound WHERE `date` >= '2026-01-01';

    -- ==============================================================
    -- [P0-2] Q1+Q2 常规共享表，提出循环外一次执行
    -- ==============================================================
    INSERT INTO lm_st_product_inbound(
        company_id,material_code,material_name,material_id,material_type,material_batch,
        quantity,date,production_line,team_id,team_code,team_name,
        org_code,org_name,company_code,company_name,allow_val_range,allow_val_range1,
        validflag,valid_user,valid_date,using_user,using_date,tenant_id,
        create_user,create_date,update_user,update_date,
        hourly_output,c_lot_quantity,plan_begin_date,workorder_type
    )
    SELECT
        fgin.company_id,
        fgin.material_code,
        fgin.material_name,
        fgin.material_id,
        fgin.material_type,
        fgin.material_batch,
        sum(fgin.quantity) AS quantity,
        date_format(fgin.date, '%Y-%m-%d') AS `date`,
        fgin.production_line,
        fgin.team_id,
        fgin.team_code,
        fgin.team_name,
        fgin.org_code,
        fgin.org_name,
        fgin.company_code,
        fgin.company_name,
        fgin.allow_val_range,
        fgin.allow_val_range1,
        fgin.validflag,
        fgin.valid_user,
        fgin.valid_date,
        fgin.using_user,
        fgin.using_date,
        fgin.tenant_id,
        fgin.create_user,
        fgin.create_date,
        fgin.update_user,
        fgin.update_date,
        sum(fgin.hourly_output) AS hourly_output,
        sum(fgin.c_lot_qty) AS c_lot_quantity,
        fgin.plan_begin_date,
        fgin.workorder_type
    FROM (

        -- ========== Q1: ASN入库单 (常规共享表) - 正数 ==========
        -- 驱动: wmwf(idx_wmwf_batch) → waod(idx_004) → warod(idx_005)
        -- [P0-I5] whm_reservoir_area: IDX_NAME(org_id,warehouse_id,code,inv_org_code) 全4列命中 UNIQUE
        SELECT
            waod.warehouse_id AS company_id,
            wepm.`item_code` AS material_code,
            wepm.`name` AS material_name,
            pme.id AS material_id,
            pme.item_type AS material_type,
            `waod`.`incoming_batch` AS material_batch,
            (`warod`.`receive_qty`) AS quantity,
            `wmwf`.`plan_begin_date` AS `date`,
            fr.region_name AS production_line,
            m.id AS team_id,
            mb.team_code,
            mb.team_name,
            waod.cargo_owner_code AS org_code,
            rio.NAME AS org_name,
            rio.company_code,
            rio.company_name,
            i.allow_val_range,
            i1.allow_val_range AS allow_val_range1,
            '1' AS validflag,
            'rbac_user_superuser' AS valid_user,
            NULL AS valid_date,
            'rbac_user_superuser' AS using_user,
            NULL AS using_date,
            'root' AS tenant_id,
            'rbac_user_superuser' AS create_user,
            NOW() AS create_date,
            'rbac_user_superuser' AS update_user,
            NULL AS update_date,
            (`warod`.`receive_qty`) * l.hourly_output AS hourly_output,
            -- [v3] 通过 whm_reservoir_area 判断合格品库区 (Q1不变)
            CASE WHEN wra.is_ng_sub_library = '0' THEN (`warod`.`receive_qty`) ELSE 0 END AS c_lot_qty,
            wmwf.plan_begin_date,
            wmwf.workorder_type
        FROM
            `st_materialbatch_workorder_fg` `wmwf`
            JOIN `wms_asn_order_detail` `waod` 
                ON `waod`.`incoming_batch` = `wmwf`.`material_batch`
                AND `waod`.`warehouse_id` IN (SELECT enterprise_id FROM st_enterprise_online)
            LEFT JOIN `wms_asn_receive_order_detail` `warod` 
                ON `warod`.`asn_detail_id` = `waod`.`id`
                AND warod.warehouse_id = waod.warehouse_id
            INNER JOIN `wms_asn_order` `wao` 
                ON `waod`.`asn_id` = `wao`.`id`
                AND wao.warehouse_id = waod.warehouse_id
                AND `wao`.`type_id` IN ('CJ_RK_OTHER', 'WGRK')
            LEFT JOIN `res_inv_org` `rio` 
                ON `waod`.`cargo_owner_code` = `rio`.`inv_org_code`
            LEFT JOIN `wms_ext_part_md` `wepm` 
                ON `warod`.`warehouse_id` = `wepm`.`warehouse_id`
                AND `warod`.`item_code` = `wepm`.`item_code`
                AND `warod`.`cargo_owner_code` = `wepm`.`cargo_owner_code`
            LEFT JOIN mes_base_scheduling_item m ON m.id = warod.lot_att23
            LEFT JOIN mes_base_team mb ON mb.id = m.team_id
            INNER JOIN part_md_ext pme 
                ON waod.warehouse_id = pme.factory_id
                AND rio.id = pme.org_id
                AND wepm.`item_code` = pme.CODE
                AND pme.item_type = 'FG'
            LEFT JOIN item_ext_prop i 
                ON i.item_id = pme.id AND i.ext_prop_name = '费用系数'
            LEFT JOIN item_ext_prop i1 
                ON i1.item_id = pme.id AND i1.ext_prop_name = '工艺分类'
            LEFT JOIN lm_st_cost_coefficient_2025 l 
                ON i.allow_val_range = l.share_type_name
            LEFT JOIN mes_workorder_t mwt 
                ON mwt.workorder_no = wmwf.source_code AND mwt.validflag = '1'
            LEFT JOIN factory_region fr ON fr.id = mwt.product_line
            -- [P0-I5] 库区判断: IDX_NAME(org_id, warehouse_id, code, inv_org_code) 全4列命中 UNIQUE
            LEFT JOIN `whm_reservoir_area` `wra` 
                ON wra.org_id = warod.warehouse_id
                AND wra.warehouse_id = warod.warehouse_id
                AND wra.code = warod.lot_att02
                AND wra.inv_org_code = warod.cargo_owner_code
        WHERE 1 = 1
            AND `wmwf`.`workorder_type` IN ('out_product', 'trial_product')
            AND `wmwf`.`plan_begin_date` >= '2026-01-01'

        UNION ALL

        -- ========== Q2: 发货出库单 (常规共享表) - 负数 ==========
        -- [v4] 通过 wms_pick_detail + wms_stock_attr 获取实际库区
        -- [P0-I1] 驱动表倒转: wdo(idx_003) → wdod(idx_006) → wmwf(idx_fg_batch)
        -- [P0-I6] wpd.idx_003(warehouse_id, dispatch_order_detail_id), wsa.idx_001(lot_code) UNIQUE
        SELECT
            wdod.warehouse_id AS company_id,
            wepm.`item_code` AS material_code,
            wepm.`name` AS material_name,
            pme.id AS material_id,
            pme.item_type AS material_type,
            `wdod`.`erp_lot` AS material_batch,
            (`wpd`.`qty` * -1) AS quantity,
            `wmwf`.`plan_begin_date` AS `date`,
            fr.region_name AS production_line,
            m.id AS team_id,
            mb.team_code,
            mb.team_name,
            rio.inv_org_code AS org_code,
            rio.NAME AS org_name,
            rio.company_code,
            rio.company_name,
            i.allow_val_range,
            i1.allow_val_range AS allow_val_range1,
            '1' AS validflag,
            'rbac_user_superuser' AS valid_user,
            NULL AS valid_date,
            'rbac_user_superuser' AS using_user,
            NULL AS using_date,
            'root' AS tenant_id,
            'rbac_user_superuser' AS create_user,
            NOW() AS create_date,
            'rbac_user_superuser' AS update_user,
            NULL AS update_date,
            (`wpd`.`qty` * -1) * l.hourly_output AS hourly_output,
            -- [v4] 通过 pick_detail→stock_attr→reservoir_area 判断合格品库区
            CASE WHEN wra.is_ng_sub_library = '0' THEN (`wpd`.`qty` * -1) ELSE 0 END AS c_lot_qty,
            wmwf.plan_begin_date,
            wmwf.workorder_type
        FROM
            `wms_dispatch_order` `wdo`
            INNER JOIN `wms_dispatch_order_detail` `wdod` 
                ON `wdod`.`dispatch_order_id` = `wdo`.`id`
                AND `wdod`.`warehouse_id` = `wdo`.`warehouse_id`
            -- [v4] 引入 wms_pick_detail 获取拣货记录
            INNER JOIN `wms_pick_detail` `wpd` 
                ON `wpd`.`dispatch_order_detail_id` = `wdod`.`id`
                AND `wpd`.`warehouse_id` = `wdod`.`warehouse_id`
            -- [v4→v5] wms_stock_attr: FORCE INDEX idx_002(warehouse_id,lot_code) 前缀列先缩小范围
            INNER JOIN `wms_stock_attr` FORCE INDEX (`idx_wms_stock_attr_002`) `wsa` 
                ON `wsa`.`warehouse_id` = `wpd`.`warehouse_id`
                AND `wsa`.`lot_code` = `wpd`.`lot_code`
            INNER JOIN `st_materialbatch_workorder_fg` `wmwf` 
                ON `wmwf`.`material_batch` = `wdod`.`erp_lot`
            LEFT JOIN `res_inv_org` `rio` 
                ON `wdod`.`cargo_owner_code` = `rio`.`inv_org_code`
            LEFT JOIN `wms_ext_part_md` `wepm` 
                ON `wdod`.`warehouse_id` = `wepm`.`warehouse_id`
                AND `wdod`.`item_code` = `wepm`.`item_code`
                AND `wdod`.`cargo_owner_code` = `wepm`.`cargo_owner_code`
            LEFT JOIN mes_base_scheduling_item m ON m.id = wdo.res_emp_code
            LEFT JOIN mes_base_team mb ON mb.id = m.team_id
            INNER JOIN part_md_ext pme 
                ON wdod.warehouse_id = pme.factory_id
                AND rio.id = pme.org_id
                AND wepm.`item_code` = pme.CODE
                AND pme.item_type = 'FG'
            LEFT JOIN item_ext_prop i 
                ON i.item_id = pme.id AND i.ext_prop_name = '费用系数'
            LEFT JOIN item_ext_prop i1 
                ON i1.item_id = pme.id AND i1.ext_prop_name = '工艺分类'
            LEFT JOIN lm_st_cost_coefficient_2025 l 
                ON i.allow_val_range = l.share_type_name
            LEFT JOIN mes_workorder_t mwt 
                ON mwt.workorder_no = wmwf.source_code AND mwt.validflag = '1'
            LEFT JOIN factory_region fr ON fr.id = mwt.product_line
            -- [v4] 库区判断: 使用 wsa.lot_att02 而非 wdod.lot_att02
            LEFT JOIN `whm_reservoir_area` `wra` 
                ON wra.org_id = wsa.warehouse_id
                AND wra.warehouse_id = wsa.warehouse_id
                AND wra.code = wsa.lot_att02
                AND wra.inv_org_code = wsa.cargo_owner_code
        WHERE 1 = 1
            AND `wdo`.`receipt_large_category_code` = 'WGTH'
            AND `wdo`.`warehouse_id` IN (SELECT enterprise_id FROM st_enterprise_online)
            AND `wmwf`.`workorder_type` IN ('out_product', 'trial_product')
            AND `wmwf`.`plan_begin_date` >= '2026-01-01'

    ) fgin
    GROUP BY
        fgin.company_id,
        fgin.material_id,
        fgin.material_batch,
        fgin.production_line,
        fgin.team_id,
        fgin.org_code,
        fgin.allow_val_range,
        fgin.allow_val_range1;

    -- ==============================================================
    -- [P0-2] Q3+Q4 使用2025分表，游标循环+动态SQL
    -- ==============================================================
    OPEN curid;
    read_loop: LOOP
        FETCH curid INTO ids;
        IF done THEN
            LEAVE read_loop;
        END IF;

        SET @concatsql = CONCAT(
'   INSERT INTO lm_st_product_inbound(
        company_id,material_code,material_name,material_id,material_type,material_batch,
        quantity,date,production_line,team_id,team_code,team_name,
        org_code,org_name,company_code,company_name,allow_val_range,allow_val_range1,
        validflag,valid_user,valid_date,using_user,using_date,tenant_id,
        create_user,create_date,update_user,update_date,
        hourly_output,c_lot_quantity,plan_begin_date,workorder_type
    )
    SELECT
        fgin.company_id,
        fgin.material_code,
        fgin.material_name,
        fgin.material_id,
        fgin.material_type,
        fgin.material_batch,
        sum(fgin.quantity) AS quantity,
        date_format(fgin.date, ''%Y-%m-%d'') AS `date`,
        fgin.production_line,
        fgin.team_id,
        fgin.team_code,
        fgin.team_name,
        fgin.org_code,
        fgin.org_name,
        fgin.company_code,
        fgin.company_name,
        fgin.allow_val_range,
        fgin.allow_val_range1,
        fgin.validflag,
        fgin.valid_user,
        fgin.valid_date,
        fgin.using_user,
        fgin.using_date,
        fgin.tenant_id,
        fgin.create_user,
        fgin.create_date,
        fgin.update_user,
        fgin.update_date,
        sum(fgin.hourly_output) AS hourly_output,
        sum(fgin.c_lot_qty) AS c_lot_quantity,
        fgin.plan_begin_date,
        fgin.workorder_type
    FROM (

        -- ========== Q3: ASN入库单 (2025分表) - 正数 ==========
        -- [P0-I5] whm_reservoir_area: IDX_NAME 全4列命中 UNIQUE
        SELECT
            waod.warehouse_id AS company_id,
            wepm.`item_code` AS material_code,
            wepm.`name` AS material_name,
            pme.id AS material_id,
            pme.item_type AS material_type,
            `waod`.`incoming_batch` AS material_batch,
            (`warod`.`receive_qty`) AS quantity,
            `wmwf`.`plan_begin_date` AS `date`,
            fr.region_name AS production_line,
            m.id AS team_id,
            mb.team_code,
            mb.team_name,
            waod.cargo_owner_code AS org_code,
            rio.NAME AS org_name,
            rio.company_code,
            rio.company_name,
            i.allow_val_range,
            i1.allow_val_range AS allow_val_range1,
            ''1'' AS validflag,
            ''rbac_user_superuser'' AS valid_user,
            NULL AS valid_date,
            ''rbac_user_superuser'' AS using_user,
            NULL AS using_date,
            ''root'' AS tenant_id,
            ''rbac_user_superuser'' AS create_user,
            NOW() AS create_date,
            ''rbac_user_superuser'' AS update_user,
            NULL AS update_date,
            (`warod`.`receive_qty`) * l.hourly_output AS hourly_output,
            CASE WHEN wra.is_ng_sub_library = ''0'' THEN (`warod`.`receive_qty`) ELSE 0 END AS c_lot_qty,
            wmwf.plan_begin_date,
            wmwf.workorder_type
        FROM
            `st_materialbatch_workorder_fg` `wmwf`
            JOIN wms_asn_order_detail2025_',ids,' `waod` 
                ON `waod`.`incoming_batch` = `wmwf`.`material_batch`
                AND waod.warehouse_id = ''',ids,'''
            LEFT JOIN wms_asn_receive_order_detail2025_',ids,' `warod` 
                ON `warod`.`asn_detail_id` = `waod`.`id`
                AND warod.warehouse_id = ''',ids,'''
            INNER JOIN wms_asn_order2025_',ids,' `wao` 
                ON `waod`.`asn_id` = `wao`.`id`
                AND wao.warehouse_id = ''',ids,'''
                AND `wao`.`type_id` IN (''CJ_RK_OTHER'', ''WGRK'')
            LEFT JOIN `res_inv_org` `rio` 
                ON `waod`.`cargo_owner_code` = `rio`.`inv_org_code`
            LEFT JOIN `wms_ext_part_md` `wepm` 
                ON `warod`.`warehouse_id` = `wepm`.`warehouse_id`
                AND `warod`.`item_code` = `wepm`.`item_code`
                AND `warod`.`cargo_owner_code` = `wepm`.`cargo_owner_code`
            LEFT JOIN mes_base_scheduling_item m ON m.id = warod.lot_att23
            LEFT JOIN mes_base_team mb ON mb.id = m.team_id
            INNER JOIN part_md_ext pme 
                ON waod.warehouse_id = pme.factory_id
                AND wepm.`item_code` = pme.CODE
                AND rio.id = pme.org_id
                AND pme.item_type = ''FG''
            LEFT JOIN item_ext_prop i 
                ON i.item_id = pme.id AND i.ext_prop_name = ''费用系数''
            LEFT JOIN item_ext_prop i1 
                ON i1.item_id = pme.id AND i1.ext_prop_name = ''工艺分类''
            LEFT JOIN lm_st_cost_coefficient_2025 l 
                ON i.allow_val_range = l.share_type_name
            LEFT JOIN mes_workorder_t mwt 
                ON mwt.workorder_no = wmwf.source_code AND mwt.validflag = ''1''
            LEFT JOIN factory_region fr ON fr.id = mwt.product_line
            -- [P0-I5] 库区判断: IDX_NAME 全4列命中 UNIQUE
            LEFT JOIN `whm_reservoir_area` `wra` 
                ON wra.org_id = warod.warehouse_id
                AND wra.warehouse_id = warod.warehouse_id
                AND wra.code = warod.lot_att02
                AND wra.inv_org_code = warod.cargo_owner_code
        WHERE 1 = 1
            AND `wmwf`.`workorder_type` IN (''out_product'', ''trial_product'')
            AND `wmwf`.`plan_begin_date` >= ''2026-01-01''

        UNION ALL

        -- ========== Q4: 发货出库单 (2025分表) - 负数 ==========
        -- [v4] 通过 wms_pick_detail2025 + wms_stock_attr2025 获取实际库区
        SELECT
            wdod.warehouse_id AS company_id,
            wepm.`item_code` AS material_code,
            wepm.`name` AS material_name,
            pme.id AS material_id,
            pme.item_type AS material_type,
            `wdod`.`erp_lot` AS material_batch,
            (`wpd`.`qty` * -1) AS quantity,
            `wmwf`.`plan_begin_date` AS `date`,
            fr.region_name AS production_line,
            m.id AS team_id,
            mb.team_code,
            mb.team_name,
            rio.inv_org_code AS org_code,
            rio.NAME AS org_name,
            rio.company_code,
            rio.company_name,
            i.allow_val_range,
            i1.allow_val_range AS allow_val_range1,
            ''1'' AS validflag,
            ''rbac_user_superuser'' AS valid_user,
            NULL AS valid_date,
            ''rbac_user_superuser'' AS using_user,
            NULL AS using_date,
            ''root'' AS tenant_id,
            ''rbac_user_superuser'' AS create_user,
            NOW() AS create_date,
            ''rbac_user_superuser'' AS update_user,
            NULL AS update_date,
            (`wpd`.`qty` * -1) * l.hourly_output AS hourly_output,
            -- [v4] 通过 pick_detail→stock_attr→reservoir_area 判断合格品库区
            CASE WHEN wra.is_ng_sub_library = ''0'' THEN (`wpd`.`qty` * -1) ELSE 0 END AS c_lot_qty,
            wmwf.plan_begin_date,
            wmwf.workorder_type
        FROM
            wms_dispatch_order2025_',ids,' `wdo`
            INNER JOIN wms_dispatch_order_detail2025_',ids,' `wdod` 
                ON `wdod`.`dispatch_order_id` = `wdo`.`id`
                AND `wdod`.`warehouse_id` = `wdo`.`warehouse_id`
            -- [v4] 引入 wms_pick_detail2025 分表
            INNER JOIN wms_pick_detail2025_',ids,' `wpd` 
                ON `wpd`.`dispatch_order_detail_id` = `wdod`.`id`
                AND `wpd`.`warehouse_id` = `wdod`.`warehouse_id`
            -- [v4→v5] wms_stock_attr2025 分表: FORCE INDEX idx_002(warehouse_id,lot_code)
            INNER JOIN wms_stock_attr2025_',ids,' FORCE INDEX (`idx_wms_stock_attr_002`) `wsa` 
                ON `wsa`.`warehouse_id` = `wpd`.`warehouse_id`
                AND `wsa`.`lot_code` = `wpd`.`lot_code`
            INNER JOIN `st_materialbatch_workorder_fg` `wmwf` 
                ON `wmwf`.`material_batch` = `wdod`.`erp_lot`
            LEFT JOIN `res_inv_org` `rio` 
                ON `wdod`.`cargo_owner_code` = `rio`.`inv_org_code`
            LEFT JOIN `wms_ext_part_md` `wepm` 
                ON `wdod`.`warehouse_id` = `wepm`.`warehouse_id`
                AND `wdod`.`item_code` = `wepm`.`item_code`
                AND `wdod`.`cargo_owner_code` = `wepm`.`cargo_owner_code`
            LEFT JOIN mes_base_scheduling_item m ON m.id = wdo.res_emp_code
            LEFT JOIN mes_base_team mb ON mb.id = m.team_id
            INNER JOIN part_md_ext pme 
                ON wdod.warehouse_id = pme.factory_id
                AND wepm.`item_code` = pme.CODE
                AND rio.id = pme.org_id
                AND pme.item_type = ''FG''
            LEFT JOIN item_ext_prop i 
                ON i.item_id = pme.id AND i.ext_prop_name = ''费用系数''
            LEFT JOIN item_ext_prop i1 
                ON i1.item_id = pme.id AND i1.ext_prop_name = ''工艺分类''
            LEFT JOIN lm_st_cost_coefficient_2025 l 
                ON i.allow_val_range = l.share_type_name
            LEFT JOIN mes_workorder_t mwt 
                ON mwt.workorder_no = wmwf.source_code AND mwt.validflag = ''1''
            LEFT JOIN factory_region fr ON fr.id = mwt.product_line
            -- [v4] 库区判断: 使用 wsa.lot_att02 而非 wdod.lot_att02
            LEFT JOIN `whm_reservoir_area` `wra` 
                ON wra.org_id = wsa.warehouse_id
                AND wra.warehouse_id = wsa.warehouse_id
                AND wra.code = wsa.lot_att02
                AND wra.inv_org_code = wsa.cargo_owner_code
        WHERE 1 = 1
            AND `wdo`.`receipt_large_category_code` = ''WGTH''
            AND wdod.warehouse_id = ''',ids,'''
            AND `wmwf`.`workorder_type` IN (''out_product'', ''trial_product'')
            AND `wmwf`.`plan_begin_date` >= ''2026-01-01''

    ) fgin
    GROUP BY
        fgin.company_id,
        fgin.material_id,
        fgin.material_batch,
        fgin.production_line,
        fgin.team_id,
        fgin.org_code,
        fgin.allow_val_range,
        fgin.allow_val_range1;'
        );

        PREPARE stmt FROM @concatsql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;

    END LOOP;

    CLOSE curid;

    SET end_execution_time = NOW();
    INSERT INTO event_logs (event_name, start_execution_time, end_execution_time, status, message)
    VALUES ('daily_lm_st_product_inbound_event', start_execution_time, end_execution_time, 'SUCCESS', 'Event executed successfully');

END;
 
END;;
delimiter ;
