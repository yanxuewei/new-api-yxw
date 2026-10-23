package com.crossborder.erp.warehouse.repair;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;
import java.util.*;
import static com.crossborder.erp.warehouse.repair.RepairSupport.*;

@RestController
public class PlatformRepairController {
 private final RepairSupport s;
 public PlatformRepairController(RepairSupport s){this.s=s;}
 private Object ok(Object data){return map("code",200,"message","success","data",data);}
 private final String fields="id,platform,shop_id AS shopId,shop_name AS shopName,api_base_url AS apiBaseUrl,callback_url AS callbackUrl,status,remark,token_expire_time AS tokenExpireTime,create_time AS createTime,update_time AS updateTime,CASE WHEN api_key IS NULL OR api_key='' THEN '' ELSE '********' END AS apiKey,CASE WHEN api_secret IS NULL OR api_secret='' THEN '' ELSE '********' END AS apiSecret,CASE WHEN access_token IS NULL OR access_token='' THEN '' ELSE '********' END AS accessToken,CASE WHEN refresh_token IS NULL OR refresh_token='' THEN '' ELSE '********' END AS refreshToken";
 private Map<String,Object> row(long id){return s.one("SELECT "+fields+" FROM erp_platform.t_platform_config WHERE id=? AND deleted=0",id);}
 @GetMapping("/platform/config/list") public Object list(){return ok(s.rows("SELECT "+fields+" FROM erp_platform.t_platform_config WHERE deleted=0 ORDER BY id"));}
 @GetMapping("/platform/config/{id}") public Object get(@PathVariable long id){return ok(row(id));}
 @PostMapping("/platform/config") public Object save(@RequestBody Map<String,Object>b){s.required(b,"platform","shopId","shopName");String platform=str(b.get("platform")).toLowerCase();if(!Set.of("amazon","shopee","ebay","lazada","tiktok").contains(platform))throw bad("不支持的平台类型");int status=(int)number(b.getOrDefault("status",1));if(status!=0&&status!=1)throw bad("Invalid status");long id=b.get("id")==null?s.id():number(b.get("id"));return s.atomic(()->{if(b.get("id")==null){s.db.update("INSERT INTO erp_platform.t_platform_config(id,platform,shop_id,shop_name,api_base_url,callback_url,status,remark) VALUES(?,?,?,?,?,?,?,?)",id,platform,b.get("shopId"),b.get("shopName"),b.get("apiBaseUrl"),b.get("callbackUrl"),status,b.get("remark"));}else{s.one("SELECT id FROM erp_platform.t_platform_config WHERE id=? AND deleted=0 FOR UPDATE",id);s.db.update("UPDATE erp_platform.t_platform_config SET platform=?,shop_id=?,shop_name=?,api_base_url=?,callback_url=?,status=?,remark=? WHERE id=?",platform,b.get("shopId"),b.get("shopName"),b.get("apiBaseUrl"),b.get("callbackUrl"),status,b.get("remark"),id);}Map<String,String>secretFields=Map.of("apiKey","api_key","apiSecret","api_secret","accessToken","access_token","refreshToken","refresh_token");for(var e:secretFields.entrySet()){String v=str(b.get(e.getKey()));if(!v.isBlank()&&!v.equals("********"))s.db.update("UPDATE erp_platform.t_platform_config SET "+e.getValue()+"=? WHERE id=?",v,id);}return ok(row(id));});}
 @DeleteMapping("/platform/config/{id}") public Object delete(@PathVariable long id){s.changed(s.db.update("UPDATE erp_platform.t_platform_config SET deleted=1,status=0 WHERE id=? AND deleted=0",id));return ok(null);}
 @PutMapping("/platform/config/{id}/status") public Object status(@PathVariable long id,@RequestParam(required=false)Integer status,@RequestBody(required=false)Map<String,Object>b){int v=status!=null?status:(int)number(b==null?null:b.get("status"));if(v!=0&&v!=1)throw bad("Invalid status");s.changed(s.db.update("UPDATE erp_platform.t_platform_config SET status=? WHERE id=? AND deleted=0",v,id));return ok(null);}
 @PostMapping({"/platform/config/{id}/test","/platform/sync/orders","/platform/sync/products"}) public Object unsupported(){throw new ResponseStatusException(HttpStatus.NOT_IMPLEMENTED,"平台真实连接测试/同步需要对应平台API凭据及SDK适配，当前未完成；未执行外部请求");}
}
