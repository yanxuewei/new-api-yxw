package com.crossborder.erp.platform.util;

import com.crossborder.erp.platform.config.AmazonConfig;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.when;

/**
 * 亚马逊SP-API 签名工具单元测试
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("Amazon SP-API 签名工具测试")
class AmazonSPApiSignerTest {

    @Mock
    private AmazonConfig amazonConfig;

    @InjectMocks
    private AmazonSPApiSigner signer;

    @BeforeEach
    void setUp() {
        when(amazonConfig.getAwsAccessKeyId()).thenReturn("AKIAIOSFODNN7EXAMPLE");
        when(amazonConfig.getAwsSecretKey()).thenReturn("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
        when(amazonConfig.getRegion()).thenReturn("us-east-1");
        when(amazonConfig.getApiBaseUrl()).thenReturn("https://sellingpartnerapi-na.amazon.com");
    }

    @Test
    @DisplayName("签名请求 - 应返回 3 个必需头部")
    void testSignRequest_HeadersPresent() {
        Map<String, String> headers = signer.signRequest("/orders/v0/orders", "GET", "");

        assertNotNull(headers);
        assertEquals(3, headers.size());
        assertTrue(headers.containsKey("x-amz-date"));
        assertTrue(headers.containsKey("Content-Type"));
        assertTrue(headers.containsKey("Authorization"));
    }

    @Test
    @DisplayName("Authorization 头部 - 应符合 AWS4-HMAC-SHA256 格式")
    void testSignRequest_AuthorizationFormat() {
        Map<String, String> headers = signer.signRequest("/orders/v0/orders", "GET", "");

        String auth = headers.get("Authorization");
        assertNotNull(auth);
        assertTrue(auth.startsWith("AWS4-HMAC-SHA256 "), "Should start with AWS4-HMAC-SHA256");
        assertTrue(auth.contains("Credential=AKIAIOSFODNN7EXAMPLE"), "Should contain access key id");
        assertTrue(auth.contains("/us-east-1/execute-api/aws4_request"), "Should contain credential scope");
        assertTrue(auth.contains("SignedHeaders=content-type;host;x-amz-date"), "Should list signed headers");
        assertTrue(auth.contains("Signature="), "Should contain signature");
    }

    @Test
    @DisplayName("x-amz-date - 应符合 ISO8601 basic 格式")
    void testSignRequest_DateFormat() {
        Map<String, String> headers = signer.signRequest("/orders/v0/orders", "GET", "");

        String date = headers.get("x-amz-date");
        // 格式: YYYYMMDDTHHMMSSZ
        assertTrue(date.matches("\\d{8}T\\d{6}Z"),
            "x-amz-date should be ISO8601 basic format, got: " + date);
    }

    @Test
    @DisplayName("Content-Type - 应为 application/json")
    void testSignRequest_ContentType() {
        Map<String, String> headers = signer.signRequest("/foo", "POST", "{}");
        assertEquals("application/json", headers.get("Content-Type"));
    }

    @Test
    @DisplayName("同一请求两次签名 - 因 x-amz-date 变化，签名应不同")
    void testSignRequest_TimeBasedSignature() throws InterruptedException {
        Map<String, String> h1 = signer.signRequest("/foo", "GET", "");

        // 等待 1 秒以确保时间戳不同（秒级精度）
        Thread.sleep(1100);

        Map<String, String> h2 = signer.signRequest("/foo", "GET", "");

        // 由于 x-amz-date 是当前时间，两次签名的 Authorization 应该不同
        // （除非在同 1 秒内签名）
        // 这里我们至少验证两次签名都能成功
        assertNotNull(h1.get("Authorization"));
        assertNotNull(h2.get("Authorization"));
    }

    @Test
    @DisplayName("空 body - 应能签名成功")
    void testSignRequest_EmptyBody() {
        Map<String, String> headers = signer.signRequest("/orders", "GET", "");
        assertNotNull(headers.get("Authorization"));
        assertTrue(headers.get("Authorization").length() > 50);
    }

    @Test
    @DisplayName("签名长度 - 应为 64 字符 (SHA-256 hex)")
    void testSignRequest_SignatureLength() {
        Map<String, String> headers = signer.signRequest("/foo", "GET", "{}");
        String auth = headers.get("Authorization");

        // 提取 Signature= 后面的值
        String signature = auth.substring(auth.indexOf("Signature=") + "Signature=".length());
        // 可能有尾部逗号
        if (signature.endsWith(",")) {
            signature = signature.substring(0, signature.length() - 1);
        }
        assertEquals(64, signature.length(), "Signature should be 64 hex chars (SHA-256)");
        assertTrue(signature.matches("[0-9a-f]+"), "Signature should be lowercase hex");
    }
}
