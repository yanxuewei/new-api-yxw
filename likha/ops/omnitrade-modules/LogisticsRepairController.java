package com.crossborder.erp.warehouse.repair;

import org.springframework.web.bind.annotation.*;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;
import static com.crossborder.erp.warehouse.repair.RepairSupport.*;

@RestController
@RequestMapping("/logistics")
public class LogisticsRepairController {
    private final RepairSupport s;
    private static final String CHANNEL="SELECT code,name,carrier,type,coverage,features,avg_delivery_days avgDeliveryDays,tracking_support trackingSupport FROM erp_logistics.t_logistics_channel";
    private static final String RATE="SELECT r.id,r.channel_code channelCode,c.name channelName,c.carrier,r.shipping_method shippingMethod,r.from_country fromCountry,r.to_country toCountry,r.weight_range_min weightRangeMin,r.weight_range_max weightRangeMax,r.base_price basePrice,r.price_per_kg pricePerKg,r.volumetric_divisor volumetricDivisor,r.estimated_days estimatedDays,r.currency,r.is_active isActive,r.create_time createTime FROM erp_logistics.t_logistics_rate r JOIN erp_logistics.t_logistics_channel c ON c.code=r.channel_code";
    public LogisticsRepairController(RepairSupport s){this.s=s;}

    private String text(Map<String,Object>b,String key,int max){String v=str(b.get(key)).trim();if(v.length()>max)throw bad(key+"长度超出限制");return v;}
    private String code(Object value){String v=str(value).trim();if(!v.matches("[A-Za-z0-9_-]{1,60}"))throw bad("渠道代码仅支持字母、数字、下划线和短横线");return v;}
    private String country(Object value){String v=str(value).toUpperCase(Locale.ROOT);if(!v.matches("[A-Z]{2}"))throw bad("国家代码必须为两位字母");return v;}
    private String currency(Object value){String v=str(value).toUpperCase(Locale.ROOT);try{Currency.getInstance(v);}catch(IllegalArgumentException e){throw bad("币种必须为有效的三位货币代码");}return v;}
    private BigDecimal decimal(Object value,int scale,boolean positive){
        try{BigDecimal n=new BigDecimal(str(value)).setScale(scale,RoundingMode.UNNECESSARY);if(n.precision()>(scale==3?12:18)||(positive?n.signum()<=0:n.signum()<0))throw bad("数值超出允许范围");return n;}
        catch(NumberFormatException|ArithmeticException e){throw bad("数值格式错误，最多"+scale+"位小数");}
    }
    private int days(Object value){long n=number(value);if(n<1||n>3650)throw bad("时效必须为1到3650天");return (int)n;}
    private boolean bool(Object value){if(value instanceof Boolean b)return b;if("1".equals(str(value))||"true".equals(str(value)))return true;if("0".equals(str(value))||"false".equals(str(value)))return false;throw bad("布尔值格式错误");}
    private String arrayJson(Object value){
        if(!(value instanceof List<?> list)||list.size()>200)throw bad("覆盖国家和特色必须为数组，且不超过200项");
        List<String>result=new ArrayList<>();for(Object item:list){if(!(item instanceof String)||str(item).length()>100)throw bad("数组元素必须为100字以内的文本");result.add(str(item));}
        try{return s.json.writeValueAsString(result);}catch(Exception e){throw bad("数组格式错误");}
    }
    private Map<String,Object> channelRow(Map<String,Object> row){
        try{row.put("coverage",s.json.readValue(str(row.get("coverage")),List.class));row.put("features",s.json.readValue(str(row.get("features")),List.class));}
        catch(Exception e){throw new IllegalStateException("数据库物流渠道数组格式错误",e);}
        row.put("trackingSupport",bool(row.get("trackingSupport")));return row;
    }
    private Map<String,Object> rateRow(Map<String,Object>row){row.put("isActive",bool(row.get("isActive")));return row;}
    @GetMapping("/channels")
    public List<Map<String,Object>> channels(){List<Map<String,Object>>rows=s.rows(CHANNEL+" ORDER BY code");rows.forEach(this::channelRow);return rows;}
    @GetMapping("/channel/{code}") public Map<String,Object> channel(@PathVariable String code){return channelRow(s.one(CHANNEL+" WHERE code=?",code(code)));}

    private Map<String,Object> saveChannel(String pathCode,Map<String,Object>input){return s.atomic(()->{
        boolean update=pathCode!=null;String channelCode=code(update?pathCode:input.get("code"));
        Map<String,Object>b=new HashMap<>();if(update){s.one("SELECT code FROM erp_logistics.t_logistics_channel WHERE code=? FOR UPDATE",channelCode);b.putAll(channel(channelCode));}b.putAll(input);
        if(update&&input.containsKey("code")&&!channelCode.equals(input.get("code")))throw bad("渠道代码不可修改");
        s.required(b,"name","carrier","type");String type=str(b.get("type"));if(!Set.of("EXPRESS","SPECIAL","POST","SEA","AIR").contains(type))throw bad("渠道类型无效");
        String coverage=arrayJson(b.getOrDefault("coverage",List.of())),features=arrayJson(b.getOrDefault("features",List.of()));
        if(update)s.db.update("UPDATE erp_logistics.t_logistics_channel SET name=?,carrier=?,type=?,coverage=?,features=?,avg_delivery_days=?,tracking_support=? WHERE code=?",text(b,"name",150),text(b,"carrier",100),type,coverage,features,days(b.getOrDefault("avgDeliveryDays",7)),bool(b.getOrDefault("trackingSupport",true)),channelCode);
        else{
            if(s.count("SELECT COUNT(*) FROM erp_logistics.t_logistics_channel WHERE code=?",channelCode)>0)throw bad("渠道代码已存在");
            s.db.update("INSERT INTO erp_logistics.t_logistics_channel(code,name,carrier,type,coverage,features,avg_delivery_days,tracking_support) VALUES(?,?,?,?,?,?,?,?)",channelCode,text(b,"name",150),text(b,"carrier",100),type,coverage,features,days(b.getOrDefault("avgDeliveryDays",7)),bool(b.getOrDefault("trackingSupport",true)));
        }
        return channel(channelCode);
    });}
    @PostMapping({"/channel","/channels"}) public Map<String,Object> createChannel(@RequestBody Map<String,Object>b){return saveChannel(null,b);}
    @PutMapping("/channel/{code}") public Map<String,Object> updateChannel(@PathVariable String code,@RequestBody Map<String,Object>b){return saveChannel(code,b);}
    @DeleteMapping("/channel/{code}") public void deleteChannel(@PathVariable String code){s.atomic(()->{
        s.one("SELECT code FROM erp_logistics.t_logistics_channel WHERE code=? FOR UPDATE",code(code));
        if(s.count("SELECT COUNT(*) FROM erp_logistics.t_logistics_rate WHERE channel_code=?",code)>0)throw bad("渠道存在费率，请先删除关联费率");
        s.changed(s.db.update("DELETE FROM erp_logistics.t_logistics_channel WHERE code=?",code));return null;
    });}

    @GetMapping("/rates")
    public Map<String,Object> rates(@RequestParam Map<String,String>p){
        List<Object>a=new ArrayList<>();String w=" WHERE 1=1";
        if(p.containsKey("channelCode")&&!p.get("channelCode").isBlank()){a.add(code(p.get("channelCode")));w+=" AND r.channel_code=?";}
        if(p.containsKey("fromCountry")&&!p.get("fromCountry").isBlank()){a.add(country(p.get("fromCountry")));w+=" AND r.from_country=?";}
        if(p.containsKey("toCountry")&&!p.get("toCountry").isBlank()){a.add(country(p.get("toCountry")));w+=" AND r.to_country=?";}
        Map<String,String>page=new HashMap<>(p);page.put("current",p.getOrDefault("current",p.getOrDefault("page","1")));
        Map<String,Object>result=s.page(RATE,w,a,page," ORDER BY r.id DESC");
        Object records=result.get("records");if(records instanceof List<?> list)for(Object row:list)if(row instanceof Map<?,?> map){Object active=map.get("isActive");replaceActive(map,bool(active));}
        return result;
    }
    private <K,V> void replaceActive(Map<K,V> map,boolean active){
        // 数据库字段需转换成JSON布尔值，避免前端开关收到整数。
        @SuppressWarnings("unchecked") Map<String,Object> row=(Map<String,Object>)map;row.put("isActive",active);
    }
    @GetMapping("/rate/{id}") public Map<String,Object> rate(@PathVariable long id){return rateRow(s.one(RATE+" WHERE r.id=?",id));}
    private Map<String,Object> saveRate(Long id,Map<String,Object>input){return s.atomic(()->{
        Map<String,Object>b=new HashMap<>();if(id!=null){s.one("SELECT id FROM erp_logistics.t_logistics_rate WHERE id=? FOR UPDATE",id);b.putAll(rate(id));}b.putAll(input);
        s.required(b,"channelCode","fromCountry","toCountry","weightRangeMin","weightRangeMax","basePrice","pricePerKg","estimatedDays","currency");
        String channelCode=code(b.get("channelCode"));s.one("SELECT code FROM erp_logistics.t_logistics_channel WHERE code=? FOR UPDATE",channelCode);
        BigDecimal min=decimal(b.get("weightRangeMin"),3,false),max=decimal(b.get("weightRangeMax"),3,true);
        if(max.compareTo(min)<=0)throw bad("最大重量必须大于最小重量");
        BigDecimal base=decimal(b.get("basePrice"),2,false),perKg=decimal(b.get("pricePerKg"),2,false);
        BigDecimal divisor=b.get("volumetricDivisor")==null?null:decimal(b.get("volumetricDivisor"),2,true);
        if(divisor!=null&&divisor.precision()>12)throw bad("体积重系数超出范围");
        String from=country(b.get("fromCountry")),to=country(b.get("toCountry")),cur=currency(b.get("currency")),method=text(b,"shippingMethod",50);
        boolean active=bool(b.getOrDefault("isActive",true));
        // 重量区间为(min,max]，同渠道、运输方式、路线和币种禁止启用重叠区间。
        if(active&&s.count("SELECT COUNT(*) FROM erp_logistics.t_logistics_rate WHERE channel_code=? AND from_country=? AND to_country=? AND currency=? AND shipping_method=? AND is_active=1 AND weight_range_min<? AND weight_range_max>? AND id<>?",channelCode,from,to,cur,method,max,min,id==null?-1:id)>0)throw bad("存在重叠的启用费率区间，请调整重量范围或停用旧费率");
        long rid=id==null?s.id():id;
        if(id==null)s.db.update("INSERT INTO erp_logistics.t_logistics_rate(id,channel_code,shipping_method,from_country,to_country,weight_range_min,weight_range_max,base_price,price_per_kg,volumetric_divisor,estimated_days,currency,is_active) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",rid,channelCode,method,from,to,min,max,base,perKg,divisor,days(b.get("estimatedDays")),cur,active);
        else s.db.update("UPDATE erp_logistics.t_logistics_rate SET channel_code=?,shipping_method=?,from_country=?,to_country=?,weight_range_min=?,weight_range_max=?,base_price=?,price_per_kg=?,volumetric_divisor=?,estimated_days=?,currency=?,is_active=? WHERE id=?",channelCode,method,from,to,min,max,base,perKg,divisor,days(b.get("estimatedDays")),cur,active,rid);
        return rate(rid);
    });}
    @PostMapping("/rate") public long createRate(@RequestBody Map<String,Object>b){return number(saveRate(null,b).get("id"));}
    @PutMapping("/rate/{id}") public Map<String,Object> updateRate(@PathVariable long id,@RequestBody Map<String,Object>b){return saveRate(id,b);}
    @DeleteMapping("/rate/{id}") public void deleteRate(@PathVariable long id){s.changed(s.db.update("DELETE FROM erp_logistics.t_logistics_rate WHERE id=?",id));}

    @PostMapping({"/calculate","/recommend"})
    public List<Map<String,Object>> calculate(@RequestBody Map<String,Object>b){
        s.required(b,"fromCountry","toCountry","weight");String from=country(b.get("fromCountry")),to=country(b.get("toCountry"));BigDecimal weight=decimal(b.get("weight"),3,true);
        BigDecimal length=decimal(b.getOrDefault("length",0),3,false),width=decimal(b.getOrDefault("width",0),3,false),height=decimal(b.getOrDefault("height",0),3,false);
        int dimensions=(length.signum()>0?1:0)+(width.signum()>0?1:0)+(height.signum()>0?1:0);if(dimensions!=0&&dimensions!=3)throw bad("长宽高必须同时填写正数，或全部留空");
        List<Map<String,Object>>rates=s.rows(RATE+" WHERE r.from_country=? AND r.to_country=? AND r.is_active=1 ORDER BY r.currency,r.id",from,to);
        List<Map<String,Object>>result=new ArrayList<>();
        for(Map<String,Object>r:rates){
            if(b.containsKey("currency")&&!str(b.get("currency")).isBlank()&&!currency(b.get("currency")).equals(r.get("currency")))continue;
            BigDecimal chargeable=weight;Object divisor=r.get("volumetricDivisor");
            if(divisor!=null){if(dimensions!=3)throw bad("匹配渠道配置了体积重，请填写完整长宽高");chargeable=weight.max(length.multiply(width).multiply(height).divide(new BigDecimal(str(divisor)),3,RoundingMode.CEILING));}
            if(chargeable.compareTo(new BigDecimal(str(r.get("weightRangeMin"))))<=0||chargeable.compareTo(new BigDecimal(str(r.get("weightRangeMax"))))>0)continue;
            BigDecimal total=new BigDecimal(str(r.get("basePrice"))).add(new BigDecimal(str(r.get("pricePerKg"))).multiply(chargeable)).setScale(2,RoundingMode.HALF_UP);
            result.add(map("rateId",r.get("id"),"channelCode",r.get("channelCode"),"channelName",r.get("channelName"),"carrier",r.get("carrier"),"shippingMethod",r.get("shippingMethod"),"totalPrice",total,"currency",r.get("currency"),"estimatedDays",r.get("estimatedDays"),"transitTime",r.get("estimatedDays")+"天","isRecommended",false,"chargeableWeight",chargeable,"pricingBasis",divisor==null?"按实重；基础价 + 重量×公斤单价":"按实重与体积重较大者；基础价 + 计费重×公斤单价","quoteSource","数据库配置费率；不含未配置的税费、偏远地区及其他附加费，非承运商实时报价"));
        }
        result.sort(Comparator.comparing((Map<String,Object>r)->str(r.get("currency"))).thenComparing(r->(BigDecimal)r.get("totalPrice")));
        Set<String>recommended=new HashSet<>();for(Map<String,Object>r:result)r.put("isRecommended",recommended.add(str(r.get("currency"))));
        return result;
    }
}
