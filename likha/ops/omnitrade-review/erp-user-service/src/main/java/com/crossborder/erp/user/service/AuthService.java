package com.crossborder.erp.user.service;

import com.crossborder.erp.user.dto.LoginRequest;
import com.crossborder.erp.user.dto.LoginResponse;
import com.crossborder.erp.user.dto.RegisterRequest;

public interface AuthService {
    LoginResponse login(LoginRequest request);

    void logout(String token);

    void register(RegisterRequest request);

    LoginResponse refreshToken(String refreshToken);
}
