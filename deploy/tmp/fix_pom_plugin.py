#!/usr/bin/env python3
"""fix_pom_plugin.py - 给 customer/supplier pom.xml 补 spring-boot-maven-plugin"""
import os, re

BASE = "/opt/OmniTradeERP"

PLUGIN_XML = """
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>"""

for svc in ["erp-customer-service", "erp-supplier-service"]:
    pom = os.path.join(BASE, svc, "pom.xml")
    content = open(pom).read()
    if "spring-boot-maven-plugin" in content:
        print(f"OK     {svc} already has plugin")
        continue
    # 在 </plugins> 前插入
    if "</plugins>" in content:
        fixed = content.replace("</plugins>", PLUGIN_XML + "\n        </plugins>", 1)
        open(pom, 'w').write(fixed)
        print(f"FIXED  {svc}/pom.xml + spring-boot-maven-plugin")
    elif "<build>" in content:
        # 在 </build> 前插入完整 plugins 块
        plugins_block = "\n        <plugins>" + PLUGIN_XML + "\n        </plugins>\n    "
        fixed = content.replace("</build>", plugins_block + "</build>", 1)
        open(pom, 'w').write(fixed)
        print(f"FIXED  {svc}/pom.xml added plugins block")
    else:
        # 在 </dependencies> 后插入 build 块
        build_block = "\n    <build>\n        <plugins>" + PLUGIN_XML + "\n        </plugins>\n    </build>\n"
        fixed = content.replace("</project>", build_block + "</project>", 1)
        open(pom, 'w').write(fixed)
        print(f"FIXED  {svc}/pom.xml added build block")

print("\nALL DONE")
