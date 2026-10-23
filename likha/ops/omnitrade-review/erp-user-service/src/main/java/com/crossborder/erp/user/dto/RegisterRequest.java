package com.crossborder.erp.user.dto;

import lombok.Data;

@Data
public class RegisterRequest {
    private String username;
    private String realName;
    private String password;
}