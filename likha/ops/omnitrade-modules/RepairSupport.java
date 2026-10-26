package com.crossborder.erp.warehouse.repair;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;
import java.util.*;
import java.security.SecureRandom;
import java.util.function.Supplier;

/** Shared parameterized persistence for the minimal consolidated module. */
@Component
public class RepairSupport {
 public final JdbcTemplate db;
 public final TransactionTemplate tx;
 public final ObjectMapper json;
 private final SecureRandom random=new SecureRandom();
 public RepairSupport(JdbcTemplate db, org.springframework.transaction.PlatformTransactionManager tm,ObjectMapper json){this.db=db;this.tx=new TransactionTemplate(tm);this.json=json;}
 public static Map<String,Object> map(Object... kv){Map<String,Object> m=new LinkedHashMap<>();for(int i=0;i<kv.length;i+=2)m.put((String)kv[i],kv[i+1]);return m;}
 public static String str(Object x){return x==null?"":String.valueOf(x);}
 public static long number(Object x){try{return Long.parseLong(str(x));}catch(Exception e){throw bad("Invalid integer");}}
 public static ResponseStatusException bad(String m){return new ResponseStatusException(HttpStatus.BAD_REQUEST,m);}
 public static ResponseStatusException missing(){return new ResponseStatusException(HttpStatus.NOT_FOUND,"Record not found");}
 public long id(){long value;do{value=random.nextLong() & ((1L<<52)-1);}while(value==0);return value;}
 public <T>T atomic(Supplier<T> op){return tx.execute(s->op.get());}
 public List<Map<String,Object>> rows(String sql,Object... args){return db.queryForList(sql,args);}
 public Map<String,Object> one(String sql,Object... args){List<Map<String,Object>> r=rows(sql,args);if(r.isEmpty())throw missing();return r.get(0);}
 public long count(String sql,Object... args){Long n=db.queryForObject(sql,Long.class,args);return n==null?0:n;}
 public Map<String,Object> page(String select,String where,List<Object> args,Map<String,String> p,String order){int current=Math.max(1,Integer.parseInt(p.getOrDefault("current","1")));int size=Math.max(1,Math.min(100,Integer.parseInt(p.getOrDefault("size","20"))));long offset=(long)(current-1)*size;if(offset>1000000)throw bad("Pagination offset too large");long total=count("SELECT COUNT(*) FROM ("+select+where+") repair_count",args.toArray());List<Object>a=new ArrayList<>(args);a.add(size);a.add(offset);return map("current",current,"size",size,"total",total,"records",rows(select+where+order+" LIMIT ? OFFSET ?",a.toArray()));}
 public void required(Map<String,Object>b,String... keys){for(String k:keys)if(str(b.get(k)).trim().isEmpty())throw bad(k+" is required");}
 public String eq(String field,String key,Map<String,String>p,List<Object>a){String v=p.get(key);if(v==null||v.isEmpty())return "";a.add(v);return " AND "+field+"=?";}
 public String like(String field,String key,Map<String,String>p,List<Object>a){String v=p.get(key);if(v==null||v.isEmpty())return "";a.add("%"+v+"%");return " AND "+field+" LIKE ?";}
 public void changed(int n){if(n==0)throw missing();}
}
