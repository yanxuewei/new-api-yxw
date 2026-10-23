package com.crossborder.erp.warehouse.repair;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import static com.crossborder.erp.warehouse.repair.RepairSupport.*;

@RestController
@RequestMapping("/api")
public class InventoryRepairController {
    private final RepairSupport s;
    public InventoryRepairController(RepairSupport s) { this.s = s; }
    private static final String INVENTORY = """
        SELECT i.id,i.sku_code skuCode,COALESCE(p.product_name,sk.sku_name,i.sku_code) productName,
        i.warehouse_id warehouseId,w.warehouse_name warehouseName,il.location_id locationId,l.location_code locationCode,
        i.available_qty availableQty,i.locked_qty lockedQty,i.total_qty totalQty,COALESCE(i.safety_stock,0) safetyStock,
        ROUND(COALESCE(f.sales,0)/30,2) dailySales,
        CASE WHEN COALESCE(f.sales,0)>0 THEN ROUND(i.available_qty*30/f.sales,1) ELSE NULL END turnoverDays,
        f.lastInTime,f.lastOutTime
        FROM erp_inventory.t_inventory i
        JOIN erp_warehouse.t_warehouse w ON w.id=i.warehouse_id AND w.deleted=0
        LEFT JOIN erp_product.t_product_sku sk ON sk.sku_code=i.sku_code AND sk.deleted=0
        LEFT JOIN erp_product.t_product p ON p.id=sk.product_id AND p.deleted=0
        LEFT JOIN erp_inventory.t_repair_inventory_location il ON il.inventory_id=i.id
        LEFT JOIN erp_warehouse.t_repair_warehouse_location l ON l.id=il.location_id AND l.deleted=0
        LEFT JOIN (SELECT sku_code,warehouse_id,
          SUM(CASE WHEN change_type='out' AND create_time>=DATE_SUB(NOW(),INTERVAL 30 DAY)
            AND order_no IS NOT NULL AND order_no NOT LIKE 'REPAIR-%' THEN ABS(change_qty) ELSE 0 END) sales,
          MAX(CASE WHEN change_type='in' THEN create_time END) lastInTime,
          MAX(CASE WHEN change_type='out' THEN create_time END) lastOutTime
          FROM erp_inventory.t_inventory_log GROUP BY sku_code,warehouse_id) f
          ON f.sku_code=i.sku_code AND f.warehouse_id=i.warehouse_id
        """;
    private static final String WAREHOUSE = """
        SELECT w.id,w.warehouse_code warehouseCode,w.warehouse_name warehouseName,w.warehouse_type warehouseType,
        w.country,w.province,w.city,w.address,w.contact_person contactPerson,w.contact_phone contactPhone,
        COALESCE(e.email,'') email,w.status,COALESCE(e.is_default,0) isDefault,w.create_time createTime,w.update_time updateTime
        FROM erp_warehouse.t_warehouse w LEFT JOIN erp_warehouse.t_repair_warehouse_extra e ON e.warehouse_id=w.id
        """;
    private static final String LOCATION = """
        SELECT id,warehouse_id warehouseId,location_code locationCode,location_type locationType,
        zone,row_code `row`,column_code `column`,level_code `level`,status
        FROM erp_warehouse.t_repair_warehouse_location
        """;
    private static final Set<String> WAREHOUSE_FIELDS = Set.of("id","warehouseCode","warehouseName","warehouseType","country","province","city","address","contactPerson","contactPhone","email","status","isDefault","createTime","updateTime");
    private static final Set<String> LOCATION_FIELDS = Set.of("id","warehouseId","locationCode","locationType","zone","row","column","level","status");

    private static ResponseStatusException conflict(String message) { return new ResponseStatusException(HttpStatus.CONFLICT,message); }
    private static long qty(Object value) { long n=number(value); if(n<0 || n>Integer.MAX_VALUE) throw bad("库存数量必须是非负整数且不能超过2147483647"); return n; }
    private static long positive(Object value) { long n=number(value); if(n<=0) throw bad("ID或数量必须大于0"); return n; }
    private static String text(Object value,int max) { String v=str(value).trim(); if(v.length()>max) throw bad("字段内容过长"); return v; }
    private static int flag(Object value) { long n=number(value); if(n!=0 && n!=1) throw bad("状态必须为0或1"); return (int)n; }
    private static void whitelist(Map<String,Object> body,Set<String> keys) { if(body==null || !keys.containsAll(body.keySet())) throw bad("请求包含不支持的字段"); }
    private void guard() { s.one("SELECT id FROM erp_inventory.t_repair_inventory_guard WHERE id=1 FOR UPDATE"); }
    private Map<String,Object> lockInventory(long id) { return s.one("SELECT * FROM erp_inventory.t_inventory WHERE id=? FOR UPDATE",id); }
    private Map<String,Object> lockWarehouse(long id,boolean active) {
        Map<String,Object> w=s.one("SELECT * FROM erp_warehouse.t_warehouse WHERE id=? AND deleted=0 FOR UPDATE",id);
        if(active && number(w.get("status"))!=1) throw conflict("仓库已停用"); return w;
    }
    private void lockLocation(long id,long warehouseId) {
        Map<String,Object> l=s.one("SELECT * FROM erp_warehouse.t_repair_warehouse_location WHERE id=? AND deleted=0 FOR UPDATE",id);
        if(number(l.get("warehouse_id"))!=warehouseId || number(l.get("status"))!=1) throw bad("库位不属于目标仓库或已停用");
    }
    private String inventoryWhere(Map<String,String> p,List<Object> a) {
        String where=" WHERE 1=1"+s.eq("i.warehouse_id","warehouseId",p,a)+s.like("i.sku_code","skuCode",p,a);
        return where+switch(p.getOrDefault("status","")) {
            case "" -> "";
            case "normal" -> " AND i.available_qty>0 AND i.available_qty>=COALESCE(i.safety_stock,0)*3";
            case "warning" -> " AND i.available_qty>0 AND i.available_qty>=COALESCE(i.safety_stock,0)*2 AND i.available_qty<COALESCE(i.safety_stock,0)*3";
            case "danger" -> " AND i.available_qty>0 AND i.available_qty<COALESCE(i.safety_stock,0)*2";
            case "out" -> " AND i.available_qty=0";
            default -> throw bad("未知库存状态");
        };
    }
    @GetMapping("/inventory/stats") public Object stats() {
        return s.one("""
            SELECT COUNT(*) totalSku,
            COALESCE(SUM(i.available_qty>0 AND i.available_qty>=COALESCE(i.safety_stock,0)*3),0) normalStock,
            COALESCE(SUM(i.available_qty>0 AND i.available_qty<COALESCE(i.safety_stock,0)*3),0) lowStock,
            COALESCE(SUM(i.available_qty=0),0) outOfStock
            FROM erp_inventory.t_inventory i JOIN erp_warehouse.t_warehouse w ON w.id=i.warehouse_id AND w.deleted=0
            """);
    }
    @GetMapping("/inventory/list") public Object list(@RequestParam Map<String,String> p) {
        List<Object> a=new ArrayList<>(); return s.page(INVENTORY,inventoryWhere(p,a),a,p," ORDER BY i.id DESC");
    }
    @GetMapping("/inventory/{id:\\d+}") public Map<String,Object> detail(@PathVariable("id") long id) { return s.one(INVENTORY+" WHERE i.id=?",id); }
    @GetMapping("/inventory/{id:\\d+}/flows") public Object flows(@PathVariable("id") long id,@RequestParam Map<String,String> p) {
        Map<String,Object> i=detail(id);
        return s.page("SELECT id,create_time flowTime,change_type flowType,ABS(change_qty) quantity,order_no orderNo,remark,before_qty beforeQty,after_qty afterQty FROM erp_inventory.t_inventory_log",
            " WHERE sku_code=? AND warehouse_id=?",new ArrayList<>(List.of(i.get("skuCode"),i.get("warehouseId"))),p," ORDER BY create_time DESC,id DESC");
    }
    private void change(Map<String,Object> i,long available,String orderNo,String remark) {
        long old=qty(i.get("available_qty")),locked=qty(i.get("locked_qty"));
        if(qty(i.get("total_qty"))!=old+locked) throw conflict("既有库存数量不一致，请先核实数据");
        qty(available); long total=qty(available+locked),delta=available-old;
        s.db.update("UPDATE erp_inventory.t_inventory SET available_qty=?,total_qty=?,update_time=NOW() WHERE id=?",available,total,i.get("id"));
        s.db.update("INSERT INTO erp_inventory.t_inventory_log (id,sku_code,warehouse_id,change_type,change_qty,before_qty,after_qty,order_no,remark) VALUES (?,?,?,?,?,?,?,?,?)",
            s.id(),i.get("sku_code"),i.get("warehouse_id"),delta>=0?"in":"out",delta,old,available,orderNo,text(remark,500));
    }
    @PostMapping("/inventory/adjust") public Object adjust(@RequestBody Map<String,Object> b) {
        whitelist(b,Set.of("inventoryId","type","quantity","reason","remark")); s.required(b,"inventoryId","type","quantity","reason");
        return s.atomic(()->{
            guard(); Map<String,Object> i=lockInventory(positive(b.get("inventoryId"))); lockWarehouse(number(i.get("warehouse_id")),true);
            long amount=qty(b.get("quantity")),old=qty(i.get("available_qty"));
            long value=switch(str(b.get("type"))) { case "increase" -> old+amount; case "decrease" -> old-amount; case "set" -> amount; default -> throw bad("未知调整类型"); };
            change(i,value,"REPAIR-ADJ-"+s.id(),text(b.get("reason"),100)+" "+text(b.get("remark"),390));
            return detail(number(i.get("id")));
        });
    }
    private Map<String,Object> ensureInventory(String sku,long warehouse) {
        s.one("SELECT id FROM erp_product.t_product_sku WHERE sku_code=? AND deleted=0 AND status=1 FOR UPDATE",sku);
        s.db.update("INSERT INTO erp_inventory.t_inventory (id,sku_code,warehouse_id) VALUES (?,?,?) ON DUPLICATE KEY UPDATE id=id",s.id(),sku,warehouse);
        return s.one("SELECT * FROM erp_inventory.t_inventory WHERE sku_code=? AND warehouse_id=? FOR UPDATE",sku,warehouse);
    }
    private void assignLocation(Map<String,Object> inventory,long location,boolean explicitAssignment) {
        long id=number(inventory.get("id"));
        List<Map<String,Object>> existing=s.rows("SELECT location_id FROM erp_inventory.t_repair_inventory_location WHERE inventory_id=? FOR UPDATE",id);
        Long old=existing.isEmpty()?null:number(existing.get(0).get("location_id"));
        if(number(inventory.get("total_qty"))>0 && !Objects.equals(old,location) && !(explicitAssignment && old==null))
            throw conflict("该SKU在目标仓库已有其他库位库存；当前模型每仓库每SKU仅支持一个库位");
        s.db.update("INSERT INTO erp_inventory.t_repair_inventory_location (inventory_id,location_id) VALUES (?,?) ON DUPLICATE KEY UPDATE location_id=VALUES(location_id)",id,location);
    }
    @PostMapping("/inventory/transfer") public Object transfer(@RequestBody Map<String,Object> b) {
        whitelist(b,Set.of("fromInventoryId","toWarehouseId","toLocationId","quantity","remark"));
        s.required(b,"fromInventoryId","toWarehouseId","toLocationId","quantity");
        return s.atomic(()->{
            guard(); Map<String,Object> from=lockInventory(positive(b.get("fromInventoryId")));
            long target=positive(b.get("toWarehouseId")),location=positive(b.get("toLocationId")),amount=positive(b.get("quantity")); qty(amount);
            if(target==number(from.get("warehouse_id"))) throw bad("请选择不同的目标仓库");
            lockWarehouse(number(from.get("warehouse_id")),true); lockWarehouse(target,true); lockLocation(location,target);
            if(amount>qty(from.get("available_qty"))) throw conflict("可用库存不足，锁定库存不可调拨");
            Map<String,Object> to=ensureInventory(str(from.get("sku_code")),target); assignLocation(to,location,false);
            String order="REPAIR-TR-"+s.id(),remark=text(b.get("remark"),450);
            change(from,number(from.get("available_qty"))-amount,order,"调拨出库 "+remark);
            change(to,number(to.get("available_qty"))+amount,order,"调拨入库 "+remark);
            return map("orderNo",order,"fromInventoryId",from.get("id"),"toInventoryId",to.get("id"),"quantity",amount);
        });
    }
    @PostMapping("/inventory/import") public Object importInventory(@RequestBody List<Map<String,Object>> records) {
        if(records==null || records.isEmpty() || records.size()>1000) throw bad("每次导入须包含1至1000行");
        return s.atomic(()->{
            guard(); Set<String> seen=new HashSet<>(); String order="REPAIR-IMPORT-"+s.id();
            for(Map<String,Object> b:records) {
                whitelist(b,Set.of("skuCode","warehouseId","locationId","availableQty","totalQty","safetyStock","remark")); s.required(b,"skuCode","warehouseId");
                if(b.containsKey("availableQty")==b.containsKey("totalQty")) throw bad("每行必须且只能提供availableQty或totalQty");
                String sku=text(b.get("skuCode"),100); long warehouse=positive(b.get("warehouseId"));
                if(!seen.add(warehouse+":"+sku.toLowerCase(Locale.ROOT))) throw bad("导入存在重复仓库SKU");
                lockWarehouse(warehouse,true); Map<String,Object> i=ensureInventory(sku,warehouse);
                if(b.get("locationId")!=null) { long location=positive(b.get("locationId")); lockLocation(location,warehouse); assignLocation(i,location,true); }
                long value=b.containsKey("availableQty")?qty(b.get("availableQty")):qty(b.get("totalQty"))-qty(i.get("locked_qty"));
                change(i,value,order,"导入库存 "+text(b.get("remark"),450));
                if(b.containsKey("safetyStock")) s.db.update("UPDATE erp_inventory.t_inventory SET safety_stock=? WHERE id=?",qty(b.get("safetyStock")),i.get("id"));
            }
            return map("imported",records.size(),"orderNo",order);
        });
    }
    @GetMapping("/warehouse/list") public Object warehouses(@RequestParam Map<String,String> p) {
        List<Object> a=new ArrayList<>(); String where=" WHERE w.deleted=0"+s.eq("w.status","status",p,a);
        if(!p.getOrDefault("keyword","").isBlank()) { where+=" AND (w.warehouse_code LIKE ? OR w.warehouse_name LIKE ?)"; a.add("%"+p.get("keyword")+"%"); a.add(a.get(a.size()-1)); }
        return p.containsKey("current")?s.page(WAREHOUSE,where,a,p," ORDER BY w.id DESC"):s.rows(WAREHOUSE+where+" ORDER BY w.warehouse_name,w.id",a.toArray());
    }
    @GetMapping("/warehouse/{id:\\d+}") public Map<String,Object> warehouse(@PathVariable("id") long id) { return s.one(WAREHOUSE+" WHERE w.id=? AND w.deleted=0",id); }
    @PostMapping("/warehouse") public Object createWarehouse(@RequestBody Map<String,Object> b) { return saveWarehouse(b,false); }
    @PutMapping("/warehouse") public Object updateWarehouse(@RequestBody Map<String,Object> b) { return saveWarehouse(b,true); }
    private Object saveWarehouse(Map<String,Object> b,boolean update) {
        whitelist(b,WAREHOUSE_FIELDS);
        return s.atomic(()->{
            guard(); long id=update?positive(b.get("id")):s.id(); Map<String,Object> v=new HashMap<>();
            if(update) { lockWarehouse(id,false); v.putAll(warehouse(id)); } else { v.put("status",1); v.put("isDefault",0); }
            v.putAll(b); s.required(v,"warehouseCode","warehouseName","warehouseType");
            String type=text(v.get("warehouseType"),50); if(!Set.of("main","overseas","third_party").contains(type)) throw bad("未知仓库类型");
            String code=text(v.get("warehouseCode"),50),name=text(v.get("warehouseName"),200);
            int status=flag(v.get("status")),isDefault=flag(v.get("isDefault"));
            if(isDefault==1 && status==0) throw bad("默认仓库必须启用");
            if(s.count("SELECT COUNT(*) FROM erp_warehouse.t_warehouse WHERE warehouse_code=? AND id<>?",code,id)>0) throw conflict("仓库编码已存在");
            Object[] values={code,name,type,text(v.get("country"),100),text(v.get("province"),100),text(v.get("city"),100),text(v.get("address"),500),text(v.get("contactPerson"),100),text(v.get("contactPhone"),50),status,id};
            if(update) s.db.update("UPDATE erp_warehouse.t_warehouse SET warehouse_code=?,warehouse_name=?,warehouse_type=?,country=?,province=?,city=?,address=?,contact_person=?,contact_phone=?,status=?,update_time=NOW() WHERE id=?",values);
            else s.db.update("INSERT INTO erp_warehouse.t_warehouse (warehouse_code,warehouse_name,warehouse_type,country,province,city,address,contact_person,contact_phone,status,id) VALUES (?,?,?,?,?,?,?,?,?,?,?)",values);
            if(isDefault==1) s.db.update("UPDATE erp_warehouse.t_repair_warehouse_extra SET is_default=0 WHERE is_default=1");
            s.db.update("INSERT INTO erp_warehouse.t_repair_warehouse_extra (warehouse_id,email,is_default) VALUES (?,?,?) ON DUPLICATE KEY UPDATE email=VALUES(email),is_default=VALUES(is_default)",id,text(v.get("email"),200),isDefault);
            return warehouse(id);
        });
    }
    @DeleteMapping("/warehouse/{id:\\d+}") public Object deleteWarehouse(@PathVariable("id") long id) {
        return s.atomic(()->{
            guard(); lockWarehouse(id,false);
            if(s.count("SELECT COUNT(*) FROM erp_inventory.t_inventory WHERE warehouse_id=?",id)>0 ||
               s.count("SELECT COUNT(*) FROM erp_warehouse.t_repair_warehouse_location WHERE warehouse_id=? AND deleted=0",id)>0 ||
               s.count("SELECT COUNT(*) FROM erp_warehouse.t_warehouse_in_out WHERE warehouse_id=?",id)>0)
                throw conflict("仓库仍有关联库存、库位或出入库单，不能删除");
            s.db.update("UPDATE erp_warehouse.t_warehouse SET deleted=1,status=0,update_time=NOW() WHERE id=?",id);
            s.db.update("UPDATE erp_warehouse.t_repair_warehouse_extra SET is_default=0 WHERE warehouse_id=?",id);
            return map("id",id,"deleted",true);
        });
    }
    @GetMapping("/warehouse/{id:\\d+}/locations") public Object locations(@PathVariable("id") long id) { warehouse(id); return s.rows(LOCATION+" WHERE warehouse_id=? AND deleted=0 ORDER BY location_code,id",id); }
    @PostMapping("/warehouse/location") public Object createLocation(@RequestBody Map<String,Object> b) { return saveLocation(b,false); }
    @PutMapping("/warehouse/location") public Object updateLocation(@RequestBody Map<String,Object> b) { return saveLocation(b,true); }
    private Object saveLocation(Map<String,Object> b,boolean update) {
        whitelist(b,LOCATION_FIELDS);
        return s.atomic(()->{
            guard(); long id=update?positive(b.get("id")):s.id(); Map<String,Object> v=new HashMap<>(); long oldWarehouse=0;
            if(update) { v.putAll(s.one(LOCATION+" WHERE id=? AND deleted=0 FOR UPDATE",id)); oldWarehouse=number(v.get("warehouseId")); } else v.put("status",1);
            v.putAll(b); s.required(v,"warehouseId","locationCode","locationType"); long warehouse=positive(v.get("warehouseId"));
            if(update && warehouse!=oldWarehouse) throw bad("不能变更库位所属仓库"); lockWarehouse(warehouse,true);
            String code=text(v.get("locationCode"),100),type=text(v.get("locationType"),50); int status=flag(v.get("status"));
            if(status==0 && s.count("SELECT COUNT(*) FROM erp_inventory.t_repair_inventory_location il JOIN erp_inventory.t_inventory i ON i.id=il.inventory_id WHERE il.location_id=? AND (i.total_qty<>0 OR i.locked_qty<>0 OR i.available_qty<>0)",id)>0) throw conflict("库位仍有库存，不能停用");
            if(s.count("SELECT COUNT(*) FROM erp_warehouse.t_repair_warehouse_location WHERE warehouse_id=? AND location_code=? AND id<>?",warehouse,code,id)>0) throw conflict("库位编码已存在");
            Object[] values={warehouse,code,type,text(v.get("zone"),100),text(v.get("row"),100),text(v.get("column"),100),text(v.get("level"),100),status,id};
            if(update) s.db.update("UPDATE erp_warehouse.t_repair_warehouse_location SET warehouse_id=?,location_code=?,location_type=?,zone=?,row_code=?,column_code=?,level_code=?,status=?,update_time=NOW() WHERE id=?",values);
            else s.db.update("INSERT INTO erp_warehouse.t_repair_warehouse_location (warehouse_id,location_code,location_type,zone,row_code,column_code,level_code,status,id) VALUES (?,?,?,?,?,?,?,?,?)",values);
            return s.one(LOCATION+" WHERE id=?",id);
        });
    }
    @DeleteMapping("/warehouse/location/{id:\\d+}") public Object deleteLocation(@PathVariable("id") long id) {
        return s.atomic(()->{
            guard(); s.one(LOCATION+" WHERE id=? AND deleted=0 FOR UPDATE",id);
            if(s.count("SELECT COUNT(*) FROM erp_inventory.t_repair_inventory_location WHERE location_id=?",id)>0) throw conflict("库位已关联库存，不能删除");
            s.db.update("UPDATE erp_warehouse.t_repair_warehouse_location SET deleted=1,status=0,update_time=NOW() WHERE id=?",id);
            return map("id",id,"deleted",true);
        });
    }
    @GetMapping("/inventory/export") public ResponseEntity<byte[]> export(@RequestParam Map<String,String> p) throws java.io.IOException {
        List<Object> a=new ArrayList<>(); String where=inventoryWhere(p,a);
        List<Map<String,Object>> records=s.rows(INVENTORY+where+" ORDER BY i.id LIMIT 10001",a.toArray());
        if(records.size()>10000) throw bad("单次导出不能超过10000条，请缩小筛选范围");
        String[] fields={"id","skuCode","productName","warehouseId","warehouseName","locationId","locationCode","availableQty","lockedQty","totalQty","safetyStock","dailySales","turnoverDays","lastInTime","lastOutTime"};
        StringBuilder sheet=new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>");
        sheet.append("<row>"); for(String f:fields) cell(sheet,f); sheet.append("</row>");
        for(Map<String,Object> record:records) { sheet.append("<row>"); for(String f:fields) cell(sheet,record.get(f)); sheet.append("</row>"); } sheet.append("</sheetData></worksheet>");
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(ZipOutputStream zip=new ZipOutputStream(bytes,StandardCharsets.UTF_8)) {
            zip(zip,"[Content_Types].xml","<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>");
            zip(zip,"_rels/.rels","<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
            zip(zip,"xl/workbook.xml","<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"库存\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>");
            zip(zip,"xl/_rels/workbook.xml.rels","<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>");
            zip(zip,"xl/worksheets/sheet1.xml",sheet.toString());
        }
        return ResponseEntity.ok().header("Content-Type","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet").header("Content-Disposition","attachment; filename=inventory.xlsx").body(bytes.toByteArray());
    }
    private static void cell(StringBuilder out,Object value) {
        if(value instanceof Number) { out.append("<c><v>").append(value).append("</v></c>"); return; }
        String v=str(value).replaceAll("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]","").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;");
        out.append("<c t=\"inlineStr\"><is><t xml:space=\"preserve\">").append(v).append("</t></is></c>");
    }
    private static void zip(ZipOutputStream zip,String name,String value) throws java.io.IOException { zip.putNextEntry(new ZipEntry(name)); zip.write(value.getBytes(StandardCharsets.UTF_8)); zip.closeEntry(); }
    @RequestMapping(value={"/inventory/**","/warehouse/**"},method={RequestMethod.POST,RequestMethod.PUT,RequestMethod.PATCH,RequestMethod.DELETE})
    public Object unsupported() { throw new ResponseStatusException(HttpStatus.NOT_IMPLEMENTED,"该写入接口尚未实现"); }
}
