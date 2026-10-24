package com.crossborder.erp.warehouse.repair;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.stream.Collectors;

import static com.crossborder.erp.warehouse.repair.RepairSupport.*;

@RestController
@RequestMapping("/ai-center")
public class AiBusinessController {
    private final RepairSupport s;
    private static final BigDecimal MAX_PRICE = new BigDecimal("999999999");
    private static final String PRICE_BASIS = "仅按真实SKU成本加成：成本/(1-30%)；未计物流、税费、平台费用；商品表未提供币种，不作跨币种比较。";
    private static final String SALES_BASIS = "最近90日且不晚于当前时间的非删除订单及明细；仅PAID/SUCCESS付款或SHIPPED/COMPLETED/DELIVERED订单，排除取消、退款、退货；按明细internal_sku精确匹配sku_code，不将商品级编码分摊给多个SKU。";
    private static final String FORECAST_BASIS = SALES_BASIS + "观察期从窗口内首次合格销售日开始（含当天），至少14天且5个销售日；均值包含零销量日，未来30日保持均值，不是机器学习。补货=max(0,ceil(30*日均销量+安全库存-可用库存))；未接入在途采购数据，因此未扣减在途采购，创建采购前须人工核对。缺少库存记录时库存、补货及缺货天数均为null，需求预测独立计算。";
    private static final String SKU_SELECT = "SELECT sk.id,sk.sku_code sku,COALESCE(p.product_name,sk.sku_name,sk.sku_code) productName,sk.sale_price currentPrice,sk.cost_price costPrice,sk.create_time createTime FROM erp_product.t_product_sku sk JOIN erp_product.t_product p ON p.id=sk.product_id AND p.deleted=0 AND p.status=1 WHERE sk.deleted=0 AND sk.status=1";
    private static final String QUALIFIED = "o.deleted=0 AND oi.deleted=0 AND oi.quantity>0 AND o.create_time>=DATE_SUB(CURRENT_DATE(),INTERVAL 89 DAY) AND o.create_time<=NOW() AND oi.create_time<=NOW() AND (UPPER(o.payment_status) IN ('PAID','SUCCESS') OR UPPER(o.status) IN ('SHIPPED','COMPLETED','DELIVERED')) AND UPPER(COALESCE(o.status,'')) NOT IN ('CANCELLED','CANCELED','REFUNDED','REFUNDING','RETURNED','RETURNING','IN_CLAIM','CLOSED') AND UPPER(COALESCE(o.payment_status,'')) NOT IN ('REFUNDED','REFUNDING','PARTIALLY_REFUNDED','REFUND')";
    private static final String ORDER_SELECT = "SELECT CAST(o.id AS CHAR) id,o.internal_order_no orderNo,o.platform,o.order_amount orderAmount,o.product_amount productAmount,o.currency_code currency,o.status,o.payment_status paymentStatus,o.payment_time paymentTime,o.shipping_time shippingTime,CASE WHEN o.tracking_number IS NULL OR TRIM(o.tracking_number)='' THEN 0 ELSE 1 END hasTracking,o.create_time createTime FROM erp_order.t_order o WHERE o.deleted=0";

    public AiBusinessController(RepairSupport s) { this.s = s; }

    private static ResponseStatusException conflict(String message) { return new ResponseStatusException(HttpStatus.CONFLICT, message); }
    private static int bounded(Map<String,String> p, String key, int fallback, int min, int max) {
        if (!Set.of("limit","offset").containsAll(p.keySet())) throw bad("仅支持limit与offset参数；日期窗口固定为最近90日");
        String raw = p.get(key);
        if (raw == null) return fallback;
        try { int n = Integer.parseInt(raw); if (n >= min && n <= max) return n; }
        catch (NumberFormatException ignored) { }
        throw bad(key + "超出允许范围：" + min + "至" + max);
    }
    private static String sku(String value) {
        if (value == null || value.trim().isEmpty() || value.length() > 100 || value.chars().anyMatch(Character::isISOControl)) throw bad("SKU不合法");
        return value;
    }
    private static long positiveId(String value) { long n = number(value); if (n <= 0) throw bad("ID必须大于0"); return n; }
    private static BigDecimal decimal(Object value) { return value == null ? null : new BigDecimal(String.valueOf(value)); }
    private static BigDecimal zero(Object value) { BigDecimal v = decimal(value); return v == null ? BigDecimal.ZERO : v; }
    private static BigDecimal price(Object value, boolean allowZero) {
        String text = str(value);
        if (text.length() > 32 || !text.matches("[0-9]+(?:\\.[0-9]{1,2})?")) throw bad("价格须为最多两位小数的非负数");
        BigDecimal n = new BigDecimal(text);
        if (n.compareTo(allowZero ? BigDecimal.ZERO : new BigDecimal("0.01")) < 0 || n.compareTo(MAX_PRICE) > 0) throw bad("价格超出允许范围");
        return n.setScale(2, RoundingMode.UNNECESSARY);
    }
    private static void bodyKeys(Map<String,Object> body, String... keys) {
        if (body == null || !new HashSet<>(Arrays.asList(keys)).containsAll(body.keySet())) throw bad("请求包含不支持的字段");
    }
    private static String placeholders(int size) { return String.join(",", Collections.nCopies(size, "?")); }
    private static LocalDate date(Object value) {
        if (value instanceof Timestamp) return ((Timestamp)value).toLocalDateTime().toLocalDate();
        if (value instanceof LocalDateTime) return ((LocalDateTime)value).toLocalDate();
        if (value instanceof java.sql.Date) return ((java.sql.Date)value).toLocalDate();
        return LocalDate.parse(str(value).substring(0,10));
    }
    private List<Map<String,Object>> skus(Map<String,String> p) {
        int limit = bounded(p,"limit",100,1,500), offset = bounded(p,"offset",0,0,100000);
        List<Map<String,Object>> rows = s.rows(SKU_SELECT + " ORDER BY sk.id LIMIT ? OFFSET ?", limit, offset);
        if (!rows.isEmpty()) {
            Object[] keys = rows.stream().map(r -> r.get("sku")).toArray();
            if (!s.rows("SELECT sku_code FROM erp_product.t_product_sku WHERE deleted=0 AND sku_code IN (" + placeholders(keys.length) + ") GROUP BY sku_code HAVING COUNT(*)>1 LIMIT 1",keys).isEmpty()) throw conflict("SKU编码不唯一，请先修复商品资料");
        }
        return rows;
    }
    private Map<String,Object> findSku(String code) { return findSku(code,false); }
    private Map<String,Object> findSku(String code, boolean lock) {
        List<Map<String,Object>> matches = s.rows("SELECT id FROM erp_product.t_product_sku WHERE deleted=0 AND sku_code=? LIMIT 2" + (lock ? " FOR UPDATE" : ""),sku(code));
        if (matches.isEmpty()) throw missing();
        if (matches.size()>1) throw conflict("SKU编码不唯一，请先修复商品资料");
        return s.one(SKU_SELECT + " AND sk.id=?" + (lock ? " FOR UPDATE" : ""),matches.get(0).get("id"));
    }
    private Map<String,Object> pricingRow(Map<String,Object> row) {
        BigDecimal cost = decimal(row.get("costPrice"));
        BigDecimal suggested = cost == null || cost.signum() <= 0 ? null : cost.divide(new BigDecimal("0.70"),2,RoundingMode.HALF_UP);
        if (suggested != null && suggested.compareTo(MAX_PRICE) > 0) suggested = null;
        BigDecimal margin = suggested == null ? null : suggested.subtract(cost).divide(suggested,4,RoundingMode.HALF_UP).multiply(new BigDecimal("100"));
        return map("sku",row.get("sku"),"productName",row.get("productName"),"currentPrice",row.get("currentPrice"),"costPrice",cost,"suggestedPrice",suggested,"expectedMargin",margin,"strategy","COST_PLUS_30_PERCENT","currency","UNSPECIFIED","basis",PRICE_BASIS,"dataStatus",suggested == null ? "INSUFFICIENT_DATA" : "AVAILABLE");
    }

    @GetMapping("/pricing")
    public List<Map<String,Object>> pricing(@RequestParam Map<String,String> p) {
        return skus(p).stream().map(this::pricingRow).collect(Collectors.toList());
    }

    @PostMapping("/pricing/{sku}/apply")
    public Map<String,Object> apply(@PathVariable("sku") String code, @RequestBody Map<String,Object> body, HttpServletRequest req) {
        bodyKeys(body,"price","expectedPrice");
        BigDecimal next = price(body.get("price"),false);
        if (!body.containsKey("expectedPrice")) throw bad("必须提供expectedPrice防止覆盖并发变更");
        BigDecimal expected = body.get("expectedPrice") == null ? null : price(body.get("expectedPrice"),true);
        String key = sku(code);
        return s.atomic(() -> {
            Map<String,Object> row = findSku(key,true);
            BigDecimal current = decimal(row.get("currentPrice"));
            if (current == null ? expected != null : expected == null || current.compareTo(expected) != 0) throw conflict("价格已变更，请刷新后重试");
            if (current != null && current.compareTo(next) == 0) return map("sku",key,"previousPrice",current,"currentPrice",next,"changed",false,"currency","UNSPECIFIED");
            s.changed(s.db.update("UPDATE erp_product.t_product_sku SET sale_price=?,update_time=NOW() WHERE id=? AND deleted=0",next,row.get("id")));
            s.db.update("INSERT INTO erp_inventory.t_ai_price_history(sku_id,sku_code,previous_price,new_price,operator_id,basis,create_time) VALUES(?,?,?,?,?,?,NOW())",row.get("id"),key,current,next,req.getAttribute("repairUserId"),PRICE_BASIS);
            return map("sku",key,"previousPrice",current,"currentPrice",next,"changed",true,"currency","UNSPECIFIED","basis",PRICE_BASIS);
        });
    }

    @GetMapping("/pricing/{sku}/history")
    public List<Map<String,Object>> history(@PathVariable("sku") String code, @RequestParam Map<String,String> p) {
        findSku(code);
        return s.rows("SELECT id,sku_code sku,previous_price previousPrice,new_price newPrice,operator_id operatorId,basis,create_time createTime,'UNSPECIFIED' currency FROM erp_inventory.t_ai_price_history WHERE sku_code=? ORDER BY id DESC LIMIT ? OFFSET ?",code,bounded(p,"limit",100,1,500),bounded(p,"offset",0,0,100000));
    }

    private Map<String,Map<String,Object>> sales(List<Map<String,Object>> products) {
        Map<String,Map<String,Object>> result = new HashMap<>();
        if (products.isEmpty()) return result;
        Object[] keys = products.stream().map(r -> r.get("sku")).toArray();
        for (Map<String,Object> row : s.rows("SELECT sk.sku_code sku,SUM(oi.quantity) sales90d,COUNT(DISTINCT DATE(o.create_time)) salesDays,MIN(DATE(o.create_time)) firstSaleDate,CURRENT_DATE() observedThrough FROM erp_order.t_order_item oi JOIN erp_order.t_order o ON o.id=oi.order_id JOIN erp_product.t_product_sku sk ON sk.sku_code=oi.internal_sku AND sk.deleted=0 AND sk.status=1 WHERE " + QUALIFIED + " AND sk.sku_code IN (" + placeholders(keys.length) + ") GROUP BY sk.id,sk.sku_code",keys)) result.put(str(row.get("sku")),row);
        return result;
    }
    private List<Map<String,Object>> recommendations(List<Map<String,Object>> products) {
        Map<String,Map<String,Object>> sales = sales(products);
        Set<String> adopted = new HashSet<>();
        if (!products.isEmpty()) {
            Object[] keys = products.stream().map(r -> r.get("sku")).toArray();
            for (Map<String,Object> row : s.rows("SELECT sku_code FROM erp_inventory.t_ai_recommend_adoption WHERE sku_code IN (" + placeholders(keys.length) + ")",keys)) adopted.add(str(row.get("sku_code")));
        }
        List<Map<String,Object>> result = new ArrayList<>();
        for (Map<String,Object> product : products) {
            BigDecimal cost = decimal(product.get("costPrice")), sale = decimal(product.get("currentPrice"));
            BigDecimal margin = cost == null || cost.signum() < 0 || sale == null || sale.signum() <= 0 ? null : sale.subtract(cost).divide(sale,6,RoundingMode.HALF_UP).multiply(new BigDecimal("100"));
            BigDecimal units = zero(sales.getOrDefault(str(product.get("sku")), Collections.emptyMap()).get("sales90d"));
            BigDecimal salesScore = units.min(new BigDecimal("100")).multiply(new BigDecimal("0.60"));
            BigDecimal marginScore = margin == null ? BigDecimal.ZERO : margin.max(BigDecimal.ZERO).min(new BigDecimal("100")).multiply(new BigDecimal("0.40"));
            result.add(map("sku",product.get("sku"),"productName",product.get("productName"),"currentPrice",sale,"costPrice",cost,"sales90d",units,"grossMargin",margin == null ? null : margin.setScale(2,RoundingMode.HALF_UP),"score",salesScore.add(marginScore).setScale(2,RoundingMode.HALF_UP),"reason","评分=60%×min(90日销量,100)+40%×max(0,min(当前商品毛利率百分数,100))；缺失毛利按0分，不代表已实现利润。","adopted",adopted.contains(str(product.get("sku"))),"currency","UNSPECIFIED","basis",SALES_BASIS + "仅展示启用商品与SKU，在当前分页内按评分排序，并非全库Top排行。只使用内部销量及当前商品售价/成本，无外部市场、竞争或趋势数据；售价与成本币种未标明，毛利仅供人工核对。"));
        }
        result.sort((a,b) -> decimal(b.get("score")).compareTo(decimal(a.get("score"))));
        return result;
    }

    @GetMapping("/recommend")
    public List<Map<String,Object>> recommend(@RequestParam Map<String,String> p) { return recommendations(skus(p)); }

    @PostMapping("/recommend/refresh")
    public List<Map<String,Object>> refresh(@RequestParam Map<String,String> p) { return recommendations(skus(p)); }

    @PostMapping("/recommend/{sku}/adopt")
    public Map<String,Object> adopt(@PathVariable("sku") String code, HttpServletRequest req) {
        String key = sku(code);
        return s.atomic(() -> {
            Map<String,Object> product = findSku(key,true);
            s.db.update("INSERT INTO erp_inventory.t_ai_recommend_adoption(sku_id,sku_code,operator_id,create_time,update_time) VALUES(?,?,?,NOW(),NOW()) ON DUPLICATE KEY UPDATE operator_id=VALUES(operator_id),update_time=NOW()",product.get("id"),key,req.getAttribute("repairUserId"));
            return map("sku",key,"adopted",true,"productName",product.get("productName"));
        });
    }

    @GetMapping("/recommend/adopted")
    public List<Map<String,Object>> adopted(@RequestParam Map<String,String> p) {
        return s.rows("SELECT a.sku_code sku,COALESCE(p.product_name,sk.sku_name,a.sku_code) productName,a.operator_id operatorId,a.create_time createTime,a.update_time updateTime FROM erp_inventory.t_ai_recommend_adoption a JOIN erp_product.t_product_sku sk ON sk.id=a.sku_id AND sk.deleted=0 JOIN erp_product.t_product p ON p.id=sk.product_id AND p.deleted=0 ORDER BY a.update_time DESC,a.sku_id LIMIT ? OFFSET ?",bounded(p,"limit",100,1,500),bounded(p,"offset",0,0,100000));
    }

    private List<Map<String,Object>> inventoryRows(List<Map<String,Object>> products) {
        Map<String,Map<String,Object>> sales = sales(products), inventory = new HashMap<>();
        if (!products.isEmpty()) {
            Object[] keys = products.stream().map(r -> r.get("sku")).toArray();
            for (Map<String,Object> row : s.rows("SELECT sk.sku_code sku,SUM(i.available_qty) availableStock,SUM(i.locked_qty) lockedStock,SUM(i.total_qty) totalStock,SUM(COALESCE(i.safety_stock,0)) safetyStock FROM erp_inventory.t_inventory i JOIN erp_product.t_product_sku sk ON sk.sku_code=i.sku_code AND sk.deleted=0 AND sk.status=1 WHERE sk.sku_code IN (" + placeholders(keys.length) + ") GROUP BY sk.id,sk.sku_code",keys)) inventory.put(str(row.get("sku")),row);
        }
        List<Map<String,Object>> result = new ArrayList<>();
        for (Map<String,Object> product : products) {
            String code = str(product.get("sku"));
            Map<String,Object> st = sales.getOrDefault(code,Collections.emptyMap()), inv = inventory.getOrDefault(code,Collections.emptyMap());
            long observed = st.get("firstSaleDate") == null ? 0 : Math.min(90,ChronoUnit.DAYS.between(date(st.get("firstSaleDate")),date(st.get("observedThrough"))) + 1);
            long days = zero(st.get("salesDays")).longValue();
            BigDecimal units = zero(st.get("sales90d")), available = decimal(inv.get("availableStock")), safety = decimal(inv.get("safetyStock"));
            boolean sufficient = observed >= 14 && days >= 5;
            BigDecimal avg = sufficient ? units.divide(BigDecimal.valueOf(observed),8,RoundingMode.HALF_UP) : null;
            BigDecimal demand = avg == null ? null : units.multiply(new BigDecimal("30")).divide(BigDecimal.valueOf(observed),8,RoundingMode.HALF_UP);
            BigDecimal replenishment = demand == null || available == null || safety == null ? null : units.multiply(new BigDecimal("30")).add(safety.subtract(available).multiply(BigDecimal.valueOf(observed))).divide(BigDecimal.valueOf(observed),0,RoundingMode.CEILING).max(BigDecimal.ZERO);
            BigDecimal stockout = avg == null || avg.signum() <= 0 || available == null ? null : available.max(BigDecimal.ZERO).divide(avg,1,RoundingMode.HALF_UP);
            result.add(map("sku",code,"productName",product.get("productName"),"availableStock",available,"lockedStock",decimal(inv.get("lockedStock")),"totalStock",decimal(inv.get("totalStock")),"safetyStock",safety,"inventoryRecordExists",!inv.isEmpty(),"sales90d",units,"observationDays",observed,"salesDays",days,"dailySales",avg,"dataStatus",sufficient ? "AVAILABLE" : "INSUFFICIENT_DATA","predictedDemand",demand == null ? null : demand.setScale(2,RoundingMode.HALF_UP),"replenishmentQty",replenishment,"stockoutDays",stockout,"pendingPurchaseQty",null,"pendingPurchaseDeducted",false,"basis",FORECAST_BASIS));
        }
        return result;
    }

    @GetMapping("/inventory")
    public List<Map<String,Object>> inventory(@RequestParam Map<String,String> p) { return inventoryRows(skus(p)); }

    @GetMapping("/inventory/{sku}/forecast")
    public Map<String,Object> forecast(@PathVariable("sku") String code, @RequestParam Map<String,String> p) {
        if (!p.isEmpty()) throw bad("预测固定为未来30日，不支持日期或周期参数");
        Map<String,Object> row = inventoryRows(Collections.singletonList(findSku(code))).get(0);
        LocalDate today = date(s.one("SELECT CURRENT_DATE() today").get("today"));
        List<Map<String,Object>> points = new ArrayList<>();
        for (int i=1;i<=30;i++) points.add(map("date",today.plusDays(i).toString(),"demand",row.get("dailySales")));
        row.put("forecast",points);
        return row;
    }

    private List<Map<String,Object>> evaluate(List<Map<String,Object>> orders) {
        if (orders.isEmpty()) return orders;
        Object[] ids = orders.stream().map(r -> r.get("id")).toArray();
        Map<String,Map<String,Object>> items = new HashMap<>(), reviews = new HashMap<>();
        for (Map<String,Object> row : s.rows("SELECT order_id orderId,COUNT(*) itemCount,SUM(total_amount) detailAmount,COUNT(DISTINCT UPPER(TRIM(currency_code))) currencyCount,MIN(UPPER(TRIM(currency_code))) detailCurrency,SUM(CASE WHEN currency_code IS NULL OR TRIM(currency_code)='' OR total_amount IS NULL THEN 1 ELSE 0 END) incomplete FROM erp_order.t_order_item WHERE deleted=0 AND order_id IN (" + placeholders(ids.length) + ") GROUP BY order_id",ids)) items.put(str(row.get("orderId")),row);
        for (Map<String,Object> row : s.rows("SELECT order_id orderId,rule_key ruleKey,confirmation_status confirmationStatus,confirmed_by confirmedBy,confirmed_at confirmedAt FROM erp_inventory.t_ai_order_anomaly WHERE order_id IN (" + placeholders(ids.length) + ")",ids)) reviews.put(str(row.get("orderId")),row);
        List<Map<String,Object>> results = new ArrayList<>();
        for (Map<String,Object> order : orders) {
            Map<String,Object> row = new LinkedHashMap<>(order), detail = items.get(str(order.get("id"))), review = reviews.get(str(order.get("id")));
            List<Map<String,Object>> rules = new ArrayList<>();
            BigDecimal amount = decimal(order.get("orderAmount"));
            if (amount == null || amount.signum() <= 0) rules.add(map("code","NON_POSITIVE_AMOUNT","message","订单金额缺失或非正数","score",40));
            boolean comparable = detail != null && zero(detail.get("currencyCount")).intValue() == 1 && zero(detail.get("incomplete")).signum() == 0 && !str(order.get("currency")).trim().isEmpty() && str(order.get("currency")).trim().equalsIgnoreCase(str(detail.get("detailCurrency"))) && order.get("productAmount") != null;
            if (comparable && decimal(order.get("productAmount")).subtract(zero(detail.get("detailAmount"))).abs().compareTo(new BigDecimal("0.01")) > 0) rules.add(map("code","ITEM_AMOUNT_MISMATCH","message","同币种明细合计与订单商品金额相差超过0.01（不与含运税折扣的订单总额比较）","score",30));
            if (Set.of("PAID","SUCCESS").contains(str(order.get("paymentStatus")).toUpperCase(Locale.ROOT)) && order.get("paymentTime") == null) rules.add(map("code","PAID_WITHOUT_PAYMENT_TIME","message","已付款但缺少付款时间","score",20));
            if (Set.of("SHIPPED","COMPLETED","DELIVERED").contains(str(order.get("status")).toUpperCase(Locale.ROOT)) && zero(order.get("hasTracking")).signum() == 0) rules.add(map("code","SHIPPED_WITHOUT_TRACKING","message","已发货或完成但缺少物流单号","score",20));
            int score = Math.min(100,rules.stream().mapToInt(r -> ((Number)r.get("score")).intValue()).sum());
            String ruleKey = rules.stream().map(r -> str(r.get("code"))).collect(Collectors.joining(","));
            boolean current = review != null && ruleKey.equals(str(review.get("ruleKey")));
            row.remove("hasTracking");
            row.put("rules",rules); row.put("riskScore",score); row.put("riskLevel",score >= 60 ? "HIGH" : score >= 30 ? "MEDIUM" : score > 0 ? "LOW" : "NORMAL");
            row.put("anomalous",score > 0); row.put("ruleKey",ruleKey);
            row.put("confirmationStatus",current ? review.get("confirmationStatus") : "PENDING");
            row.put("confirmedBy",current ? review.get("confirmedBy") : null); row.put("confirmedAt",current ? review.get("confirmedAt") : null);
            row.put("amountComparison",comparable ? "COMPARED" : "SKIPPED_INCOMPLETE_OR_MIXED_CURRENCY");
            row.put("basis","确定性规则加分且封顶100；非模型概率；商品明细只在币种完整一致时核对。规则集合改变后旧确认不再适用。");
            results.add(row);
        }
        return results;
    }

    @GetMapping("/anomaly")
    public List<Map<String,Object>> anomalies(@RequestParam Map<String,String> p) {
        if (!Set.of("limit","offset","orderId").containsAll(p.keySet())) throw bad("仅支持limit、offset与orderId参数");
        Long orderId = p.containsKey("orderId") ? positiveId(p.get("orderId")) : null;
        Map<String,String> pagination = new HashMap<>(p);
        pagination.remove("orderId");
        int limit = bounded(pagination,"limit",100,1,500), offset = bounded(pagination,"offset",0,0,100000);
        if (orderId != null) {
            if (offset != 0) throw bad("精确订单查询不支持非零offset");
            return evaluate(s.rows(ORDER_SELECT + " AND o.id=?",orderId));
        }
        return evaluate(s.rows(ORDER_SELECT + " ORDER BY o.id DESC LIMIT ? OFFSET ?",limit,offset));
    }

    private void persistDetection(Map<String,Object> row) {
        s.db.update("INSERT INTO erp_inventory.t_ai_order_anomaly(order_id,rule_key,risk_score,confirmation_status,detected_at) VALUES(?,?,?,'PENDING',NOW()) ON DUPLICATE KEY UPDATE confirmation_status=IF(rule_key=VALUES(rule_key),confirmation_status,'PENDING'),confirmed_by=IF(rule_key=VALUES(rule_key),confirmed_by,NULL),confirmed_at=IF(rule_key=VALUES(rule_key),confirmed_at,NULL),rule_key=VALUES(rule_key),risk_score=VALUES(risk_score),detected_at=NOW()",row.get("id"),row.get("ruleKey"),row.get("riskScore"));
    }

    @PostMapping("/anomaly/detect")
    public Map<String,Object> detect(@RequestParam Map<String,String> p) {
        if (!Set.of("limit","orderId").containsAll(p.keySet())) throw bad("检测仅支持limit与orderId参数");
        Long orderId = p.containsKey("orderId") ? positiveId(p.get("orderId")) : null;
        Map<String,String> pagination = new HashMap<>(p);
        pagination.remove("orderId");
        int limit = bounded(pagination,"limit",1000,1,1000);
        return s.atomic(() -> {
            List<Map<String,Object>> orders = orderId == null ? s.rows(ORDER_SELECT + " ORDER BY o.id DESC LIMIT ? FOR UPDATE",limit+1) : s.rows(ORDER_SELECT + " AND o.id=? FOR UPDATE",orderId);
            boolean truncated = orderId == null && orders.size() > limit;
            if (truncated) orders.remove(orders.size()-1);
            List<Map<String,Object>> results = evaluate(orders);
            for (Map<String,Object> row : results) persistDetection(row);
            return map("scanned",results.size(),"truncated",truncated,"limit",limit,"anomalous",results.stream().filter(r -> Boolean.TRUE.equals(r.get("anomalous"))).count(),"results",results,"scope",orderId == null ? "LATEST_ORDERS" : "SINGLE_ORDER","orderId",orderId == null ? null : orderId.toString(),"basis",orderId == null ? "扫描最新非删除订单的全部规则；超过上限时明确截断，不代表全库已完成检测。" : "仅扫描指定orderId的非删除订单，不读取或写入其他订单检测记录。");
        });
    }

    @PostMapping("/anomaly/{id}/confirm")
    public Map<String,Object> confirm(@PathVariable("id") String rawId, @RequestBody Map<String,Object> body, HttpServletRequest req) {
        long id = positiveId(rawId);
        bodyKeys(body,"status","expectedStatus","expectedRuleKey");
        if (!(body.get("expectedRuleKey") instanceof String) || str(body.get("expectedRuleKey")).length()>512) throw bad("必须提供当前列表的expectedRuleKey");
        String status = str(body.get("status")), expected = str(body.get("expectedStatus")), expectedRule = str(body.get("expectedRuleKey"));
        if (!Set.of("CONFIRMED","REJECTED").contains(status) || !Set.of("PENDING","CONFIRMED","REJECTED").contains(expected)) throw bad("status或expectedStatus不合法");
        return s.atomic(() -> {
            Map<String,Object> order = s.one(ORDER_SELECT + " AND o.id=? FOR UPDATE",id);
            Map<String,Object> row = evaluate(Collections.singletonList(order)).get(0);
            if (!expected.equals(str(row.get("confirmationStatus"))) || !expectedRule.equals(str(row.get("ruleKey")))) throw conflict("确认状态或异常规则已改变，请刷新后重试");
            if (!Boolean.TRUE.equals(row.get("anomalous"))) throw bad("该订单未命中异常规则，无需确认");
            persistDetection(row);
            s.db.update("UPDATE erp_inventory.t_ai_order_anomaly SET confirmation_status=?,confirmed_by=?,confirmed_at=NOW() WHERE order_id=?",status,req.getAttribute("repairUserId"),id);
            return evaluate(Collections.singletonList(order)).get(0);
        });
    }

    @GetMapping("/anomaly/stats")
    public Map<String,Object> anomalyStats(@RequestParam Map<String,String> p) {
        if (p.containsKey("offset")) throw bad("此扫描接口不支持offset，请使用订单列表分页");
        int limit = bounded(p,"limit",1000,1,1000);
        List<Map<String,Object>> orders = s.rows(ORDER_SELECT + " ORDER BY o.id DESC LIMIT ?",limit+1);
        boolean truncated = orders.size() > limit;
        if (truncated) orders.remove(orders.size()-1);
        List<Map<String,Object>> results = evaluate(orders);
        long abnormal = results.stream().filter(r -> Boolean.TRUE.equals(r.get("anomalous"))).count();
        long confirmed = results.stream().filter(r -> Boolean.TRUE.equals(r.get("anomalous")) && "CONFIRMED".equals(r.get("confirmationStatus"))).count();
        long rejected = results.stream().filter(r -> Boolean.TRUE.equals(r.get("anomalous")) && "REJECTED".equals(r.get("confirmationStatus"))).count();
        return map("totalOrders",s.count("SELECT COUNT(*) FROM erp_order.t_order WHERE deleted=0"),"scanned",results.size(),"truncated",truncated,"anomalous",abnormal,"confirmed",confirmed,"rejected",rejected,"pending",abnormal-confirmed-rejected,"basis","除totalOrders外，统计仅针对最新订单的有界扫描范围，非全库异常率。");
    }
}
