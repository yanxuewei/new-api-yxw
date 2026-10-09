# ours_likha/ops — 运维脚本区

| 文件 | 用途 |
|---|---|
| `patches/0001-log-ms-precision.patch` | 日志时间格式毫秒化补丁（对应 `UPSTREAM_CHANGES.md` 条目 1–5） |
| `verify-upstream-changes.sh` | 对照 `UPSTREAM_CHANGES.md` **机械校验**每处定制是否仍在位；上游 sync 前后必跑 |

## 用法

```bash
# 校验定制项是否在位（退出码非 0 = 有定制项被上游覆盖或冲突未解决）
bash ours_likha/ops/verify-upstream-changes.sh

# 若某补丁被上游 sync 冲掉，可用补丁重新应用（-3 三方合并 / --check 干跑）
git apply --check ours_likha/ops/patches/0001-log-ms-precision.patch
git apply ours_likha/ops/patches/0001-log-ms-precision.patch
```

## 约定

- 每个补丁头部注释写明：对应 `UPSTREAM_CHANGES.md` 哪几条、为什么要改、如何验证。
- 补丁编号递增，**不重编号、不删除**；作废的补丁保留并标注 `# DEPRECATED`。
