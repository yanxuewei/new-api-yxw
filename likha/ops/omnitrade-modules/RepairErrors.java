package com.crossborder.erp.warehouse.repair;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.*;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.dao.DataIntegrityViolationException;
import java.util.Map;
@RestControllerAdvice(basePackages="com.crossborder.erp.warehouse.repair")
public class RepairErrors {
 @ExceptionHandler(ResponseStatusException.class) public ResponseEntity<?> status(ResponseStatusException e){return ResponseEntity.status(e.getStatusCode()).body(Map.of("code",e.getStatusCode().value(),"message",e.getReason()==null?"请求失败":e.getReason()));}
 @ExceptionHandler({NumberFormatException.class,IllegalArgumentException.class}) public ResponseEntity<?> input(Exception e){return ResponseEntity.badRequest().body(Map.of("code",400,"message","请求参数不合法"));}
 @ExceptionHandler(DataIntegrityViolationException.class) public ResponseEntity<?> duplicate(Exception e){return ResponseEntity.status(409).body(Map.of("code",409,"message","数据重复或关联约束冲突，请检查输入"));}
}
