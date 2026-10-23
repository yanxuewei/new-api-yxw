package com.crossborder.erp.warehouse.repair;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.*;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.*;
import static com.crossborder.erp.warehouse.repair.RepairSupport.*;

@RestController
@RequestMapping("/finance")
public class FinanceRepairController {
    private final RepairSupport s;
    private static final String ACCOUNT = "SELECT id,account_no accountNo,account_name accountName,account_type accountType,bank_name bankName,currency,balance,status,is_default isDefault,create_time createTime FROM erp_finance.t_finance_account";
    private static final String CATEGORY = "SELECT id,name,type,COALESCE(parent_id,0) parentId,sort,status FROM erp_finance.t_finance_category";
    private static final String FROM = " FROM erp_finance.t_finance_flow f LEFT JOIN erp_finance.t_finance_flow_meta m ON m.flow_id=f.id LEFT JOIN erp_finance.t_finance_account a ON a.id=m.account_id LEFT JOIN erp_finance.t_finance_category c ON c.id=m.category_id";
    private static final String FLOW = "SELECT f.id,COALESCE(m.record_no,CAST(f.id AS CHAR)) recordNo,f.flow_type type,f.amount,f.currency_code currency,m.account_id accountId,a.account_name accountName,m.category_id categoryId,COALESCE(c.name,f.category) categoryName,f.order_no orderNo,f.remark,f.create_time createTime,m.create_by createBy,(m.flow_id IS NULL) legacy" + FROM;

    public FinanceRepairController(RepairSupport s) { this.s = s; }

    private String text(Map<String,Object> b,String key,int max) {
        String v=str(b.get(key)).trim();
        if(v.length()>max) throw bad(key+"长度超出限制");
        return v;
    }
    private String type(Object value) {
        String v=str(value);
        if(!Set.of("income","expense","refund").contains(v)) throw bad("流水类型必须为 income、expense 或 refund");
        return v;
    }
    private String currency(Object value) {
        String v=str(value).toUpperCase(Locale.ROOT);
        try { Currency.getInstance(v); } catch(IllegalArgumentException e) { throw bad("币种必须为有效的三位货币代码"); }
        return v;
    }
    private BigDecimal money(Object value,boolean positive) {
        try {
            BigDecimal n=new BigDecimal(str(value)).setScale(2,RoundingMode.UNNECESSARY);
            if(n.precision()>18 || (positive ? n.signum()<=0 : n.signum()<0)) throw bad("金额必须在允许范围内，且最多两位小数");
            return n;
        } catch(NumberFormatException | ArithmeticException e) { throw bad("金额格式错误，最多两位小数"); }
    }
    private int flag(Object value) {
        long n=number(value); if(n!=0 && n!=1) throw bad("状态仅支持0或1"); return (int)n;
    }
    private Map<String,Object> account(long id) { return s.one(ACCOUNT+" WHERE id=?",id); }
    private void lockAccounts() { s.rows("SELECT id FROM erp_finance.t_finance_account ORDER BY id FOR UPDATE"); }
    private void defaultAccount(long id,String cur) {
        s.db.update("UPDATE erp_finance.t_finance_account SET is_default=0 WHERE currency=? AND is_default=1",cur);
        s.db.update("UPDATE erp_finance.t_finance_account SET is_default=1 WHERE id=?",id);
    }

    @GetMapping("/account/list")
    public List<Map<String,Object>> accounts() { return s.rows(ACCOUNT+" ORDER BY currency,is_default DESC,id"); }

    @PostMapping("/account")
    public Map<String,Object> createAccount(@RequestBody Map<String,Object> b) {
        s.required(b,"accountNo","accountName","accountType","currency");
        return s.atomic(()->{
            lockAccounts();
            long id=s.id(); String cur=currency(b.get("currency"));
            int status=flag(b.getOrDefault("status",1)), def=flag(b.getOrDefault("isDefault",0));
            if(status==0 && def==1) throw bad("停用账户不能设为默认");
            String no=text(b,"accountNo",100);
            if(s.count("SELECT COUNT(*) FROM erp_finance.t_finance_account WHERE account_no=?",no)>0) throw bad("账号已存在");
            s.db.update("INSERT INTO erp_finance.t_finance_account(id,account_no,account_name,account_type,bank_name,currency,balance,status,is_default) VALUES(?,?,?,?,?,?,?,?,0)",id,no,text(b,"accountName",150),text(b,"accountType",30),text(b,"bankName",150),cur,money(b.getOrDefault("balance",0),false),status);
            if(def==1) defaultAccount(id,cur);
            return account(id);
        });
    }

    @PutMapping("/account")
    public Map<String,Object> updateAccount(@RequestBody Map<String,Object> input) {
        long id=number(input.get("id"));
        return s.atomic(()->{
            lockAccounts(); Map<String,Object> old=account(id), b=new HashMap<>(old); b.putAll(input);
            s.required(b,"accountNo","accountName","accountType","currency");
            String cur=currency(b.get("currency"));
            if(!cur.equals(old.get("currency"))) throw bad("账户币种不可修改，请新建对应币种账户");
            if(money(b.get("balance"),false).compareTo(new BigDecimal(str(old.get("balance"))))!=0) throw bad("余额只能通过收支流水调整");
            int status=flag(b.get("status")), def=flag(b.get("isDefault"));
            if(status==0 && def==1) throw bad("停用账户不能设为默认");
            String no=text(b,"accountNo",100);
            if(s.count("SELECT COUNT(*) FROM erp_finance.t_finance_account WHERE account_no=? AND id<>?",no,id)>0) throw bad("账号已存在");
            s.db.update("UPDATE erp_finance.t_finance_account SET account_no=?,account_name=?,account_type=?,bank_name=?,status=?,is_default=0 WHERE id=?",no,text(b,"accountName",150),text(b,"accountType",30),text(b,"bankName",150),status,id);
            if(def==1) defaultAccount(id,cur);
            return account(id);
        });
    }

    @PostMapping("/account/{id}/default")
    public Map<String,Object> setDefault(@PathVariable long id) {
        return s.atomic(()->{ lockAccounts(); Map<String,Object> a=account(id); if(number(a.get("status"))!=1) throw bad("账户已停用"); defaultAccount(id,str(a.get("currency"))); return account(id); });
    }

    @DeleteMapping("/account/{id}")
    public void deleteAccount(@PathVariable long id) {
        s.atomic(()->{
            Map<String,Object> locked=s.one("SELECT id,balance FROM erp_finance.t_finance_account WHERE id=? FOR UPDATE",id);
            if(new BigDecimal(str(locked.get("balance"))).signum()!=0) throw bad("账户余额不为零，不能删除，请停用账户");
            if(s.count("SELECT COUNT(*) FROM erp_finance.t_finance_flow_meta WHERE account_id=?",id)>0) throw bad("存在流水的账户不能删除，请停用账户");
            s.changed(s.db.update("DELETE FROM erp_finance.t_finance_account WHERE id=?",id)); return null;
        });
    }

    @GetMapping("/category/list")
    public List<Map<String,Object>> categories(@RequestParam Map<String,String> p) {
        List<Object>a=new ArrayList<>(); String where=" WHERE 1=1";
        if(p.containsKey("type") && !p.get("type").isBlank()){a.add(type(p.get("type")));where+=" AND type=?";}
        return s.rows(CATEGORY+where+" ORDER BY sort,id",a.toArray());
    }

    private Map<String,Object> saveCategory(Map<String,Object> input,boolean update) {
        return s.atomic(()->{
            s.rows("SELECT id FROM erp_finance.t_finance_category ORDER BY id FOR UPDATE");
            long id=update?number(input.get("id")):s.id();
            Map<String,Object> b=update?new HashMap<>(s.one(CATEGORY+" WHERE id=?",id)):new HashMap<>();b.putAll(input);
            s.required(b,"name","type");String t=type(b.get("type"));
            Long parent=b.get("parentId")==null || number(b.get("parentId"))==0 ? null : number(b.get("parentId"));
            if(parent!=null){
                Set<Long> visited=new HashSet<>(); visited.add(id); Long cursor=parent;
                while(cursor!=null){
                    if(!visited.add(cursor)) throw bad("分类不能形成循环");
                    Map<String,Object> row=s.one("SELECT parent_id,type FROM erp_finance.t_finance_category WHERE id=?",cursor);
                    if(!t.equals(row.get("type"))) throw bad("父分类必须与当前分类类型一致");
                    cursor=row.get("parent_id")==null?null:number(row.get("parent_id"));
                }
            }
            if(update && s.count("SELECT COUNT(*) FROM erp_finance.t_finance_flow_meta m JOIN erp_finance.t_finance_flow f ON f.id=m.flow_id WHERE m.category_id=? AND f.flow_type<>?",id,t)>0) throw bad("存在流水，不能修改分类类型");
            if(update && s.count("SELECT COUNT(*) FROM erp_finance.t_finance_category WHERE parent_id=? AND type<>?",id,t)>0) throw bad("子分类类型不一致");
            long sort=number(b.getOrDefault("sort",0));if(sort<0 || sort>1000000)throw bad("排序超出范围");
            if(update) s.db.update("UPDATE erp_finance.t_finance_category SET name=?,type=?,parent_id=?,sort=?,status=? WHERE id=?",text(b,"name",100),t,parent,sort,flag(b.getOrDefault("status",1)),id);
            else s.db.update("INSERT INTO erp_finance.t_finance_category(id,name,type,parent_id,sort,status) VALUES(?,?,?,?,?,?)",id,text(b,"name",100),t,parent,sort,flag(b.getOrDefault("status",1)));
            return s.one(CATEGORY+" WHERE id=?",id);
        });
    }
    @PostMapping("/category") public Map<String,Object> createCategory(@RequestBody Map<String,Object>b){return saveCategory(b,false);}
    @PutMapping("/category") public Map<String,Object> updateCategory(@RequestBody Map<String,Object>b){return saveCategory(b,true);}
    @DeleteMapping("/category/{id}")
    public void deleteCategory(@PathVariable long id){s.atomic(()->{
        s.one("SELECT id FROM erp_finance.t_finance_category WHERE id=? FOR UPDATE",id);
        if(s.count("SELECT COUNT(*) FROM erp_finance.t_finance_flow_meta WHERE category_id=?",id)>0 || s.count("SELECT COUNT(*) FROM erp_finance.t_finance_category WHERE parent_id=?",id)>0) throw bad("分类有流水或子分类，不能删除");
        s.changed(s.db.update("DELETE FROM erp_finance.t_finance_category WHERE id=?",id));return null;
    });}

    private LocalDate date(String value){try{return LocalDate.parse(value);}catch(DateTimeParseException e){throw bad("日期格式必须为YYYY-MM-DD");}}
    private String filter(Map<String,String> p,List<Object> args){
        String w=" WHERE 1=1";
        for(String key:List.of("accountId","categoryId"))if(p.containsKey(key)&&!p.get(key).isBlank()){args.add(number(p.get(key)));w+=" AND m."+(key.equals("accountId")?"account_id":"category_id")+"=?";}
        if(p.containsKey("type")&&!p.get("type").isBlank()){args.add(type(p.get("type")));w+=" AND f.flow_type=?";}
        if(p.containsKey("currency")&&!p.get("currency").isBlank()){args.add(currency(p.get("currency")));w+=" AND f.currency_code=?";}
        LocalDate start=null,end=null;
        if(p.containsKey("startDate")&&!p.get("startDate").isBlank()){start=date(p.get("startDate"));args.add(start.atStartOfDay());w+=" AND f.create_time>=?";}
        if(p.containsKey("endDate")&&!p.get("endDate").isBlank()){end=date(p.get("endDate"));args.add(end.plusDays(1).atStartOfDay());w+=" AND f.create_time<?";}
        if(start!=null && end!=null && start.isAfter(end))throw bad("开始日期不能晚于结束日期");
        if(p.containsKey("keyword")&&!p.get("keyword").isBlank()){String k="%"+p.get("keyword")+"%";Collections.addAll(args,k,k,k);w+=" AND (f.order_no LIKE ? OR f.remark LIKE ? OR m.record_no LIKE ?)";}
        return w;
    }
    @GetMapping("/flow/list")
    public Map<String,Object> flows(@RequestParam Map<String,String> p){List<Object>a=new ArrayList<>();String w=filter(p,a);return s.page(FLOW,w,a,p," ORDER BY f.create_time DESC,f.id DESC");}
    @GetMapping("/flow/{id}") public Map<String,Object> flow(@PathVariable long id){return s.one(FLOW+" WHERE f.id=?",id);}

    private BigDecimal signed(String t,BigDecimal amount){return t.equals("income")?amount:amount.negate();}
    private void balance(long accountId,BigDecimal delta){
        BigDecimal next=new BigDecimal(str(s.one(ACCOUNT+" WHERE id=? FOR UPDATE",accountId).get("balance"))).add(delta);
        if(next.signum()<0)throw bad("账户余额不足，不能执行此流水变更");
        if(next.precision()>18)throw bad("余额超出允许范围");
        s.db.update("UPDATE erp_finance.t_finance_account SET balance=? WHERE id=?",next,accountId);
    }
    private Map<String,Object> saveFlow(Map<String,Object> input,boolean update,String actor){
        return s.atomic(()->{
            long id=update?number(input.get("id")):s.id(); Map<String,Object> old=null;
            if(update){s.one("SELECT id FROM erp_finance.t_finance_flow WHERE id=? FOR UPDATE",id);old=flow(id);if(old.get("accountId")==null)throw bad("历史流水未关联账户，禁止自动改写；请先完成历史对账迁移");}
            Map<String,Object>b=old==null?new HashMap<>():new HashMap<>(old);b.putAll(input);
            s.required(b,"type","amount","accountId");String t=type(b.get("type"));BigDecimal amount=money(b.get("amount"),true);long aid=number(b.get("accountId"));
            long oldAid=old==null?aid:number(old.get("accountId"));
            s.one("SELECT id FROM erp_finance.t_finance_account WHERE id=? FOR UPDATE",Math.min(aid,oldAid));
            if(aid!=oldAid)s.one("SELECT id FROM erp_finance.t_finance_account WHERE id=? FOR UPDATE",Math.max(aid,oldAid));
            Map<String,Object>a=s.one(ACCOUNT+" WHERE id=? FOR UPDATE",aid);String cur=str(a.get("currency"));
            if(number(a.get("status"))!=1)throw bad("账户已停用");
            if(b.containsKey("currency")&&!str(b.get("currency")).isBlank()&&!cur.equals(currency(b.get("currency"))))throw bad("流水币种必须与账户一致，不支持自动换汇");
            if(old!=null&&!cur.equals(old.get("currency")))throw bad("不支持跨币种移动流水");
            Long cid=b.get("categoryId")==null?null:number(b.get("categoryId"));String category="";
            if(cid!=null){Map<String,Object>c=s.one("SELECT name,type,status FROM erp_finance.t_finance_category WHERE id=? FOR UPDATE",cid);if(number(c.get("status"))!=1 || !t.equals(c.get("type")))throw bad("分类必须启用且与流水类型一致");category=str(c.get("name"));}
            BigDecimal delta=signed(t,amount);
            if(old!=null){BigDecimal reversal=signed(str(old.get("type")),new BigDecimal(str(old.get("amount")))).negate();if(aid==oldAid)delta=delta.add(reversal);else balance(oldAid,reversal);}
            balance(aid,delta);
            if(update){
                s.db.update("UPDATE erp_finance.t_finance_flow SET flow_type=?,order_no=?,amount=?,currency_code=?,category=?,remark=? WHERE id=?",t,text(b,"orderNo",100),amount,cur,category,text(b,"remark",500),id);
                s.db.update("UPDATE erp_finance.t_finance_flow_meta SET account_id=?,category_id=? WHERE flow_id=?",aid,cid,id);
            }else{
                s.db.update("INSERT INTO erp_finance.t_finance_flow(id,flow_type,order_no,amount,currency_code,category,remark) VALUES(?,?,?,?,?,?,?)",id,t,text(b,"orderNo",100),amount,cur,category,text(b,"remark",500));
                s.db.update("INSERT INTO erp_finance.t_finance_flow_meta(flow_id,record_no,account_id,category_id,create_by) VALUES(?,?,?,?,?)",id,"FIN"+id,aid,cid,actor);
            }
            return flow(id);
        });
    }
    @PostMapping("/flow") public Map<String,Object> createFlow(@RequestBody Map<String,Object>b,HttpServletRequest request){return saveFlow(b,false,str(request.getAttribute("repairUserId")));}
    @PutMapping("/flow") public Map<String,Object> updateFlow(@RequestBody Map<String,Object>b,HttpServletRequest request){return saveFlow(b,true,str(request.getAttribute("repairUserId")));}
    @DeleteMapping("/flow/{id}")
    public void deleteFlow(@PathVariable long id){s.atomic(()->{
        s.one("SELECT id FROM erp_finance.t_finance_flow WHERE id=? FOR UPDATE",id);Map<String,Object>f=flow(id);
        if(f.get("accountId")==null)throw bad("历史流水未关联账户，禁止自动删除；请先完成历史对账迁移");
        long aid=number(f.get("accountId"));s.one("SELECT id FROM erp_finance.t_finance_account WHERE id=? FOR UPDATE",aid);
        balance(aid,signed(str(f.get("type")),new BigDecimal(str(f.get("amount")))).negate());
        s.db.update("DELETE FROM erp_finance.t_finance_flow_meta WHERE flow_id=?",id);s.db.update("DELETE FROM erp_finance.t_finance_flow WHERE id=?",id);return null;
    });}

    private String singleCurrency(List<Map<String,Object>> rows,Map<String,String>p){
        Set<String> currencies=new HashSet<>();for(Map<String,Object>row:rows)currencies.add(str(row.get("currency")));
        if(currencies.size()>1)throw bad("结果包含多个币种，不支持混币种汇总；请选择 currency 或 accountId");
        return currencies.isEmpty()?p.getOrDefault("currency",""):currencies.iterator().next();
    }
    @GetMapping("/flow/statistics")
    public Map<String,Object> statistics(@RequestParam Map<String,String>p){
        List<Object>a=new ArrayList<>();String w=filter(p,a);
        List<Map<String,Object>>rows=s.rows("SELECT f.currency_code currency,SUM(CASE WHEN f.flow_type='income' THEN f.amount ELSE 0 END) totalIncome,SUM(CASE WHEN f.flow_type IN ('expense','refund') THEN f.amount ELSE 0 END) totalExpense,COUNT(*) recordCount"+FROM+w+" GROUP BY f.currency_code",a.toArray());
        String cur=singleCurrency(rows,p);Map<String,Object>r=rows.isEmpty()?map("totalIncome",BigDecimal.ZERO,"totalExpense",BigDecimal.ZERO,"recordCount",0):rows.get(0);
        r.put("profit",new BigDecimal(str(r.get("totalIncome"))).subtract(new BigDecimal(str(r.get("totalExpense")))));r.put("currency",cur);return r;
    }
    @GetMapping("/flow/trend")
    public List<Map<String,Object>> trend(@RequestParam Map<String,String>p){
        long days=number(p.getOrDefault("days","30"));if(days<1||days>366)throw bad("趋势天数必须为1到366");
        Map<String,String>q=new HashMap<>(p);LocalDate end=LocalDate.now();q.put("startDate",end.minusDays(days-1).toString());q.put("endDate",end.toString());
        List<Object>a=new ArrayList<>();String w=filter(q,a);
        List<Map<String,Object>>rows=s.rows("SELECT DATE_FORMAT(f.create_time,'%Y-%m-%d') date,f.currency_code currency,SUM(CASE WHEN f.flow_type='income' THEN f.amount ELSE 0 END) income,SUM(CASE WHEN f.flow_type IN ('expense','refund') THEN f.amount ELSE 0 END) expense"+FROM+w+" GROUP BY DATE_FORMAT(f.create_time,'%Y-%m-%d'),f.currency_code ORDER BY date",a.toArray());
        String cur=singleCurrency(rows,p);Map<String,Map<String,Object>>byDate=new HashMap<>();for(Map<String,Object>r:rows)byDate.put(str(r.get("date")),r);
        List<Map<String,Object>>result=new ArrayList<>();for(long i=days-1;i>=0;i--){String d=end.minusDays(i).toString();result.add(byDate.getOrDefault(d,map("date",d,"income",BigDecimal.ZERO,"expense",BigDecimal.ZERO,"currency",cur)));}return result;
    }
    @GetMapping("/flow/category")
    public List<Map<String,Object>> categoryData(@RequestParam Map<String,String>p){
        List<Object>a=new ArrayList<>();String w=filter(p,a);
        List<Map<String,Object>>rows=s.rows("SELECT COALESCE(c.name,NULLIF(f.category,''),'未分类') categoryName,f.flow_type type,f.currency_code currency,SUM(f.amount) amount"+FROM+w+" GROUP BY COALESCE(c.name,NULLIF(f.category,''),'未分类'),f.flow_type,f.currency_code ORDER BY amount DESC",a.toArray());singleCurrency(rows,p);return rows;
    }
}
