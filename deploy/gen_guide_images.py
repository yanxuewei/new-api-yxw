#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成《用户设置指南.md》配图 —— 阿里云 RAM 访问控制控制台界面示意图。
输出 ./user-guide-images/*.svg，矢量图，1:1 复刻控制台布局与用词，标注点击位置。
运行：/usr/bin/python3 gen_guide_images.py
"""
import os
import re

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "user-guide-images")
os.makedirs(OUT, exist_ok=True)

F = "PingFang SC,Hiragino Sans GB,Microsoft YaHei,sans-serif"
C = dict(bg="#ffffff", nav="#f7f8fa", hov="#eef0f3", line="#e8eaed", thead="#f7f8fa",
         text="#1f2329", sub="#646a73", muted="#8f959e", primary="#ff6a00",
         link="#0064c8", hl="#ff6a00", hlsoft="#fff7f0", green="#00b42a",
         red="#f53f3f", input="#c9cdd4")

NAV = [("item", "概览"), ("item", "设置"),
       ("head", "身份管理"), ("item", "用户"), ("item", "用户组"), ("item", "角色"),
       ("head", "权限管理"), ("item", "权限策略"), ("item", "授权"),
       ("head", "集成管理"), ("item", "SSO 管理"), ("item", "OAuth 应用（公测）"), ("item", "多账号身份权限"),
       ("head", "访问分析"), ("item", "分析器"), ("item", "分析结果"),
       ("head", "AI 治理中心")]

W, H, NAVW, TOP = 1120, 640, 200, 48


def e(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def t(x, y, s, size=13, fill=None, anchor="start", weight="400", op=None):
    fill = fill or C["text"]
    a = ' text-anchor="%s"' % anchor if anchor != "start" else ""
    w = ' font-weight="%s"' % weight if weight != "400" else ""
    o = ' opacity="%s"' % op if op else ""
    return '<text x="%.1f" y="%.1f" font-family="%s" font-size="%s" fill="%s"%s%s%s>%s</text>' % (
        x, y, F, size, fill, a, w, o, e(s))


def r(x, y, w, h, fill="none", stroke="none", rx=0, sw=1, dash=None, op=None):
    d = ' stroke-dasharray="%s"' % dash if dash else ""
    o = ' opacity="%s"' % op if op else ""
    return '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%s" fill="%s" stroke="%s" stroke-width="%s"%s%s/>' % (
        x, y, w, h, rx, fill, stroke, sw, d, o)


def ln(x1, y1, x2, y2, stroke=None, sw=1, dash=None):
    stroke = stroke or C["line"]
    d = ' stroke-dasharray="%s"' % dash if dash else ""
    return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%s"%s/>' % (
        x1, y1, x2, y2, stroke, sw, d)


def mark(cx, cy, num, rad=12):
    return r(cx - rad, cy - rad, rad * 2, rad * 2, fill=C["hl"], rx=rad) + \
        t(cx, cy + 5, num, 12.5, "#fff", "middle", "600")


def btn(x, y, w, h, label, kind="primary", num=None):
    if kind == "primary":
        g = r(x, y, w, h, fill=C["primary"], rx=4) + t(x + w / 2, y + h / 2 + 5, label, 13, "#fff", "middle")
    elif kind == "ghost":
        g = r(x, y, w, h, fill="#fff", stroke=C["line"], rx=4) + t(x + w / 2, y + h / 2 + 5, label, 13, C["text"], "middle")
    else:
        return t(x, y + h / 2 + 5, label, 13, C["link"])
    if num:
        g += mark(x + w + 16, y + h / 2, num)
    return g


def callout(x, y, w, h, num):
    return r(x, y, w, h, stroke=C["hl"], rx=5, sw=2, dash="7 5") + mark(x + w, y, num)


def table(x, y, widths, header, rows, hh=38, rh=34, hl=()):
    total = sum(widths)
    o = [r(x, y, total, hh, fill=C["thead"]), ln(x, y, x + total, y)]
    cx = x
    for i, hd in enumerate(header):
        o.append(t(cx + 12, y + hh / 2 + 5, hd, 12.5, C["sub"], weight="500"))
        cx += widths[i]
    o.append(ln(x, y + hh, x + total, y + hh))
    yy = y + hh
    for i, row in enumerate(rows):
        if i in hl:
            o.append(r(x, yy, total, rh, fill=C["hlsoft"]))
        o.append(ln(x, yy + rh, x + total, yy + rh))
        cx = x
        for j, cell in enumerate(row):
            col, wt = C["text"], "400"
            if isinstance(cell, tuple):
                cell, col, wt = (list(cell) + [C["text"], "400"])[:3]
            if j == 0:
                o.append(r(cx + 12, yy + rh / 2 - 7, 14, 14, fill="#fff", stroke=C["input"], rx=2))
            else:
                o.append(t(cx + 12, yy + rh / 2 + 5, cell, 12.5, col, weight=wt))
            cx += widths[j]
        yy += rh
    o += [ln(x, yy, x + total, yy), ln(x, y, x, yy), ln(x + total, y, x + total, yy)]
    return "".join(o), yy


def legend(items, x, y, w=330):
    o = [r(x, y, w, 20 + 22 * len(items), fill="#fff", stroke=C["line"], rx=6)]
    for i, s in enumerate(items):
        o.append(mark(x + 20, y + 22 + 22 * i, str(i + 1), 9))
        o.append(t(x + 36, y + 26 + 22 * i, s, 12, C["text"]))
    return "".join(o)


def trunc(s, n):
    """表格单元格文字截断（模拟控制台省略号）"""
    return s if len(s) <= n else s[:n - 1] + "…"


def topbar(w=W):
    o = [r(0, 0, w, TOP, fill="#fff"), ln(0, TOP, w, TOP, C["line"]),
         r(16, 14, 20, 20, fill=C["primary"], rx=3),
         t(44, 30, "Alibaba Cloud", 15, C["primary"], weight="600"),
         r(170, 12, 66, 24, fill="#fff", stroke=C["line"], rx=4),
         t(203, 28, "工作台", 12.5, C["text"], "middle"),
         r(420, 10, 300, 28, fill="#f7f8fa", stroke=C["line"], rx=14),
         t(440, 29, "搜索", 12.5, C["muted"])]
    for i, m in enumerate(["费用", "备案", "企业", "支持", "工单"]):
        o.append(t(w - 400 + i * 46, 29, m, 12.5, C["sub"]))
    o += ['<circle cx="%s" cy="24" r="12" fill="#dfe3e8"/>' % (w - 62),
          t(w - 62, 28, "颜", 11, "#fff", "middle"),
          t(w - 24, 29, "yanxuewei", 12, C["sub"], anchor="end")]
    return "".join(o)


def sidebar(active, h=H):
    o = [r(0, TOP, NAVW, h - TOP, fill=C["nav"]), ln(NAVW, TOP, NAVW, h, C["line"])]
    y = TOP + 26
    for kind, label in NAV:
        if kind == "head":
            o.append(t(20, y + 4, label, 12, C["muted"], weight="600"))
            y += 30
        else:
            on = label == active
            if on:
                o += [r(8, y - 15, NAVW - 16, 28, fill=C["hov"], rx=4),
                      r(8, y - 15, 3, 28, fill=C["primary"], rx=1.5)]
            o.append(t(26, y + 4, label, 13, C["primary"] if on else C["text"], weight="500" if on else "400"))
            y += 28
    return "".join(o)


def page(active, crumb, title, toolbar_svg, body_svg):
    """标准列表页：面包屑 + 大标题 + 工具栏 + 主区"""
    o = [r(0, 0, W, H, fill=C["bg"]), topbar(), sidebar(active),
         t(NAVW + 24, TOP + 30, crumb, 13, C["sub"]),
         t(NAVW + 24, TOP + 74, title, 22, C["text"], weight="600")]
    o.append(toolbar_svg)
    o.append(body_svg)
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s">%s</svg>'
            % (W, H, W, H, "".join(o)))


def dialog(active, crumb, dlg_title, inner_fn, vw=780, vh=478):
    vx = NAVW + (W - NAVW - vw) / 2
    vy = TOP + (H - TOP - vh) / 2
    o = [r(0, 0, W, H, fill=C["bg"]), topbar(), sidebar(active),
         t(NAVW + 24, TOP + 30, crumb, 13, C["sub"]),
         r(NAVW, TOP, W - NAVW, H - TOP, fill="#000", op="0.22"),
         r(vx, vy, vw, vh, fill="#fff", rx=8),
         t(vx + 24, vy + 32, dlg_title, 16, C["text"], weight="600"),
         ln(vx, vy + 48, vx + vw, vy + 48, C["line"])]
    o.append(inner_fn(vx, vy, vw, vh))
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s">%s</svg>'
            % (W, H, W, H, "".join(o)))


def steps(vx, vy, cur):
    names = ["用户信息", "访问方式", "完成"]
    o = []
    for i, nm in enumerate(names):
        cx = vx + 56 + i * 175
        done = i + 1 < cur
        col = C["primary"] if (i + 1 <= cur) else C["input"]
        o.append('<circle cx="%.1f" cy="%.1f" r="10" fill="%s"/>' % (cx, vy + 86, col))
        o.append(t(cx, vy + 91, str(i + 1), 12, "#fff", "middle", "600"))
        o.append(t(cx + 18, vy + 91, nm, 12.5, C["text"] if i + 1 <= cur else C["muted"]))
        if i < 2:
            o.append(ln(cx + 12, vy + 86, cx + 160, vy + 86, C["line"], 2))
    return "".join(o)


def field(x, y, w, label, value="", hint=None, h=32, req=True):
    o = [t(x, y - 9, label, 13, C["text"])]
    if req:
        o.append(t(x + len(label) * 13 + 4, y - 9, "*", 13, C["red"]))
    o.append(r(x, y, w, h, fill="#fff", stroke=C["line"], rx=4))
    o.append(t(x + 12, y + h / 2 + 5, value or "请输入", 12.5, C["text"] if value else C["muted"]))
    if hint:
        o.append(t(x, y + h + 17, hint, 11.5, C["muted"]))
    return "".join(o)


def radio(x, y, label, checked=False, desc=None):
    o = ['<circle cx="%.1f" cy="%.1f" r="7" fill="#fff" stroke="%s" stroke-width="2"/>'
         % (x, y, C["primary"] if checked else C["input"])]
    if checked:
        o.append('<circle cx="%.1f" cy="%.1f" r="3.5" fill="%s"/>' % (x, y, C["primary"]))
    o.append(t(x + 16, y + 5, label, 13, C["text"]))
    if desc:
        o.append(t(x + 16, y + 23, desc, 11.5, C["muted"]))
    return "".join(o)


def checkbox(x, y, label, checked=True, disabled=False):
    o = [r(x, y - 9, 16, 16, fill=C["primary"] if checked else "#fff",
           stroke=C["primary"] if checked else C["input"], rx=3)]
    if checked:
        o.append('<path d="M%.1f %.1f l4 4 l7 -8" fill="none" stroke="#fff" stroke-width="2"/>'
                 % (x + 4, y - 1))
    o.append(t(x + 24, y + 4, label, 13, C["muted"] if disabled else C["text"]))
    return "".join(o)


def write(name, svg):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(svg)
    print("  ok", name)


# ════════ 01 权限策略列表 ════════
# 「已关联授权」列 = 云端实际 AttachmentCount（2026-09-26 实测）
POL = [("newapi-dev-program", "—", "1", "2026年9月25日 22:29:57"),
       ("newapi-prod-oss-guard", "—", "3", "2026年9月25日 22:24:37"),
       ("newapi-prod-boundary", "—", "3", "2026年9月25日 22:24:36"),
       ("newapi-audit-protect", "Deny write/delete of ActionTrail audit objects in both regions (tamper protection)", "8", "2026年9月25日 15:12:02"),
       ("newapi-oss-replication", "CRR minimal: ReplicateGet on src, ReplicatePut/Delete on dest", "1", "2026年9月25日 13:39:58"),
       ("newapi-admin-identity", "newapi admin: identity/audit management + read-only across services", "1", "2026年9月25日 11:42:21"),
       ("newapi-enforce-mfa", "true", "5", "2026年9月25日 11:41:00"),
       ("newapi-iac-terraform", "newapi terraform: IaC minimum set incl. ram:Get*, excl. ram:CreateUser and all RAM writes", "1", "2026年9月25日 11:39:24"),
       ("newapi-cicd-acr-push", "newapi cicd: ACR pull/push limited to newapi/* namespace", "1", "2026年9月25日 11:39:04"),
       ("newapi-ops-operator", "newapi ops: VPC/ECS/ACK/RDS/SLB/WAF/DNS describe + deploy write, deny RAM/account + destructive", "3", "2026年9月25日 11:38:47")]
tb = btn(NAVW + 24, TOP + 108, 132, 32, "创建权限策略", "primary", "1")
tb += (r(NAVW + 24, TOP + 156, 320, 32, fill="#fff", stroke=C["line"], rx=4)
       + t(NAVW + 36, TOP + 177, "筛选策略名称、备注", 12.5, C["muted"])
       + r(NAVW + 356, TOP + 156, 150, 32, fill="#fff", stroke=C["line"], rx=4)
       + t(NAVW + 368, TOP + 177, "策略类型：自定义策略 ▾", 12.5, C["text"])
       + r(NAVW + 518, TOP + 156, 120, 32, fill="#fff", stroke=C["line"], rx=4)
       + t(NAVW + 530, TOP + 177, "标签：请选择 ▾", 12.5, C["muted"]))
body, _ = table(NAVW + 24, TOP + 204,
                [46, 196, 88, 290, 102, 150],
                ["", "策略名称", "策略类型", "备注", "已关联授权", "创建时间"],
                # ⚠️ 每行首个元素落在「复选框列」，占位必须补 ""，否则整行数据左移一列
                [("", n, "自定义策略", trunc(d, 39), a, c) for n, d, a, c in POL])
write("01-权限策略列表.svg", page("权限策略", "RAM 访问控制  /  权限策略", "权限策略", tb, body))

# ════════ 02 用户组列表 ════════
# 用户组列表：10 个组，备注列 = 云端实际中文备注（2026-09-26 实测）
GRP = [("dev_group", "开发组(人)|策略:newapi-ops-operator+enforce-mfa+audit-protect+newapi-prod-boundary+newapi-prod-oss-guard|注意:非生产读写,生产只读;AK走dev程序组", "2026年9月26日 12:15:41"),
       ("fin_group", "财务组(人)|策略:AliyunBSSReadOnlyAccess+newapi-audit-protect|注意:仅查账单与费用,无资源写权限;纯控制台无AK;要看资源清单可另加ReadOnlyAccess", "2026年9月26日 11:53:08"),
       ("ops-prod_group", "生产运维组(人)|策略:newapi-ops-operator+enforce-mfa+audit-protect|注意:生产可写不可销毁,可删生产桶对象;优先走IaC,手工变更须补回Terraform;成员暂空", "2026年9月25日 22:58:23"),
       ("dev-program_group", "开发程序身份组(纯AK,无控制台)|策略:newapi-dev-program+newapi-prod-boundary+newapi-prod-oss-guard|注意:生产只读,写全挡;禁开LoginProfile;AK严禁提交git", "2026年9月25日 22:29:58"),
       ("admin_group", "管理人员组(人)|策略:newapi-admin-identity+audit-protect+enforce-mfa|注意:非生产全量管理,生产仅只读;登录控制台须绑MFA;策略仅组级承载,禁止用户级绑定", "2026年9月25日 21:03:27"),
       ("iac-terraform_group", "Terraform IaC组|策略:newapi-iac-terraform+newapi-audit-protect|注意:唯一能改生产OSS桶配置的自动化身份,故意不挂prod边界;变更须走流水线,勿手工跑", "2026年9月25日 11:18:37"),
       ("cicd-push_group", "CI/CD镜像推送组|策略:newapi-cicd-acr-push+newapi-audit-protect|注意:仅ACR镜像推拉权限;只发AK给流水线,不开控制台;勿并入其它组", "2026年9月25日 11:17:59"),
       ("ops_group", "非生产运维组(人)|策略:newapi-ops-operator+enforce-mfa+audit-protect+newapi-prod-boundary+newapi-prod-oss-guard|注意:生产只读,写全挡;须绑MFA;策略仅组级承载", "2026年9月25日 11:17:35"),
       ("power_user_group", "所有资源组(人)|策略:PowerUserAccess+newapi-enforce-mfa+newapi-audit-protect|注意:权限近账号级,须绑MFA;仅临时查问题用,勿长期加人", "2026年9月25日 11:17:12"),
       ("super_group", "主账号身份组(人)|策略:AdministratorAccess等20条|成员:yanxuewei", "2026年9月24日 22:36:07")]
tb2 = btn(NAVW + 24, TOP + 108, 116, 32, "创建用户组", "primary", "1")
tb2 += (r(NAVW + 160, TOP + 108, 340, 32, fill="#fff", stroke=C["line"], rx=4)
        + t(NAVW + 172, TOP + 129, "筛选用户组名称、显示名称、备注", 12.5, C["muted"]))
body2, _ = table(NAVW + 24, TOP + 156,
                 [46, 180, 180, 306, 160],
                 ["", "用户组名称 / 显示名称", "备注", "创建时间", "操作"],
                 [("", g, trunc(cm, 22), ct, "添加用户  新增授权  ⋮") for g, cm, ct in GRP],
                 hl=(0, 1))
write("02-用户组列表.svg", page("用户组", "RAM 访问控制  /  用户组", "用户组", tb2, body2))

# ════════ 03 创建用户 · 步骤1 ════════


def inner03(vx, vy, vw, vh):
    return (steps(vx, vy, 1)
            + field(vx + 48, vy + 158, 420, "登录名称", "zhangzijun",
                    hint="控制台登录名 / API 调用标识。创建后不可修改，建议用「姓名拼音」")
            + callout(vx + 40, vy + 136, 440, 82, "1")
            + field(vx + 48, vy + 262, 420, "显示名称", "张子俊",
                    hint="仅用于展示，可随时修改")
            + t(vx + 48, vy + 352, "标签", 13, C["text"])
            + r(vx + 48, vy + 368, 180, 32, fill="#fff", stroke=C["line"], rx=4)
            + t(vx + 60, vy + 389, "键  project", 12.5, C["muted"])
            + r(vx + 240, vy + 368, 180, 32, fill="#fff", stroke=C["line"], rx=4)
            + t(vx + 252, vy + 389, "值  new-api", 12.5, C["muted"])
            + callout(vx + 40, vy + 338, 440, 74, "2")
            + btn(vx + vw - 220, vy + vh - 56, 88, 32, "取消", "ghost")
            + btn(vx + vw - 120, vy + vh - 56, 88, 32, "下一步", "primary"))


write("03-创建用户-步骤1-用户信息.svg",
      dialog("用户", "RAM 访问控制  /  用户", "创建用户", inner03))

# ════════ 04 创建用户 · 步骤2 访问方式 ════════


def inner04(vx, vy, vw, vh):
    o = [steps(vx, vy, 2),
         t(vx + 48, vy + 140, "访问方式（可同时勾选）", 13, C["text"], weight="500"),
         r(vx + 48, vy + 152, vw - 96, 148, fill="#fbfbfc", stroke=C["line"], rx=6),
         checkbox(vx + 68, vy + 180, "控制台访问", True),
         t(vx + 92, vy + 204, "为 RAM 用户开启控制台登录（需设置密码）", 11.5, C["muted"]),
         radio(vx + 92, vy + 230, "自动生成默认密码", True),
         radio(vx + 300, vy + 230, "自定义密码"),
         checkbox(vx + 92, vy + 268, "要求下次登录时重置密码", True),
         checkbox(vx + 340, vy + 268, "需要 MFA 多因素认证", True),
         r(vx + 48, vy + 312, vw - 96, 92, fill="#fbfbfc", stroke=C["line"], rx=6),
         checkbox(vx + 68, vy + 340, "OpenAPI 调用访问", True),
         t(vx + 92, vy + 364, "自动创建 AccessKey ID / Secret（Secret 仅创建时显示一次）", 11.5, C["muted"]),
         t(vx + 92, vy + 386, "⚠ 纯程序身份（dev-*、cicd-*、iac-*）只勾此项，不要开控制台访问", 11.5, C["red"]),
         callout(vx + 40, vy + 128, vw - 80, 100, "1"),
         callout(vx + 40, vy + 296, vw - 80, 120, "2"),
         btn(vx + vw - 320, vy + vh - 56, 88, 32, "上一步", "ghost"),
         btn(vx + vw - 220, vy + vh - 56, 88, 32, "取消", "ghost"),
         btn(vx + vw - 120, vy + vh - 56, 88, 32, "下一步", "primary")]
    return "".join(o)


write("04-创建用户-步骤2-访问方式.svg",
      dialog("用户", "RAM 访问控制  /  用户", "创建用户", inner04, vh=520))

# ════════ 05 创建用户 · 步骤3 完成 ════════


def inner05(vx, vy, vw, vh):
    return (steps(vx, vy, 3)
            + '<circle cx="%.1f" cy="%.1f" r="16" fill="%s"/>' % (vx + 64, vy + 152, C["green"])
            + '<path d="M%.1f %.1f l6 6 l11 -13" fill="none" stroke="#fff" stroke-width="2.5"/>'
            % (vx + 57, vy + 152)
            + t(vx + 92, vy + 158, "用户 zhangzijun 创建成功", 15, C["text"], weight="600")
            + t(vx + 92, vy + 180, "控制台登录：已开启（要求首次登录重置密码 + 需要 MFA）", 12, C["sub"])
            + t(vx + 92, vy + 200, "OpenAPI：已创建 AccessKey", 12, C["sub"])
            + r(vx + 48, vy + 224, vw - 96, 128, fill="#fff9f5", stroke=C["hl"], rx=6, dash="6 4")
            + t(vx + 68, vy + 252, "AccessKey ID", 12, C["sub"])
            + t(vx + 68, vy + 274, "LTAI5tXXXXXXXXXXXXXX", 13, C["text"])
            + t(vx + 68, vy + 302, "AccessKey Secret", 12, C["sub"])
            + t(vx + 68, vy + 324, "＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊＊（仅此一次可见）", 13, C["text"])
            + callout(vx + 40, vy + 212, vw - 80, 152, "1")
            + btn(vx + vw - 372, vy + vh - 56, 128, 32, "下载 CSV 凭证", "ghost")
            + btn(vx + vw - 220, vy + vh - 56, 88, 32, "复制", "ghost")
            + btn(vx + vw - 120, vy + vh - 56, 88, 32, "完成", "primary"))


write("05-创建用户-步骤3-保存AK.svg",
      dialog("用户", "RAM 访问控制  /  用户", "创建用户", inner05, vh=520))

# ════════ 06 用户列表 ════════
USR = [("admin", "admin", "admin_group", "已开启", "0 个", ""),
       ("ops", "ops", "ops_group", "已开启", "0 个", ""),
       ("cicd-push", "cicd-push", "cicd-push_group", "未开启", "1 个", ""),
       ("iac-terraform", "iac-terraform", "iac-terraform_group", "未开启", "1 个", ""),
       ("zhangzijun", "zhangzijun", "dev_group", "已开启", "0 个", ""),
       ("xiangdong", "xiangdong", "dev_group", "已开启", "0 个", ""),
       ("dev-zhangzijun", "dev-zhangzijun", "dev-program_group", "未开启", "1 个", ""),
       ("dev-xiangdong", "dev-xiangdong", "dev-program_group", "未开启", "1 个", ""),
       ("yanxuewei", "yanxuewei", "super_group", "已开启", "0 个", "")]
tb3 = btn(NAVW + 24, TOP + 108, 96, 32, "创建用户", "primary", "1")
tb3 += (r(NAVW + 140, TOP + 108, 320, 32, fill="#fff", stroke=C["line"], rx=4)
        + t(NAVW + 152, TOP + 129, "筛选登录名称、显示名称", 12.5, C["muted"]))
body3, _ = table(NAVW + 24, TOP + 156,
                 [46, 158, 148, 186, 108, 92, 134],
                 ["", "登录名称", "显示名称", "用户组", "控制台访问", "AccessKey", "操作"],
                 [("", u, d, g, c, a, "移除用户   ⋮") for u, d, g, c, a, _ in USR],
                 hl=(4,))
write("06-用户列表.svg", page("用户", "RAM 访问控制  /  用户", "用户", tb3, body3))

# ════════ 07 用户组 · 添加用户 ════════


def inner07(vx, vy, vw, vh):
    o = [r(vx + 48, vy + 76, 300, 32, fill="#fff", stroke=C["line"], rx=4)
         + t(vx + 60, vy + 97, "筛选登录名称、显示名称", 12.5, C["muted"]),
         r(vx + 48, vy + 124, vw - 96, 250, fill="#fff", stroke=C["line"], rx=6)]
    rows = [("zhangzijun", "张子俊", "dev_group", True),
            ("xiangdong", "向东", "dev_group", False),
            ("ops", "运维值班", "ops_group", False),
            ("dev-zhangzijun", "张子俊（程序）", "dev-program_group", False),
            ("yanxuewei", "颜学伟", "super_group", False)]
    for i, (n, d, grp, ck) in enumerate(rows):
        yy = vy + 148 + i * 44
        if i:
            o.append(ln(vx + 48, yy - 22, vx + vw - 48, yy - 22, C["line"]))
        o.append(checkbox(vx + 68, yy, "", ck))
        o.append(t(vx + 96, yy + 5, n, 13, C["text"]))
        o.append(t(vx + 300, yy + 5, d, 12.5, C["sub"]))
        o.append(t(vx + 520, yy + 5, "当前所属：" + grp, 11.5, C["muted"]))
    o += [callout(vx + 40, vy + 112, vw - 80, 274, "1"),
          btn(vx + vw - 220, vy + vh - 56, 88, 32, "取消", "ghost"),
          btn(vx + vw - 120, vy + vh - 56, 88, 32, "确定", "primary", "2")]
    return "".join(o)


write("07-用户组-添加用户.svg",
      dialog("用户组", "RAM 访问控制  /  用户组", "添加用户 · ops_group", inner07, vh=470))

# ════════ 08 用户组 · 新增授权 ════════


def inner08(vx, vy, vw, vh):
    o = [r(vx + 48, vy + 76, 300, 32, fill="#fff", stroke=C["line"], rx=4)
         + t(vx + 60, vy + 97, "筛选策略名称、备注", 12.5, C["muted"]),
         r(vx + 48, vy + 124, vw - 96, 250, fill="#fff", stroke=C["line"], rx=6)]
    rows = [("newapi-ops-operator", "运维读写 + 禁止销毁", True),
            ("newapi-enforce-mfa", "强制 MFA（控制台会话）", True),
            ("newapi-audit-protect", "保护 ActionTrail 审计对象", True),
            ("newapi-prod-boundary", "生产资源只读边界", False),
            ("newapi-prod-oss-guard", "生产桶写删兜底", False),
            ("AliyunBSSReadOnlyAccess", "费用中心只读（系统策略）", False)]
    for i, (n, d, ck) in enumerate(rows):
        yy = vy + 148 + i * 42
        if i:
            o.append(ln(vx + 48, yy - 21, vx + vw - 48, yy - 21, C["line"]))
        o.append(checkbox(vx + 68, yy, "", ck))
        o.append(t(vx + 96, yy + 5, n, 12.5, C["text"]))
        o.append(t(vx + 400, yy + 5, d, 11.5, C["muted"]))
    o += [callout(vx + 40, vy + 112, vw - 80, 274, "1"),
          btn(vx + vw - 220, vy + vh - 56, 88, 32, "取消", "ghost"),
          btn(vx + vw - 120, vy + vh - 56, 88, 32, "确定", "primary", "2")]
    return "".join(o)


write("08-用户组-新增授权.svg",
      dialog("用户组", "RAM 访问控制  /  用户组", "新增授权 · ops_group", inner08, vh=470))

# ════════ 09 移除用户 / 删除用户 ════════
tb4 = btn(NAVW + 24, TOP + 108, 96, 32, "创建用户", "primary")
body4, _ = table(NAVW + 24, TOP + 156,
                 [46, 158, 148, 186, 108, 92, 134],
                 ["", "登录名称", "显示名称", "用户组", "控制台访问", "AccessKey", "操作"],
                 [("", u, d, g, c, a, op) for u, d, g, c, a, op in
                  [("admin", "admin", "admin_group", "已开启", "0 个", "移除用户   ⋮"),
                   ("ops", "ops", "ops_group", "已开启", "0 个", "移除用户   ⋮"),
                   ("zhangzijun", "张子俊", "dev_group", "已开启", "0 个", "移除用户   ⋮"),
                   ("dev-zhangzijun", "张子俊（程序）", "dev-program_group", "未开启", "1 个", "移除用户   ⋮")]],
                 hl=(2,))
# 行内下拉菜单（挂在第 3 行右侧「⋮」处）
OPX = NAVW + 24 + 46 + 158 + 148 + 186 + 108 + 92   # 操作列起点 = 962
table_y0 = TOP + 156                                 # 204
row3_top = table_y0 + 38 + 34 * 2                    # 310
menu = (r(OPX - 12, row3_top + 34, 140, 76, fill="#fff", stroke=C["line"], rx=6)
        + t(OPX, row3_top + 60, "查看详情", 12.5, C["link"])
        + ln(OPX - 4, row3_top + 72, OPX + 128, row3_top + 72, C["line"])
        + t(OPX, row3_top + 96, "删除用户", 12.5, C["red"])
        + callout(OPX - 2, row3_top + 2, 76, 30, "1")
        + callout(OPX - 18, row3_top + 26, 152, 92, "2"))
# 二次确认弹窗
cx0, cy0 = NAVW + 60, TOP + 360
confirm = (r(NAVW, TOP, W - NAVW, H - TOP, fill="#000", op="0.22")
           + r(cx0, cy0, 620, 150, fill="#fff", rx=8)
           + t(cx0 + 24, cy0 + 34, "删除用户", 16, C["text"], weight="600")
           + t(cx0 + 24, cy0 + 68, "删除后该用户的 AccessKey、登录密码、MFA 设备将立即失效，且不可恢复。", 12.5, C["sub"])
           + t(cx0 + 24, cy0 + 90, "请先确认该用户已从所有用户组移除、已无在用 AccessKey。", 12.5, C["sub"])
           + btn(cx0 + 380, cy0 + 104, 88, 32, "取消", "ghost")
           + btn(cx0 + 484, cy0 + 104, 112, 32, "确认删除", "primary", "3"))
write("09-移除与删除用户.svg", page("用户", "RAM 访问控制  /  用户", "用户", tb4, body4 + menu + confirm))

# ════════ 10 七类角色映射 ════════
def role_map():
    # 七类角色 → 用户组 → 权限策略；行高固定，画布高度按行数推导
    ROW_H, BOX_H, Y0 = 100, 92, 104
    rows = [
        ("管理人员 admin", "admin_group",
         ["newapi-admin-identity", "newapi-enforce-mfa", "newapi-audit-protect"],
         "管账号：建用户/发 AK/绑策略；业务资源只能看"),
        ("财务 finance", "fin_group",
         ["AliyunBSSReadOnlyAccess", "newapi-audit-protect"],
         "只看账单与费用，不能改任何东西；无 AK"),
        ("开发 dev（人·控制台）", "dev_group",
         ["newapi-ops-operator", "newapi-enforce-mfa", "newapi-audit-protect",
          "newapi-prod-boundary", "newapi-prod-oss-guard"],
         "非生产读写；生产只读；须绑 MFA；不发 AK"),
        ("开发程序 dev-program（纯 AK）", "dev-program_group",
         ["newapi-dev-program", "newapi-prod-boundary", "newapi-prod-oss-guard"],
         "非生产 OSS 写 + 镜像推拉 + 全账号只读；无控制台"),
        ("开发 Leader", "dev_group + dev-program_group",
         ["newapi-ops-operator", "newapi-enforce-mfa", "newapi-audit-protect",
          "newapi-prod-boundary", "newapi-prod-oss-guard", "newapi-dev-program"],
         "人 + 程序双身份：改非生产、持有 AK"),
        ("初级运维 ops", "ops_group",
         ["newapi-ops-operator", "newapi-enforce-mfa", "newapi-audit-protect",
          "newapi-prod-boundary", "newapi-prod-oss-guard"],
         "非生产运维；生产只读；不可销毁；须绑 MFA"),
        ("运维 Leader", "ops-prod_group + ops_group",
         ["newapi-ops-operator", "newapi-enforce-mfa", "newapi-audit-protect"],
         "生产可写不可销毁；应急通道；优先走 IaC"),
    ]
    w = 1120
    h = Y0 + len(rows) * ROW_H + 20
    o = [r(0, 0, w, h, fill="#fff"),
         t(40, 44, "七类角色 → 用户组 → 权限策略 映射", 20, C["text"], weight="600"),
         t(40, 70, "每组左列是角色、中列是用户组、右列是挂在该组上的策略。人是控制台身份，程序是 AK 身份，两者分开。",
           12.5, C["sub"])]
    y = Y0
    for i, (name, grp, pols, desc) in enumerate(rows):
        o.append(r(40, y, 1040, BOX_H, fill="#fbfbfc" if i % 2 else "#f6f7f9",
                   stroke=C["line"], rx=8))
        o.append(r(40, y, 4, BOX_H, fill=C["primary"], rx=2))
        o.append(t(64, y + 36, name, 15, C["text"], weight="600"))
        o.append(t(64, y + 66, desc, 11.5, C["sub"]))
        o.append(t(300, y + 30, "用户组", 11, C["muted"]))
        o.append(r(300, y + 40, 240, 30, fill="#fff", stroke=C["primary"], rx=5))
        o.append(t(312, y + 60, grp, 12, C["primary"], weight="500"))
        o.append(t(620, y + 30, "权限策略", 11, C["muted"]))
        px, py = 620, y + 38
        for p in pols:
            cw = len(p) * 6.5 + 16
            if px + cw > 1064:
                px, py = 620, py + 25
            o.append(r(px, py, cw, 22, fill="#fff", stroke=C["line"], rx=4))
            o.append(t(px + 8, py + 15, p, 11, C["sub"]))
            px += cw + 6
        y += ROW_H
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s">%s</svg>'
            % (w, h, w, h, "".join(o)))


write("10-七类角色映射.svg", role_map())


# ════════ 画廊 index.html ════════
GALLERY_CAPTIONS = {
    "01-权限策略列表": "权限策略列表页 · 「已关联授权」列 = 引用计数（点进去看挂在哪些组）",
    "02-用户组列表": "用户组列表页 · 10 个组 + 云端实际中文备注（超过 22 字截断显示）",
    "03-创建用户-步骤1-用户信息": "创建用户 · 步骤 1：登录名称 / 显示名称 / 标签",
    "04-创建用户-步骤2-访问方式": "创建用户 · 步骤 2：控制台访问 + OpenAPI 调用访问（纯程序身份只勾后者）",
    "05-创建用户-步骤3-保存AK": "创建用户 · 步骤 3：AccessKey Secret 仅此一次可见",
    "06-用户列表": "用户列表页 · 9 个用户及其所属组（`zhangzijun` / `xiangdong` 在 `dev_group`）",
    "07-用户组-添加用户": "用户组 · 添加用户弹窗（显示每人「当前所属」）",
    "08-用户组-新增授权": "用户组 · 新增授权弹窗（勾选要绑的策略）",
    "09-移除与删除用户": "移除用户 / 删除用户（删除不可恢复，先删 AK 观察一周）",
    "10-七类角色映射": "七类角色 → 用户组 → 权限策略 总览",
}


def gallery():
    import glob
    files = sorted(glob.glob(os.path.join(OUT, "*.svg")))
    files = [f for f in files if "六角色映射" not in os.path.basename(f)]   # 废弃旧图不展示
    secs = []
    for f in files:
        stem = os.path.basename(f)[:-4]
        svg = open(f, encoding="utf-8").read()
        svg = re.sub(r'\swidth="\d+"\s+height="\d+"', ' width="100%"', svg, count=1)
        cap = GALLERY_CAPTIONS.get(stem, stem)
        secs.append('<section><h2>%s</h2><p>%s</p><div class="fig">%s</div></section>'
                    % (stem, cap, svg))
    html = '''<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>用户设置指南 · 控制台操作配图</title>
<style>
 body{margin:0;background:#f2f3f5;font:14px/1.6 -apple-system,"PingFang SC",sans-serif;color:#1f2329}
 header{background:#fff;border-bottom:1px solid #e8eaed;padding:22px 32px;position:sticky;top:0;z-index:9}
 header h1{margin:0;font-size:19px} header p{margin:4px 0 0;color:#646a73;font-size:12.5px}
 main{padding:24px 32px 60px;max-width:1240px;margin:0 auto}
 section{background:#fff;border:1px solid #e8eaed;border-radius:10px;padding:20px;margin-bottom:22px}
 section h2{margin:0 0 4px;font-size:15px} section p{margin:0 0 14px;color:#646a73;font-size:12.5px}
 .fig{overflow:auto;border:1px solid #eef0f3;border-radius:8px}
 code{background:#f2f3f5;border-radius:3px;padding:1px 4px;font-size:12px}
</style></head><body>
<header><h1>用户设置指南 · 控制台操作配图</h1>
<p>阿里云国际站 RAM 访问控制 · 由 <code>gen_guide_images.py</code> 生成 ·
   GitHub 上看内联 SVG 的 md 会被过滤，这里作为备用画廊</p></header>
<main>
%s
</main></body></html>''' % "\n".join(secs)
    p = os.path.join(OUT, "index.html")
    with open(p, "w", encoding="utf-8") as f:
        f.write(html)
    print("  ok index.html（画廊，%d 张）" % len(files))


gallery()

print("\n完成 →", OUT)
