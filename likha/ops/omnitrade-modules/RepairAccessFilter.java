package com.crossborder.erp.warehouse.repair;

import jakarta.servlet.*;
import jakarta.servlet.http.*;
import org.springframework.stereotype.Component;
import org.springframework.core.annotation.Order;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.filter.OncePerRequestFilter;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Validate the exact active login token, never trust unsigned JWT claims alone. */
@Component @Order(-10)
public class RepairAccessFilter extends OncePerRequestFilter {
 private final RepairSupport s; private final StringRedisTemplate redis; private final ObjectMapper json;
 public RepairAccessFilter(RepairSupport s,StringRedisTemplate redis,ObjectMapper json){this.s=s;this.redis=redis;this.json=json;}
 protected boolean shouldNotFilter(HttpServletRequest r){return "GET".equals(r.getMethod())&&"/actuator/health".equals(r.getRequestURI());}
 private void fail(HttpServletResponse r,int status,String msg)throws IOException{r.setStatus(status);r.setContentType("application/json;charset=UTF-8");json.writeValue(r.getWriter(),RepairSupport.map("code",status,"message",msg));}
 protected void doFilterInternal(HttpServletRequest req,HttpServletResponse res,FilterChain chain)throws ServletException,IOException{
  if(req.getRequestURI().equals("/auth/refresh")){fail(res,401,"请重新登录以续期；旧刷新令牌已停用");return;}
  String h=req.getHeader("Authorization");if(h==null||!h.startsWith("Bearer ")||h.length()>8192){fail(res,401,"请重新登录");return;}
  Long uid;
  try{String token=h.substring(7);String[] parts=token.split("\\.");if(parts.length!=3)throw new IllegalArgumentException();Map<?,?> claims=json.readValue(Base64.getUrlDecoder().decode(parts[1]),Map.class);uid=Long.parseLong(String.valueOf(claims.get("userId")));long exp=Long.parseLong(String.valueOf(claims.get("exp")));if(exp<=java.time.Instant.now().getEpochSecond()||!"access".equals(claims.get("type")))throw new IllegalArgumentException();String active=redis.opsForValue().get("token:"+uid);if(active==null||!MessageDigest.isEqual(token.getBytes(StandardCharsets.UTF_8),active.getBytes(StandardCharsets.UTF_8)))throw new IllegalArgumentException();}
  catch(Exception e){fail(res,401,"登录已失效，请重新登录");return;}
  if(s.count("SELECT COUNT(*) FROM erp_user.t_user WHERE id=? AND status=1 AND deleted=0",uid)!=1){fail(res,401,"账号不存在或已停用");return;}
  boolean admin=s.count("SELECT COUNT(*) FROM erp_user.t_user_role ur JOIN erp_user.t_role r ON r.id=ur.role_id WHERE ur.user_id=? AND r.status=1 AND LOWER(r.role_code) IN ('admin','super_admin')",uid)>0;
  // Missing production RBAC cannot safely grant broad business or personal-data access.
  if(!admin){fail(res,403,"此管理后台接口需要管理员角色");return;}
  req.setAttribute("repairUserId",uid);chain.doFilter(req,res);
 }
}
