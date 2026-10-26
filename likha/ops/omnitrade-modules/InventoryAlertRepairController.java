package com.crossborder.erp.warehouse.repair;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.format.DateTimeParseException;
import java.util.*;
import static com.crossborder.erp.warehouse.repair.RepairSupport.*;

@RestController
@RequestMapping("/inventory/alert")
public class InventoryAlertRepairController {
    private final RepairSupport s;
    public InventoryAlertRepairController(RepairSupport s) { this.s=s; }
    private static final String RULE_TABLE="erp_inventory.t_repair_alert_rule";
    private static final String RECORD_TABLE="erp_inventory.t_repair_alert_record";
    private static final String REPLENISH_TABLE="erp_inventory.t_repair_alert_replenishment";
    private static final String RULE="""
        SELECT id,product_id productId,sku,product_name productName,warehouse_id warehouseId,
        warehouse_name warehouseName,safe_stock safeStock,alert_stock alertStock,min_stock minStock,
        alert_type alertType,advance_days advanceDays,notify_type notifyType,notify_to notifyTo,
        email_list emailList,phone_list phoneList,enabled,remark,create_time createTime,update_time updateTime
        FROM erp_inventory.t_repair_alert_rule
        """;
    private static final String RECORD="""
        SELECT id,rule_id ruleId,inventory_id inventoryId,product_id productId,sku,product_name productName,
        warehouse_id warehouseId,warehouse_name warehouseName,current_stock currentStock,alert_stock alertStock,
        safe_stock safeStock,alert_type alertType,message,status,handler_id handlerId,handler_name handlerName,
        handle_time handleTime,handle_remark handleRemark,notified,create_time createTime,update_time updateTime
        FROM erp_inventory.t_repair_alert_record
        """;
    private static final String REPLENISH="""
        SELECT id,alert_id alertId,rule_id ruleId,inventory_id inventoryId,product_id productId,sku,
        product_name productName,warehouse_id warehouseId,warehouse_name warehouseName,current_stock currentStock,
        safe_stock safeStock,suggested_quantity suggestedQuantity,estimated_price estimatedPrice,status,
        confirm_user_id confirmUserId,confirm_user_name confirmUserName,confirm_time confirmTime,remark,
        suggested_date suggestedDate,expected_arrival_date expectedArrivalDate,create_time createTime,update_time updateTime
        FROM erp_inventory.t_repair_alert_replenishment
        """;
    private static final Set<String> RULE_FIELDS=Set.of("id","tenantId","productId","sku","productName","warehouseId","warehouseName","safeStock","alertStock","minStock","alertType","advanceDays","notifyType","notifyTypes","notifyTo","emailList","phoneList","enabled","remark","createTime","updateTime");

    private static ResponseStatusException conflict(String text) { return new ResponseStatusException(HttpStatus.CONFLICT,text); }
    private static long positive(Object value) { long n=number(value); if(n<=0) throw bad("ID必须为正整数"); return n; }
    private static long quantity(Object value) { long n=number(value); if(n<0 || n>Integer.MAX_VALUE) throw bad("库存阈值必须是0至2147483647的整数"); return n; }
    private static String text(Object value,int limit) { String v=str(value).trim(); if(v.length()>limit) throw bad("字段内容过长"); return v; }
    private static int flag(Object value) { if(Boolean.TRUE.equals(value)||"true".equalsIgnoreCase(str(value))||"1".equals(str(value))) return 1; if(Boolean.FALSE.equals(value)||"false".equalsIgnoreCase(str(value))||"0".equals(str(value))) return 0; throw bad("enabled必须为布尔值"); }
    private void guard() { s.one("SELECT id FROM erp_inventory.t_repair_inventory_guard WHERE id=1 FOR UPDATE"); }
    private Map<String,Object> actor(HttpServletRequest request) {
        Object id=request.getAttribute("repairUserId");
        if(id==null) throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,"请重新登录");
        return s.one("SELECT id,COALESCE(NULLIF(real_name,''),username) name FROM erp_user.t_user WHERE id=? AND status=1 AND deleted=0",positive(id));
    }
    private static String remark(Map<String,String> params,Map<String,Object> body) { return text(body!=null && body.containsKey("remark")?body.get("remark"):params.get("remark"),1000); }
    private Map<String,String> paging(Map<String,String> p) {
        Map<String,String> result=new HashMap<>(p);
        long page=positive(p.getOrDefault("current",p.getOrDefault("page","1"))),size=positive(p.getOrDefault("size","20"));
        if(page>1000000 || size>100) throw bad("分页范围过大，size不能超过100");
        result.put("current",Long.toString(page)); result.put("size",Long.toString(size)); return result;
    }
    private String filters(Map<String,String> p,List<Object> args,boolean records) {
        String where=" WHERE 1=1"+s.eq("warehouse_id","warehouseId",p,args)+s.eq("status","status",p,args)+s.like("sku","sku",p,args);
        if(records) where+=s.eq("alert_type","alertType",p,args);
        return where;
    }
    @GetMapping("/settings") public Map<String,Object> settings() {
        Map<String,Object> result=s.one("SELECT enable_alert enableAlert,default_advance_days defaultAdvanceDays,default_notify_to defaultNotifyTo FROM erp_inventory.t_repair_alert_settings WHERE id=1");
        result.put("enableAlert",flag(result.get("enableAlert"))==1); result.put("defaultNotifyTypes",List.of("SYSTEM")); return result;
    }
    @PutMapping("/settings") public Object saveSettings(@RequestBody Map<String,Object> body,HttpServletRequest request) {
        if(!Set.of("enableAlert","defaultAdvanceDays","defaultNotifyTypes","defaultNotifyTo").containsAll(body.keySet())) throw bad("请求包含不支持的预警设置");
        return s.atomic(()->{
            guard(); Map<String,Object> user=actor(request),value=new HashMap<>(settings()); value.putAll(body);
            int enabled=flag(value.get("enableAlert")); long days=positive(value.get("defaultAdvanceDays")); if(days>365) throw bad("默认提前天数不能超过365");
            if(!List.of("SYSTEM").equals(value.get("defaultNotifyTypes"))) throw bad("当前仅支持SYSTEM站内预警，邮件短信尚未接入");
            String recipients=text(value.get("defaultNotifyTo"),1000); if(!recipients.isEmpty()) throw bad("当前站内预警由管理后台统一查看，不支持指定通知人");
            s.db.update("UPDATE erp_inventory.t_repair_alert_settings SET enable_alert=?,default_advance_days=?,default_notify_to=?,updated_by=?,update_time=NOW() WHERE id=1",enabled,days,recipients,user.get("id"));
            return settings();
        });
    }
    @GetMapping("/rules") public Object rules(@RequestParam Map<String,String> p) {
        List<Object> args=new ArrayList<>(); String where=" WHERE deleted=0"+s.eq("warehouse_id","warehouseId",p,args)+s.like("sku","sku",p,args);
        if(!p.getOrDefault("enabled","").isBlank()) { where+=" AND enabled=?"; args.add(flag(p.get("enabled"))); }
        Map<String,Object> page=s.page(RULE,where,args,paging(p)," ORDER BY create_time DESC,id DESC");
        List<Map<String,Object>> records=new ArrayList<>();
        for(Object row:(List<?>)page.get("records")) {
            Map<String,Object> record=new LinkedHashMap<>(); ((Map<?,?>)row).forEach((key,value)->record.put(str(key),value)); records.add(ruleResult(record));
        }
        page.put("records",records);
        return page;
    }
    private Map<String,Object> ruleResult(Map<String,Object> row) { row.put("enabled",flag(row.get("enabled"))==1); return row; }
    @GetMapping("/rules/enabled") public Object enabledRules() { List<Map<String,Object>> rows=s.rows(RULE+" WHERE deleted=0 AND enabled=1 ORDER BY id"); rows.forEach(this::ruleResult); return rows; }
    @GetMapping("/rule/{id}") public Object rule(@PathVariable("id") long id) { return ruleResult(s.one(RULE+" WHERE id=? AND deleted=0",id)); }
    @PostMapping("/rule") public Object createRule(@RequestBody Map<String,Object> body) { return saveRule(null,body); }
    @PutMapping("/rule/{id}") public Object updateRule(@PathVariable("id") long id,@RequestBody Map<String,Object> body) { return saveRule(id,body); }
    private Object saveRule(Long existingId,Map<String,Object> body) {
        if(!RULE_FIELDS.containsAll(body.keySet())) throw bad("请求包含不支持的规则字段");
        return s.atomic(()->{
            guard(); long id=existingId==null?s.id():positive(existingId);
            Map<String,Object> defaults=settings();
            Map<String,Object> value=new HashMap<>(map("minStock",0,"advanceDays",defaults.get("defaultAdvanceDays"),"enabled",true,"alertType","LOW","notifyType","SYSTEM","notifyTo",defaults.get("defaultNotifyTo")));
            if(existingId!=null) value.putAll(s.one(RULE+" WHERE id=? AND deleted=0 FOR UPDATE",id));
            value.putAll(body); s.required(value,"warehouseId","safeStock","alertStock");
            long warehouse=positive(value.get("warehouseId")),safe=quantity(value.get("safeStock")),alert=quantity(value.get("alertStock")),min=quantity(value.get("minStock"));
            if(min>alert || alert>safe) throw bad("阈值须满足最低库存≤预警库存≤安全库存");
            long days=quantity(value.get("advanceDays")); if(days>365) throw bad("提前天数不能超过365");
            String type=text(value.get("alertType"),20); if(!Set.of("LOW","OUT","SAFE").contains(type)) throw bad("仅支持LOW、OUT、SAFE库存阈值预警，不支持过期预警");
            String notify=text(value.get("notifyType"),100); if(!"SYSTEM".equals(notify)) throw bad("当前仅支持SYSTEM站内预警，邮件短信通知尚未接入");
            Map<String,Object> w=s.one("SELECT warehouse_name FROM erp_warehouse.t_warehouse WHERE id=? AND deleted=0 AND status=1",warehouse);
            String sku=text(value.get("sku"),100),name=""; Object product=null;
            if(!sku.isEmpty()) {
                Map<String,Object> productRow=s.one("SELECT sk.sku_code,sk.product_id,COALESCE(p.product_name,sk.sku_name,sk.sku_code) product_name FROM erp_product.t_product_sku sk JOIN erp_product.t_product p ON p.id=sk.product_id AND p.deleted=0 WHERE sk.sku_code=? AND sk.deleted=0 AND sk.status=1",sku);
                product=productRow.get("product_id"); sku=str(productRow.get("sku_code")); name=str(productRow.get("product_name"));
            } else if(value.get("productId")!=null && !str(value.get("productId")).isBlank() && !"0".equals(str(value.get("productId")))) {
                product=positive(value.get("productId")); name=str(s.one("SELECT product_name FROM erp_product.t_product WHERE id=? AND deleted=0",product).get("product_name"));
            }
            if(s.count("SELECT COUNT(*) FROM "+RULE_TABLE+" WHERE warehouse_id=? AND sku=? AND product_id <=> ? AND deleted=0 AND id<>?",warehouse,sku,product,id)>0) throw conflict("此仓库商品范围已有规则，请编辑原规则");
            Object[] values={product,sku,name,warehouse,w.get("warehouse_name"),safe,alert,min,type,days,notify,text(value.get("notifyTo"),1000),text(value.get("emailList"),1000),text(value.get("phoneList"),1000),flag(value.get("enabled")),text(value.get("remark"),1000),id};
            if(existingId==null) s.db.update("INSERT INTO "+RULE_TABLE+" (product_id,sku,product_name,warehouse_id,warehouse_name,safe_stock,alert_stock,min_stock,alert_type,advance_days,notify_type,notify_to,email_list,phone_list,enabled,remark,id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",values);
            else {
                s.db.update("UPDATE "+RULE_TABLE+" SET product_id=?,sku=?,product_name=?,warehouse_id=?,warehouse_name=?,safe_stock=?,alert_stock=?,min_stock=?,alert_type=?,advance_days=?,notify_type=?,notify_to=?,email_list=?,phone_list=?,enabled=?,remark=?,update_time=NOW() WHERE id=?",values);
                closeRuleAlerts(id,"规则已变更，请重新检查库存");
            }
            return ruleResult(s.one(RULE+" WHERE id=?",id));
        });
    }
    private void closeRuleAlerts(long id,String message) {
        s.db.update("UPDATE "+REPLENISH_TABLE+" SET status='CANCELLED',remark=?,update_time=NOW() WHERE rule_id=? AND status='PENDING'",message,id);
        s.db.update("UPDATE "+RECORD_TABLE+" SET status='IGNORED',handle_remark=?,handle_time=NOW(),update_time=NOW() WHERE rule_id=? AND status='PENDING'",message,id);
    }
    @DeleteMapping("/rule/{id}") public Object deleteRule(@PathVariable("id") long id) {
        return s.atomic(()->{ guard(); s.changed(s.db.update("UPDATE "+RULE_TABLE+" SET deleted=1,enabled=0,update_time=NOW() WHERE id=? AND deleted=0",id)); closeRuleAlerts(id,"规则已删除"); return map("id",id,"deleted",true); });
    }
    @GetMapping("/records") public Object records(@RequestParam Map<String,String> p) { List<Object> args=new ArrayList<>(); return s.page(RECORD,filters(p,args,true),args,paging(p)," ORDER BY create_time DESC,id DESC"); }
    @GetMapping("/records/pending") public Object pendingRecords(@RequestParam Map<String,String> p) { Map<String,String> values=new HashMap<>(p); values.put("status","PENDING"); List<Object> args=new ArrayList<>(); return s.rows(RECORD+filters(values,args,true)+" ORDER BY create_time,id LIMIT 1000",args.toArray()); }
    @PostMapping("/record/{id}/handle") public Object handle(@PathVariable("id") long id,@RequestParam Map<String,String> p,@RequestBody(required=false) Map<String,Object> b,HttpServletRequest request) { return transitionRecord(id,"HANDLED",remark(p,b),request); }
    @PostMapping("/record/{id}/ignore") public Object ignore(@PathVariable("id") long id,@RequestParam Map<String,String> p,@RequestBody(required=false) Map<String,Object> b,HttpServletRequest request) { return transitionRecord(id,"IGNORED",remark(p,b),request); }
    private Object transitionRecord(long id,String status,String remark,HttpServletRequest request) {
        return s.atomic(()->{
            guard(); Map<String,Object> user=actor(request),record=s.one(RECORD+" WHERE id=? FOR UPDATE",id);
            if(!"PENDING".equals(record.get("status"))) throw conflict("仅待处理预警可以处理或忽略");
            s.db.update("UPDATE "+RECORD_TABLE+" SET status=?,handler_id=?,handler_name=?,handle_time=NOW(),handle_remark=?,update_time=NOW() WHERE id=? AND status='PENDING'",status,user.get("id"),user.get("name"),remark,id);
            return s.one(RECORD+" WHERE id=?",id);
        });
    }
    @PostMapping("/record/{id}/replenishment") public Object createReplenishment(@PathVariable("id") long id,@RequestBody(required=false) Map<String,Object> body,HttpServletRequest request) {
        if(body!=null && !Set.of("suggestedQuantity").containsAll(body.keySet())) throw bad("请求包含不支持的补货字段");
        Long requested=body!=null && body.containsKey("suggestedQuantity")?positive(body.get("suggestedQuantity")):null;
        if(requested!=null) quantity(requested);
        return s.atomic(()->{
            guard(); actor(request);
            if(!Boolean.TRUE.equals(settings().get("enableAlert"))) throw conflict("库存预警已停用");
            Map<String,Object> record=s.one(RECORD+" WHERE id=? FOR UPDATE",id);
            if(!"PENDING".equals(record.get("status"))) throw conflict("仅待处理预警可以生成补货建议");
            checkInventory(number(record.get("inventoryId")));
            record=s.one(RECORD+" WHERE id=? FOR UPDATE",id);
            if(!"PENDING".equals(record.get("status"))) throw conflict("库存已恢复或规则不再适用，请刷新预警");
            if(!Set.of("LOW","OUT").contains(str(record.get("alertType")))) throw conflict("仅库存不足或缺货预警需要补货建议");
            List<Map<String,Object>> existing=s.rows(REPLENISH+" WHERE (alert_id=? OR (rule_id=? AND inventory_id=? AND status='PENDING')) ORDER BY create_time DESC FOR UPDATE",id,record.get("ruleId"),record.get("inventoryId"));
            if(!existing.isEmpty()) {
                Map<String,Object> suggestion=existing.get(0);
                if("CANCELLED".equals(suggestion.get("status"))) throw conflict("此预警的补货建议已取消，请核实后重新检查库存");
                if(requested!=null) {
                    if(!"PENDING".equals(suggestion.get("status"))) throw conflict("补货建议已确认，不能修改数量");
                    s.db.update("UPDATE "+REPLENISH_TABLE+" SET suggested_quantity=?,update_time=NOW() WHERE id=? AND status='PENDING'",requested,suggestion.get("id"));
                    s.db.update("INSERT INTO erp_inventory.t_repair_alert_quantity_override (suggestion_id,quantity) VALUES (?,?) ON DUPLICATE KEY UPDATE quantity=VALUES(quantity)",suggestion.get("id"),requested);
                    return s.one(REPLENISH+" WHERE id=?",suggestion.get("id"));
                }
                return suggestion;
            }
            throw conflict("未生成补货建议，请核实库存和规则");
        });
    }
    @GetMapping("/replenishments") public Object replenishments(@RequestParam Map<String,String> p) { List<Object> args=new ArrayList<>(); return s.page(REPLENISH,filters(p,args,false),args,paging(p)," ORDER BY create_time DESC,id DESC"); }
    @GetMapping("/replenishments/pending") public Object pendingReplenishments(@RequestParam Map<String,String> p) { Map<String,String> values=new HashMap<>(p); values.put("status","PENDING"); List<Object> args=new ArrayList<>(); return s.rows(REPLENISH+filters(values,args,false)+" ORDER BY create_time,id LIMIT 1000",args.toArray()); }
    @PostMapping("/replenishment/{id}/confirm") public Object confirm(@PathVariable("id") long id,@RequestParam Map<String,String> p,@RequestBody(required=false) Map<String,Object> b,HttpServletRequest request) { return transitionReplenishment(id,"CONFIRMED",remark(p,b),request); }
    @PostMapping("/replenishment/{id}/cancel") public Object cancel(@PathVariable("id") long id,@RequestParam Map<String,String> p,@RequestBody(required=false) Map<String,Object> b,HttpServletRequest request) { return transitionReplenishment(id,"CANCELLED",remark(p,b),request); }
    private Object transitionReplenishment(long id,String status,String remark,HttpServletRequest request) {
        return s.atomic(()->{
            guard(); Map<String,Object> user=actor(request),record=s.one(REPLENISH+" WHERE id=? FOR UPDATE",id);
            if(!"PENDING".equals(record.get("status"))) throw conflict("仅待确认补货建议可以确认或取消");
            s.db.update("UPDATE "+REPLENISH_TABLE+" SET status=?,confirm_user_id=?,confirm_user_name=?,confirm_time=NOW(),remark=?,update_time=NOW() WHERE id=? AND status='PENDING'",status,user.get("id"),user.get("name"),remark,id);
            return s.one(REPLENISH+" WHERE id=?",id);
        });
    }
    @GetMapping("/statistics/realtime") public Object realtime(@RequestParam Map<String,String> p) {
        List<Object> args=new ArrayList<>(); String where=" WHERE 1=1"+s.eq("warehouse_id","warehouseId",p,args);
        Map<String,Object> result=s.one("SELECT COUNT(*) totalAlerts,COALESCE(SUM(status='PENDING'),0) pendingAlerts,COALESCE(SUM(status='HANDLED'),0) handledAlerts,COALESCE(SUM(status='IGNORED'),0) ignoredAlerts,COALESCE(SUM(create_time>=CURDATE()),0) todayAlerts,COALESCE(SUM(status='PENDING' AND alert_type='LOW'),0) lowStockCount,COALESCE(SUM(status='PENDING' AND alert_type='OUT'),0) outOfStockCount,COALESCE(SUM(status='PENDING' AND alert_type='SAFE'),0) safeStockWarningCount FROM "+RECORD_TABLE+where,args.toArray());
        result.put("pendingCount",result.get("pendingAlerts")); return result;
    }
    @GetMapping("/statistics/trend") public Object trend(@RequestParam Map<String,String> p) {
        long days=positive(p.getOrDefault("days","7")); if(days>366) throw bad("趋势范围不能超过366天");
        LocalDate today=LocalDate.parse(str(s.one("SELECT DATE_FORMAT(CURDATE(),'%Y-%m-%d') today").get("today"))),start=today.minusDays(days-1);
        List<Object> args=new ArrayList<>(List.of(start.toString(),today.plusDays(1).toString()));
        String where=" WHERE create_time>=? AND create_time<?"+s.eq("warehouse_id","warehouseId",p,args);
        List<Map<String,Object>> rows=s.rows("SELECT DATE_FORMAT(create_time,'%Y-%m-%d') date,COUNT(*) totalCount,SUM(status='PENDING') pendingCount,SUM(status='HANDLED') handledCount,SUM(status='IGNORED') ignoredCount FROM "+RECORD_TABLE+where+" GROUP BY DATE_FORMAT(create_time,'%Y-%m-%d') ORDER BY date",args.toArray());
        Map<String,Map<String,Object>> byDate=new HashMap<>(); for(Map<String,Object> row:rows) byDate.put(str(row.get("date")),row);
        List<Map<String,Object>> result=new ArrayList<>();
        for(LocalDate date=start;!date.isAfter(today);date=date.plusDays(1)) result.add(byDate.getOrDefault(date.toString(),map("date",date.toString(),"totalCount",0,"pendingCount",0,"handledCount",0,"ignoredCount",0)));
        return result;
    }
    private static LocalDateTime timestamp(String value) { try { return LocalDateTime.parse(value.replace(' ','T')); } catch(DateTimeParseException e) { throw bad("时间必须使用yyyy-MM-dd HH:mm:ss格式"); } }
    @GetMapping("/statistics/distribution") public Object distribution(@RequestParam Map<String,String> p) {
        List<Object> args=new ArrayList<>(); String where=" WHERE 1=1"+s.eq("warehouse_id","warehouseId",p,args);
        LocalDateTime start=null,end=null;
        if(!p.getOrDefault("startTime","").isBlank()) { start=timestamp(p.get("startTime")); where+=" AND create_time>=?"; args.add(java.sql.Timestamp.valueOf(start)); }
        if(!p.getOrDefault("endTime","").isBlank()) { end=timestamp(p.get("endTime")); where+=" AND create_time<?"; args.add(java.sql.Timestamp.valueOf(end)); }
        if(start!=null && end!=null && !start.isBefore(end)) throw bad("开始时间必须早于结束时间");
        Map<String,Object> result=map("LOW",0,"OUT",0,"SAFE",0);
        for(Map<String,Object> row:s.rows("SELECT alert_type,COUNT(*) count FROM "+RECORD_TABLE+where+" GROUP BY alert_type",args.toArray())) result.put(str(row.get("alert_type")),row.get("count"));
        return result;
    }
    @PostMapping("/check") public Object check(@RequestParam Map<String,String> p,@RequestBody(required=false) Map<String,Object> body) {
        Map<String,Object> values=new HashMap<>(p); if(body!=null) values.putAll(body);
        return s.atomic(()->{
            guard(); List<Object> args=new ArrayList<>(); String where=" WHERE w.deleted=0 AND w.status=1";
            if(values.get("inventoryId")!=null && !str(values.get("inventoryId")).isBlank()) { where+=" AND i.id=?"; args.add(positive(values.get("inventoryId"))); }
            if(values.get("warehouseId")!=null && !str(values.get("warehouseId")).isBlank()) { where+=" AND i.warehouse_id=?"; args.add(positive(values.get("warehouseId"))); }
            if(values.get("sku")!=null && !str(values.get("sku")).isBlank()) { where+=" AND i.sku_code=?"; args.add(text(values.get("sku"),100)); }
            if(values.get("productId")!=null && !str(values.get("productId")).isBlank()) { where+=" AND EXISTS (SELECT 1 FROM erp_product.t_product_sku sk WHERE sk.sku_code=i.sku_code AND sk.product_id=? AND sk.deleted=0)"; args.add(positive(values.get("productId"))); }
            List<Map<String,Object>> inventories=s.rows("SELECT i.id FROM erp_inventory.t_inventory i JOIN erp_warehouse.t_warehouse w ON w.id=i.warehouse_id"+where+" ORDER BY i.id LIMIT 10001",args.toArray());
            if(inventories.size()>10000) throw bad("单次最多检查10000条库存，请按仓库或SKU筛选");
            if(inventories.isEmpty() && (values.containsKey("inventoryId") || values.containsKey("sku"))) throw missing();
            long created=0,updated=0,recovered=0;
            for(Map<String,Object> inventory:inventories) { Map<String,Object> checked=checkInventory(number(inventory.get("id"))); created+=number(checked.get("created")); updated+=number(checked.get("updated")); recovered+=number(checked.get("recovered")); }
            return map("checked",inventories.size(),"created",created,"updated",updated,"recovered",recovered);
        });
    }

    // 与库存写入共用事务和锁顺序，库存值与展示名称始终读取数据库。
    @Transactional
    public Map<String,Object> checkInventory(long inventoryId) {
        guard(); Map<String,Object> inventory=s.one("SELECT id,sku_code,warehouse_id,available_qty FROM erp_inventory.t_inventory WHERE id=? FOR UPDATE",inventoryId);
        Map<String,Object> meta=s.one("""
            SELECT i.sku_code sku,i.warehouse_id warehouseId,i.available_qty currentStock,
            sk.product_id productId,COALESCE(p.product_name,sk.sku_name,i.sku_code) productName,w.warehouse_name warehouseName
            FROM erp_inventory.t_inventory i JOIN erp_warehouse.t_warehouse w ON w.id=i.warehouse_id AND w.deleted=0
            LEFT JOIN erp_product.t_product_sku sk ON sk.sku_code=i.sku_code AND sk.deleted=0
            LEFT JOIN erp_product.t_product p ON p.id=sk.product_id AND p.deleted=0 WHERE i.id=?
            """,inventoryId);
        long stock=quantity(inventory.get("available_qty"));
        if(!Boolean.TRUE.equals(settings().get("enableAlert"))) return map("inventoryId",inventoryId,"currentStock",stock,"created",0,"updated",0,"recovered",0,"disabled",true);
        List<Map<String,Object>> rules=s.rows(RULE+" WHERE deleted=0 AND enabled=1 AND warehouse_id=? AND (sku=? OR (sku='' AND (product_id=? OR product_id IS NULL))) ORDER BY id",meta.get("warehouseId"),meta.get("sku"),meta.get("productId"));
        int specificity=0; for(Map<String,Object> r:rules) specificity=Math.max(specificity,scope(r));
        Set<Long> activeRules=new HashSet<>(),replenishmentRules=new HashSet<>(); long created=0,updated=0,recovered=0;
        for(Map<String,Object> r:rules) {
            if(scope(r)!=specificity) continue;
            long ruleId=number(r.get("id")),min=quantity(r.get("minStock")),alert=quantity(r.get("alertStock")),safe=quantity(r.get("safeStock"));
            String type=stock<=min?"OUT":stock<=alert?"LOW":stock<safe?"SAFE":null;
            if(type==null) continue;
            activeRules.add(ruleId);
            List<Map<String,Object>> existing=s.rows(RECORD+" WHERE inventory_id=? AND rule_id=? AND status='PENDING' FOR UPDATE",inventoryId,ruleId);
            String message="SKU="+meta.get("sku")+"，当前可用库存="+stock+"，预警库存="+alert+"，安全库存="+safe;
            long alertId;
            if(existing.isEmpty()) {
                alertId=s.id();
                s.db.update("INSERT INTO "+RECORD_TABLE+" (id,rule_id,inventory_id,product_id,sku,product_name,warehouse_id,warehouse_name,current_stock,alert_stock,safe_stock,alert_type,message) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",alertId,ruleId,inventoryId,meta.get("productId"),meta.get("sku"),meta.get("productName"),meta.get("warehouseId"),meta.get("warehouseName"),stock,alert,safe,type,message);
                created++;
            } else {
                alertId=number(existing.get(0).get("id"));
                s.db.update("UPDATE "+RECORD_TABLE+" SET current_stock=?,alert_stock=?,safe_stock=?,alert_type=?,message=?,update_time=NOW() WHERE id=?",stock,alert,safe,type,message,alertId); updated++;
            }
            if("LOW".equals(type)||"OUT".equals(type)) {
                replenishmentRules.add(ruleId);
                long shortage=Math.max(1,safe-stock),suggested=shortage+shortage/5;
                s.db.update("INSERT INTO "+REPLENISH_TABLE+" (id,alert_id,rule_id,inventory_id,product_id,sku,product_name,warehouse_id,warehouse_name,current_stock,safe_stock,suggested_quantity,expected_arrival_date) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,DATE_ADD(NOW(),INTERVAL ? DAY)) ON DUPLICATE KEY UPDATE current_stock=IF(status='PENDING',VALUES(current_stock),current_stock),safe_stock=IF(status='PENDING',VALUES(safe_stock),safe_stock),suggested_quantity=IF(status='PENDING',VALUES(suggested_quantity),suggested_quantity)",s.id(),alertId,ruleId,inventoryId,meta.get("productId"),meta.get("sku"),meta.get("productName"),meta.get("warehouseId"),meta.get("warehouseName"),stock,safe,suggested,r.get("advanceDays"));
            } else s.db.update("UPDATE "+REPLENISH_TABLE+" SET status='CANCELLED',remark='库存已恢复至预警线以上',update_time=NOW() WHERE alert_id=? AND status='PENDING'",alertId);
        }
        s.db.update("UPDATE "+REPLENISH_TABLE+" r JOIN erp_inventory.t_repair_alert_quantity_override q ON q.suggestion_id=r.id SET r.suggested_quantity=q.quantity WHERE r.inventory_id=? AND r.status='PENDING'",inventoryId);
        for(Map<String,Object> pending:s.rows("SELECT id,rule_id FROM "+RECORD_TABLE+" WHERE inventory_id=? AND status='PENDING' FOR UPDATE",inventoryId)) {
            if(activeRules.contains(number(pending.get("rule_id")))) continue;
            s.db.update("UPDATE "+RECORD_TABLE+" SET status='HANDLED',handle_time=NOW(),handle_remark='库存已恢复或规则不再适用，系统自动关闭',update_time=NOW() WHERE id=?",pending.get("id"));
            recovered++;
        }
        for(Map<String,Object> pending:s.rows("SELECT id,rule_id,safe_stock FROM "+REPLENISH_TABLE+" WHERE inventory_id=? AND status='PENDING' FOR UPDATE",inventoryId)) {
            if(!replenishmentRules.contains(number(pending.get("rule_id"))))
                s.db.update("UPDATE "+REPLENISH_TABLE+" SET status='CANCELLED',remark='库存已恢复至安全库存或规则不再适用',update_time=NOW() WHERE id=?",pending.get("id"));
        }
        return map("inventoryId",inventoryId,"currentStock",stock,"created",created,"updated",updated,"recovered",recovered);
    }
    private static int scope(Map<String,Object> rule) { return !str(rule.get("sku")).isBlank()?2:rule.get("productId")!=null?1:0; }
}
