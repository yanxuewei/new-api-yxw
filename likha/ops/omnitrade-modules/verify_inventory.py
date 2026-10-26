# -*- coding: utf-8 -*-
"""独立库存验收；仅显式运行时写入VERIFY专用记录，finally精确补偿与清理。兼容Python 3.6。"""
import io
import json
import os
import pathlib
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile

SRC = pathlib.Path('/opt/OmniTradeERP/ops/module-repair')
BASE = 'http://127.0.0.1:8080/api'
CONTAINER = 'erp-minimal-mysql'
TOKEN = None
MYSQL_PASSWORD = None
PREFIX = 'VERIFY-INV-' + uuid.uuid4().hex[:16]
SKU = PREFIX + '-SKU'
PRODUCT_ID = secrets.randbelow(2 ** 51 - 1) + 2 ** 51
SKU_ID = secrets.randbelow(2 ** 51 - 1) + 2 ** 51
CODES = [PREFIX + '-A', PREFIX + '-B']


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, text=None, env=None):
    result = subprocess.run(args, input=text, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True)
    if result.returncode:
        # 不打印命令、环境或stderr，避免泄露数据库密码。
        raise RuntimeError('数据库工具执行失败，退出码={}'.format(result.returncode))
    return result.stdout


def sql(statement):
    env = os.environ.copy()
    env['MYSQL_PWD'] = MYSQL_PASSWORD
    return run(['docker', 'exec', '-i', '-e', 'MYSQL_PWD', CONTAINER,
                'mysql', '-uroot', '--batch', '--skip-column-names', '--default-character-set=utf8mb4'], statement, env)


def quoted(value):
    # SQL只拼接本脚本生成的随机标识；禁止任何外部字符串。
    require(all(c.isalnum() or c == '-' for c in value), '非法测试标识')
    return "'" + value + "'"


def request(path, method='GET', body=None, expected=200, auth=True, binary=False):
    headers = {'Content-Type': 'application/json'}
    if TOKEN and auth:
        headers['Authorization'] = 'Bearer ' + TOKEN
    req = urllib.request.Request(BASE + path, data=None if body is None else json.dumps(body).encode('utf-8'), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            status, raw = response.status, response.read()
            content_type = response.headers.get('Content-Type', '')
    except urllib.error.HTTPError as error:
        status, raw, content_type = error.code, error.read(), ''
    allowed = expected if isinstance(expected, tuple) else (expected,)
    require(status in allowed, '{} {} 返回{}，预期{}'.format(method, path, status, allowed))
    print('PASS', method, path, status)
    if binary:
        return raw, content_type
    try:
        return json.loads(raw.decode('utf-8')) if raw else None
    except ValueError:
        raise RuntimeError('接口未返回JSON：' + path)


def inventory(warehouse_id):
    result = request('/inventory/list?' + urllib.parse.urlencode({'warehouseId': warehouse_id, 'skuCode': SKU, 'current': 1, 'size': 20}))
    records = [x for x in result['records'] if x['skuCode'] == SKU]
    require(len(records) == 1, '专用库存记录数不等于1')
    return records[0]


def balance(inventory_id, available, locked=0):
    value = request('/inventory/' + str(inventory_id))
    require((value['availableQty'], value['lockedQty'], value['totalQty']) == (available, locked, available + locked), '库存数量或锁定量不符合预期')
    return value


def adjust(inventory_id, kind, quantity, expected=200):
    return request('/inventory/adjust', 'POST', {'inventoryId': inventory_id, 'type': kind, 'quantity': quantity, 'reason': 'check', 'remark': PREFIX}, expected)


def exercise():
    global TOKEN, MYSQL_PASSWORD
    info = json.loads(run(['docker', 'inspect', CONTAINER]))[0]
    MYSQL_PASSWORD = next(v.split('=', 1)[1] for v in info['Config']['Env'] if v.startswith('MYSQL_ROOT_PASSWORD='))
    credentials = json.loads((SRC / 'erpadmin.credentials').read_text())
    login = request('/auth/login', 'POST', credentials, auth=False)
    require(login.get('code') == 200, '管理员登录失败')
    TOKEN = login['data']['token']
    print('VERIFY_PREFIX', PREFIX)
    try:
        sql("START TRANSACTION; INSERT INTO erp_product.t_product(id,internal_sku,product_name,status) VALUES ({},{},{},1); INSERT INTO erp_product.t_product_sku(id,product_id,sku_code,sku_name,status) VALUES ({},{},{},{},1); COMMIT;".format(PRODUCT_ID, quoted(PREFIX), quoted(PREFIX), SKU_ID, PRODUCT_ID, quoted(SKU), quoted(SKU)))
        warehouses, locations = [], []
        for code in CODES:
            warehouse = request('/warehouse', 'POST', {'warehouseCode': code, 'warehouseName': code, 'warehouseType': 'main', 'status': 1, 'isDefault': 0})
            warehouses.append(warehouse['id'])
            location = request('/warehouse/location', 'POST', {'warehouseId': warehouse['id'], 'locationCode': code + '-L', 'locationType': 'shelf', 'status': 1})
            locations.append(location['id'])
        wa, wb = warehouses
        la, lb = locations
        require(isinstance(request('/warehouse/list'), list), '仓库无current参数时必须返回数组')
        require('records' in request('/warehouse/list?current=1&size=20'), '仓库分页响应缺少records')
        request('/inventory/import', 'POST', [{'skuCode': SKU, 'warehouseId': wa, 'locationId': la, 'availableQty': 20, 'safetyStock': 5, 'remark': PREFIX}])
        source = inventory(wa)
        sid = source['id']
        require(source['productName'] == PREFIX, 'SKU未关联真实商品名称')
        balance(sid, 20)
        adjust(sid, 'increase', 5)
        adjust(sid, 'decrease', 2)
        balance(sid, 23)
        logs_before = request('/inventory/{}/flows'.format(sid))['total']
        adjust(sid, 'decrease', 24, 400)
        balance(sid, 23)
        require(request('/inventory/{}/flows'.format(sid))['total'] == logs_before, '非法扣减写入了流水')
        # 第二行故意非法，验证第一行库存和流水也回滚。
        request('/inventory/import', 'POST', [{'skuCode': SKU, 'warehouseId': wa, 'availableQty': 999}, {'skuCode': SKU, 'warehouseId': wb, 'availableQty': -1}], 400)
        balance(sid, 23)
        require(request('/inventory/{}/flows'.format(sid))['total'] == logs_before, '导入失败后仍存在新增流水')
        require(sql('SELECT COUNT(*) FROM erp_inventory.t_inventory WHERE sku_code={} AND warehouse_id={};'.format(quoted(SKU), wb)).strip() == '0', '失败导入未回滚新建库存')
        # 仅锁定本次创建的3件库存，保持总量不变，检查业务写入不能消耗锁定量。
        sql('START TRANSACTION; SELECT id FROM erp_inventory.t_repair_inventory_guard WHERE id=1 FOR UPDATE; UPDATE erp_inventory.t_inventory SET available_qty=20,locked_qty=3 WHERE id={} AND sku_code={} AND warehouse_id={} AND available_qty=23 AND locked_qty=0 AND total_qty=23; COMMIT;'.format(sid, quoted(SKU), wa))
        balance(sid, 20, 3)
        transfer = {'fromInventoryId': sid, 'toWarehouseId': wb, 'toLocationId': lb, 'quantity': 21, 'remark': PREFIX}
        request('/inventory/transfer', 'POST', transfer, 409)
        balance(sid, 20, 3)
        transfer['quantity'] = 7
        moved = request('/inventory/transfer', 'POST', transfer)
        target = inventory(wb)
        tid = target['id']
        balance(sid, 13, 3)
        balance(tid, 7)
        require(target['locationId'] == lb, '目标库位未正确记录')
        for iid, kind in [(sid, 'out'), (tid, 'in')]:
            rows = request('/inventory/{}/flows?current=1&size=100'.format(iid))['records']
            require(any(x['orderNo'] == moved['orderNo'] and x['flowType'] == kind and x['quantity'] == 7 for x in rows), '缺少匹配的双向调拨流水')
        adjust(sid, 'set', 0)
        balance(sid, 0, 3)
        export, mime = request('/inventory/export?' + urllib.parse.urlencode({'skuCode': SKU}), binary=True)
        require('spreadsheetml.sheet' in mime, '导出Content-Type不是XLSX')
        with zipfile.ZipFile(io.BytesIO(export)) as archive:
            require(archive.testzip() is None, '导出ZIP损坏')
            sheet = ET.fromstring(archive.read('xl/worksheets/sheet1.xml'))
            require(any(e.text == SKU for e in sheet.iter()), '导出缺少测试SKU')
            for name in ['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels']:
                ET.fromstring(archive.read(name))
        request('/warehouse/' + str(wa), 'DELETE', expected=409)
        request('/warehouse/location/' + str(lb), 'DELETE', expected=409)
        request('/inventory/unsupported-verify', 'POST', {}, 501)
        print('INVENTORY_ACCEPTANCE_OK')
    finally:
        cleanup()


def cleanup():
    # 即使HTTP创建成功但响应丢失，也按本次唯一完整编码恢复精确ID，不使用LIKE或时间范围。
    warehouse_rows = sql('SELECT id FROM erp_warehouse.t_warehouse WHERE warehouse_code IN ({},{});'.format(*[quoted(x) for x in CODES])).split()
    warehouse_ids = [int(x) for x in warehouse_rows]
    inventories = []
    if warehouse_ids:
        ids = ','.join(str(x) for x in warehouse_ids)
        raw = sql('SELECT id,warehouse_id FROM erp_inventory.t_inventory WHERE sku_code={} AND warehouse_id IN ({});'.format(quoted(SKU), ids))
        inventories = [(int(r.split()[0]), int(r.split()[1])) for r in raw.splitlines() if r.strip()]
    for iid, wid in inventories:
        # 解除本次测试设定的锁量，再通过公开调整接口补偿回零；HTTP失败不阻止精确SQL清理。
        sql('START TRANSACTION; SELECT id FROM erp_inventory.t_repair_inventory_guard WHERE id=1 FOR UPDATE; UPDATE erp_inventory.t_inventory SET available_qty=total_qty,locked_qty=0 WHERE id={} AND sku_code={} AND warehouse_id={}; COMMIT;'.format(iid, quoted(SKU), wid))
        try:
            adjust(iid, 'set', 0)
            balance(iid, 0)
        except Exception:
            print('WARN 测试记录API补偿失败，将按精确测试ID清理', iid)
    statements = ['START TRANSACTION', 'SELECT id FROM erp_inventory.t_repair_inventory_guard WHERE id=1 FOR UPDATE']
    if warehouse_ids:
        ids = ','.join(str(x) for x in warehouse_ids)
        # 阻止删除意外写入专用仓库的非测试SKU或出入库单。
        foreign = sql('SELECT (SELECT COUNT(*) FROM erp_inventory.t_inventory WHERE warehouse_id IN ({}) AND sku_code<>{})+(SELECT COUNT(*) FROM erp_warehouse.t_warehouse_in_out WHERE warehouse_id IN ({}));'.format(ids, quoted(SKU), ids)).strip()
        require(foreign == '0', '清理停止：测试仓库存在非本次测试关联数据；请人工核实' + PREFIX)
        for iid, wid in inventories:
            for table in ['t_repair_alert_replenishment', 't_repair_alert_record']:
                exists = sql("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='erp_inventory' AND table_name='{}';".format(table)).strip()
                if exists == '1':
                    statements.append('DELETE FROM erp_inventory.{} WHERE inventory_id={} AND sku={} AND warehouse_id={}'.format(table, iid, quoted(SKU), wid))
            statements.append('DELETE FROM erp_inventory.t_repair_inventory_location WHERE inventory_id={}'.format(iid))
            statements.append('DELETE FROM erp_inventory.t_inventory_log WHERE sku_code={} AND warehouse_id={}'.format(quoted(SKU), wid))
            statements.append('DELETE FROM erp_inventory.t_inventory WHERE id={} AND sku_code={} AND warehouse_id={}'.format(iid, quoted(SKU), wid))
        for wid, code in [(int(row.split()[0]), row.split()[1]) for row in sql('SELECT id,warehouse_code FROM erp_warehouse.t_warehouse WHERE warehouse_code IN ({},{});'.format(*[quoted(x) for x in CODES])).splitlines() if row.strip()]:
            statements.append('DELETE FROM erp_warehouse.t_repair_warehouse_location WHERE warehouse_id={} AND location_code={}'.format(wid, quoted(code + '-L')))
            statements.append('DELETE FROM erp_warehouse.t_repair_warehouse_extra WHERE warehouse_id={}'.format(wid))
            statements.append('DELETE FROM erp_warehouse.t_warehouse WHERE id={} AND warehouse_code={}'.format(wid, quoted(code)))
    statements.append('DELETE FROM erp_product.t_product_sku WHERE id={} AND product_id={} AND sku_code={}'.format(SKU_ID, PRODUCT_ID, quoted(SKU)))
    statements.append('DELETE FROM erp_product.t_product WHERE id={} AND internal_sku={}'.format(PRODUCT_ID, quoted(PREFIX)))
    statements.append('COMMIT')
    sql(';\n'.join(statements) + ';')
    remaining = sql('SELECT (SELECT COUNT(*) FROM erp_product.t_product WHERE id={} AND internal_sku={})+(SELECT COUNT(*) FROM erp_product.t_product_sku WHERE id={} AND sku_code={})+(SELECT COUNT(*) FROM erp_warehouse.t_warehouse WHERE warehouse_code IN ({},{}));'.format(PRODUCT_ID, quoted(PREFIX), SKU_ID, quoted(SKU), *[quoted(x) for x in CODES])).strip()
    require(remaining == '0', '测试记录未清理干净：' + PREFIX)
    print('INVENTORY_CLEANUP_OK', PREFIX)


if __name__ == '__main__':
    try:
        exercise()
    except Exception as error:
        # 不输出异常请求体或数据库参数，也不输出密码/token。
        print('INVENTORY_ACCEPTANCE_FAILED', type(error).__name__, str(error))
        sys.exit(1)
