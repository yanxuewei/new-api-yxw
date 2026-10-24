# -*- coding: utf-8 -*-
"""仅在验收阶段显式运行；真实HTTPS、临时独立账号、精确清理，兼容Python 3.6。"""
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from decimal import Decimal

SRC = pathlib.Path('/opt/OmniTradeERP/ops/module-repair')
JAVA = '/usr/lib/jvm/java-21-alibaba-dragonwell-21.0.11.0.11.10-1.1.al8.x86_64/bin/java'
BASE = 'https://workflow-erp.likha.hk/api'
MYSQL = 'erp-minimal-mysql'
PREFIX = 'VERIFY-AI-' + uuid.uuid4().hex[:16]
PASSWORD = None
TOKENS = []
CHECKS = 0
SKIPPED = 0
ARMED = False
SCOPES = []
USED_IDS = set()


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def check(condition, label):
    global CHECKS
    require(condition, label)
    CHECKS += 1
    print('PASS', label)


def skip(label):
    global SKIPPED
    SKIPPED += 1
    print('SKIP', label)


def new_id():
    value = secrets.randbelow(2 ** 51 - 1) + 2 ** 51
    while value in USED_IDS:
        value = secrets.randbelow(2 ** 51 - 1) + 2 ** 51
    USED_IDS.add(value)
    return value


USERS = [{'id': new_id(), 'role_link': new_id(), 'name': PREFIX + suffix}
         for suffix in ('-ADMIN-A', '-ADMIN-B', '-USER')]
PRODUCT_ID, WAREHOUSE_ID, INVENTORY_ID = new_id(), new_id(), new_id()
SKUS = [{'id': new_id(), 'code': PREFIX + '-SKU'},
        {'id': new_id(), 'code': PREFIX + '-EMPTY'}]
ORDERS = [{'id': new_id(), 'item': new_id(), 'code': PREFIX + '-O' + str(i)}
          for i in range(7)]
# 异常订单专门覆盖浏览器不安全整数；其余主键保持52位以内。
ORDERS[6]['id'] = secrets.randbelow(2 ** 62 - 2 ** 53) + 2 ** 53 + 1


def run(args, text=None, env=None):
    result = subprocess.run(args, input=text, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True, timeout=90)
    require(result.returncode == 0, '本地工具执行失败，退出码={}'.format(result.returncode))
    return result.stdout


def sql(statement):
    env = os.environ.copy()
    env['MYSQL_PWD'] = PASSWORD
    return run(['docker', 'exec', '-i', '-e', 'MYSQL_PWD', MYSQL, 'mysql', '-uroot',
                '--batch', '--skip-column-names', '--default-character-set=utf8mb4'], statement, env)


def literal(value):
    # 字符集引导的十六进制字面量可随列排序规则比较；CONVERT表达式会与旧表排序规则冲突。
    # 只接收脚本生成的文本，避免引号和SQL模式差异，密码不进命令行。
    return "_utf8mb4 X'{}'".format(value.encode('utf-8').hex())


def ids(values):
    return ','.join(str(int(value)) for value in values)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # 不允许Bearer凭据因重定向发送到其他地址。
        return None


HTTP = urllib.request.build_opener(NoRedirect())


def request(path, method='GET', body=None, token=None, expected=200, label=None):
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, headers=headers, method=method,
                                 data=None if body is None else json.dumps(body).encode('utf-8'))
    try:
        with HTTP.open(req, timeout=60) as response:
            status, raw = response.status, response.read(2 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read(2 * 1024 * 1024 + 1)
    except Exception:
        raise VerificationError('HTTPS请求失败；未输出请求或响应内容')
    name = label or method + ' ' + path.split('?', 1)[0]
    check(status == expected, '{} HTTP={}，预期={}'.format(name, status, expected))
    require(len(raw) <= 2 * 1024 * 1024, '响应超过验收安全上限')
    if status >= 400:
        return None
    try:
        return json.loads(raw.decode('utf-8')) if raw else None
    except (ValueError, UnicodeError):
        raise VerificationError('成功接口未返回有效JSON')


def ai(path, token, method='GET', body=None, expected=200):
    return request('/ai-center' + path, method, body, token, expected)


def table_exists(table):
    schema, name = table.split('.')
    return sql('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema={} AND table_name={};'.format(literal(schema), literal(name))).strip() == '1'


def prepare_scopes():
    user_ids = ids(u['id'] for u in USERS)
    sku_ids = ids(s['id'] for s in SKUS)
    order_ids = ids(o['id'] for o in ORDERS)
    # 子记录先清理。临时user_id/SKU/order_id均在首次写入前确认不存在。
    SCOPES.extend([
        ('erp_inventory.t_ai_message', 'user_id IN ({})'.format(user_ids)),
        ('erp_inventory.t_ai_request', 'user_id IN ({})'.format(user_ids)),
        ('erp_inventory.t_ai_description', 'user_id IN ({})'.format(user_ids)),
        ('erp_inventory.t_ai_session', 'user_id IN ({})'.format(user_ids)),
        ('erp_inventory.t_ai_knowledge', 'created_by IN ({})'.format(user_ids)),
        ('erp_inventory.t_ai_price_history', 'sku_id IN ({})'.format(sku_ids)),
        ('erp_inventory.t_ai_recommend_adoption', 'sku_id IN ({})'.format(sku_ids)),
        ('erp_inventory.t_ai_order_anomaly', 'order_id IN ({})'.format(order_ids)),
    ])
    optional = [
        ('erp_inventory.t_repair_alert_replenishment', 'inventory_id={}'.format(INVENTORY_ID)),
        ('erp_inventory.t_repair_alert_record', 'inventory_id={}'.format(INVENTORY_ID)),
        ('erp_inventory.t_repair_inventory_location', 'inventory_id={}'.format(INVENTORY_ID)),
        ('erp_warehouse.t_repair_warehouse_extra', 'warehouse_id={}'.format(WAREHOUSE_ID)),
        ('erp_user.t_user_department', 'user_id IN ({})'.format(user_ids)),
    ]
    SCOPES.extend((table, where) for table, where in optional if table_exists(table))
    SCOPES.extend([
        ('erp_inventory.t_inventory_log', 'warehouse_id={} AND sku_code={}'.format(WAREHOUSE_ID, literal(SKUS[0]['code']))),
        ('erp_inventory.t_inventory', 'id={}'.format(INVENTORY_ID)),
        ('erp_warehouse.t_warehouse', 'id={}'.format(WAREHOUSE_ID)),
        ('erp_order.t_order_item', 'order_id IN ({})'.format(order_ids)),
        ('erp_order.t_order', 'id IN ({})'.format(order_ids)),
        ('erp_product.t_product_sku', 'id IN ({})'.format(sku_ids)),
        ('erp_product.t_product', 'id={}'.format(PRODUCT_ID)),
        ('erp_user.t_user_role', 'user_id IN ({})'.format(user_ids)),
        ('erp_user.t_user', 'id IN ({})'.format(user_ids)),
    ])


def residuals():
    query = ' UNION ALL '.join('SELECT {},COUNT(*) FROM {} WHERE {}'.format(literal(table), table, where)
                               for table, where in SCOPES)
    result = []
    for line in sql(query + ';').splitlines():
        table, count = line.split('\t')
        result.append((table, int(count)))
    return result


def create_users():
    global ARMED
    prepare_scopes()
    check(all(count == 0 for table, count in residuals()), '写入前所有精确测试范围残留为0')
    check(sql('SELECT COUNT(*) FROM erp_user.t_user WHERE username IN ({});'.format(','.join(literal(u['name']) for u in USERS))).strip() == '0', '临时用户名未占用')
    links = ids(u['role_link'] for u in USERS)
    check(sql('SELECT COUNT(*) FROM erp_user.t_user_role WHERE id IN ({});'.format(links)).strip() == '0', '临时角色关联ID未占用')
    role = sql("SELECT id FROM erp_user.t_role WHERE status=1 AND LOWER(role_code) IN ('admin','super_admin') ORDER BY id LIMIT 1;").strip()
    require(role.isdigit(), '未找到可复用的有效管理员角色')
    statements = ['START TRANSACTION']
    passwords = []
    for index, user in enumerate(USERS):
        password = secrets.token_urlsafe(32)
        passwords.append(password)
        hashed = run([JAVA, '-Xmx64m', '-cp', str(SRC / 'build/classes') + ':' + str(SRC / 'build/lib/*'), 'PasswordHash'], password).strip()
        require(re.match(r'^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$', hashed) is not None, 'PasswordHash未生成有效BCrypt')
        statements.append('INSERT INTO erp_user.t_user(id,username,password,real_name,status) VALUES({},{},{},{},1)'.format(user['id'], literal(user['name']), literal(hashed), literal(PREFIX)))
        if index < 2:
            statements.append('INSERT INTO erp_user.t_user_role(id,user_id,role_id) VALUES({},{},{})'.format(user['role_link'], user['id'], int(role)))
    statements.append('COMMIT')
    # 提前启用finally，覆盖数据库提交成功但客户端响应丢失的情况。
    ARMED = True
    sql(';\n'.join(statements) + ';')
    for user, password in zip(USERS, passwords):
        response = request('/auth/login', 'POST', {'username': user['name'], 'password': password}, label='临时用户真实登录')
        require(isinstance(response, dict) and response.get('code') == 200, '临时用户登录业务状态失败')
        token = response.get('data', {}).get('token')
        require(isinstance(token, str) and bool(token), '登录缺少令牌')
        TOKENS.append(token)
    passwords[:] = []


def initial_checks():
    paths = ['/status', '/knowledge', '/assistant/sessions', '/description/history',
             '/pricing', '/recommend', '/recommend/adopted', '/inventory', '/anomaly', '/anomaly/stats',
             '/pricing/' + SKUS[0]['code'] + '/history', '/inventory/' + SKUS[0]['code'] + '/forecast',
             '/assistant/history/' + str(uuid.uuid4())]
    for path in paths:
        ai(path, None, expected=401)
        ai(path, TOKENS[2], expected=403)
    status = ai('/status', TOKENS[0])
    check(type(status.get('modelConfigured')) is bool, '模型配置状态为真实布尔值')
    print('MODEL_CONFIGURED', str(status['modelConfigured']).lower())
    if status['modelConfigured'] is False:
        check(status.get('model') is None, '未配置模型明确返回false且无虚构模型名')
    for path in ('/assistant/sessions', '/description/history'):
        check(ai(path, TOKENS[0]) == [], '临时管理员个人历史为空 ' + path)
    sources = {
        '/knowledge': 'SELECT COUNT(*) FROM erp_inventory.t_ai_knowledge',
        '/pricing': 'SELECT COUNT(*) FROM erp_product.t_product_sku sk JOIN erp_product.t_product p ON p.id=sk.product_id WHERE sk.deleted=0 AND p.deleted=0',
        '/recommend': 'SELECT COUNT(*) FROM erp_product.t_product_sku sk JOIN erp_product.t_product p ON p.id=sk.product_id WHERE sk.deleted=0 AND p.deleted=0',
        '/inventory': 'SELECT COUNT(*) FROM erp_product.t_product_sku sk JOIN erp_product.t_product p ON p.id=sk.product_id WHERE sk.deleted=0 AND p.deleted=0',
        '/anomaly': 'SELECT COUNT(*) FROM erp_order.t_order WHERE deleted=0',
        '/recommend/adopted': 'SELECT COUNT(*) FROM erp_inventory.t_ai_recommend_adoption',
    }
    for path, query in sources.items():
        count = int(sql(query + ';').strip())
        rows = ai(path, TOKENS[0])
        check(isinstance(rows, list), '管理员列表返回数组 ' + path)
        if count == 0:
            check(rows == [], '真实空库不返回演示数据 ' + path)
        else:
            print('BASELINE_EXISTING', path, count)
    ai('/anomaly/stats', TOKENS[0])


def create_business():
    sku = SKUS[0]['code']
    generated = sql("SELECT EXTRA FROM information_schema.columns WHERE table_schema='erp_inventory' AND table_name='t_inventory' AND column_name='total_qty';").strip()
    inventory_columns = 'id,sku_code,warehouse_id,available_qty,locked_qty,safety_stock'
    inventory_values = '{},{},{},3,0,2'.format(INVENTORY_ID, literal(sku), WAREHOUSE_ID)
    if 'GENERATED' not in generated.upper():
        inventory_columns += ',total_qty'
        inventory_values += ',3'
    statements = ['START TRANSACTION',
        'INSERT INTO erp_product.t_product(id,internal_sku,product_name,status) VALUES({},{},{},1)'.format(PRODUCT_ID, literal(PREFIX), literal(PREFIX)),
        'INSERT INTO erp_warehouse.t_warehouse(id,warehouse_code,warehouse_name,warehouse_type,status) VALUES({},{},{},\'main\',1)'.format(WAREHOUSE_ID, literal(PREFIX), literal(PREFIX)),
        'INSERT INTO erp_inventory.t_inventory({}) VALUES({})'.format(inventory_columns, inventory_values)]
    for index, item in enumerate(SKUS):
        statements.append('INSERT INTO erp_product.t_product_sku(id,product_id,sku_code,sku_name,cost_price,sale_price,status) VALUES({},{},{},{},{},80,1)'.format(item['id'], PRODUCT_ID, literal(item['code']), literal(item['code']), '70' if index == 0 else 'NULL'))
    for index, order in enumerate(ORDERS):
        days = [30, 24, 18, 12, 6, 3, 2][index]
        quantity = 2 if index < 5 else 1000 if index == 5 else 1
        status = ['PAID', 'PAID', 'DELIVERED', 'PAID', 'PAID', 'CANCELLED', 'PENDING'][index]
        payment = ['PAID', 'SUCCESS', 'UNPAID', 'PAID', 'PAID', 'PAID', 'UNPAID'][index]
        amount = quantity * 80 if index < 6 else 0
        date = 'TIMESTAMP(DATE_SUB(CURRENT_DATE(),INTERVAL {} DAY),\'12:00:00\')'.format(days)
        statements.append('INSERT INTO erp_order.t_order(id,platform,shop_id,platform_order_no,internal_order_no,order_amount,product_amount,currency_code,status,payment_status,payment_time,create_time) VALUES({},{},{},{},{},{},{},\'USD\',{},{},{},{})'.format(order['id'], literal(PREFIX), literal(PREFIX), literal(order['code']), literal(order['code']), amount, amount, literal(status), literal(payment), date if index <= 5 else 'NULL', date))
        statements.append('INSERT INTO erp_order.t_order_item(id,order_id,internal_sku,product_name,unit_price,quantity,total_amount,currency_code,create_time) VALUES({},{},{},{},80,{},{},\'USD\',{})'.format(order['item'], order['id'], literal(sku), literal(PREFIX), quantity, quantity * 80, date))
    statements.append('COMMIT')
    sql(';\n'.join(statements) + ';')
    check(sql('SELECT available_qty+locked_qty=total_qty FROM erp_inventory.t_inventory WHERE id={};'.format(INVENTORY_ID)).strip() == '1', '测试库存总量约束成立')


def find_row(path, key, value):
    # 列表可能已有真实数据，分页定位本次记录，不依赖全库为空。
    for offset in range(0, 100001, 500):
        rows = ai(path + ('&' if '?' in path else '?') + 'limit=500&offset=' + str(offset), TOKENS[0])
        require(isinstance(rows, list), '业务列表结构错误')
        matches = [row for row in rows if str(row.get(key)) == str(value)]
        if matches:
            require(len(matches) == 1, '测试记录重复')
            return matches[0]
        if len(rows) < 500:
            break
    raise VerificationError('未从真实接口回读到测试记录')


def analysis_checks():
    token, sku = TOKENS[0], SKUS[0]['code']
    row = find_row('/pricing', 'sku', sku)
    check(Decimal(str(row['suggestedPrice'])) == Decimal('100') and row['dataStatus'] == 'AVAILABLE', '成本70的建议价为100')
    check(find_row('/pricing', 'sku', SKUS[1]['code'])['suggestedPrice'] is None, '缺失成本不编造建议价')
    applied = ai('/pricing/' + sku + '/apply', token, 'POST', {'price': '100.00', 'expectedPrice': '80.00'})
    check(applied['changed'] is True, '定价采纳真实变更')
    check(Decimal(str(find_row('/pricing', 'sku', sku)['currentPrice'])) == Decimal('100'), '采纳后HTTP回读价格100')
    check(Decimal(sql('SELECT sale_price FROM erp_product.t_product_sku WHERE id={};'.format(SKUS[0]['id'])).strip()) == Decimal('100'), '采纳后数据库真实价格100')
    history = ai('/pricing/' + sku + '/history', token)
    check(len(history) == 1 and Decimal(str(history[0]['previousPrice'])) == Decimal('80') and Decimal(str(history[0]['newPrice'])) == Decimal('100'), '调价历史真实保存一次')
    ai('/pricing/' + sku + '/apply', token, 'POST', {'price': '110.00', 'expectedPrice': '80.00'}, 409)
    unchanged = ai('/pricing/' + sku + '/apply', token, 'POST', {'price': '100.00', 'expectedPrice': '100.00'})
    check(unchanged['changed'] is False and len(ai('/pricing/' + sku + '/history', token)) == 1, '相同价格幂等且冲突未写历史')
    recommendation = find_row('/recommend', 'sku', sku)
    check(Decimal(str(recommendation['sales90d'])) == Decimal('10'), '销量10含SUCCESS和DELIVERED且取消订单1000件被排除')
    check(Decimal(str(recommendation['score'])) == Decimal('18'), '选品评分按真实销量和毛利确定性计算')
    before = find_row('/recommend', 'sku', sku)
    check(before == find_row('/recommend', 'sku', sku), '推荐结果重复查询确定性一致')
    ai('/recommend/refresh?limit=500', token, 'POST')
    for unused in range(2):
        check(ai('/recommend/' + sku + '/adopt', token, 'POST')['adopted'] is True, '推荐采纳返回成功')
    check(sql('SELECT COUNT(*) FROM erp_inventory.t_ai_recommend_adoption WHERE sku_id={};'.format(SKUS[0]['id'])).strip() == '1', '重复推荐采纳只保留一条')
    check(find_row('/recommend', 'sku', sku)['adopted'] is True, '推荐采纳状态回读')
    check(find_row('/recommend/adopted', 'sku', sku)['sku'] == sku, '推荐采纳历史回读')
    forecast = ai('/inventory/' + sku + '/forecast', token)
    check(forecast == ai('/inventory/' + sku + '/forecast', token), '库存预测重复查询确定性一致')
    expected = {'sales90d': '10', 'salesDays': '5', 'observationDays': '31', 'availableStock': '3', 'safetyStock': '2', 'dailySales': '0.32258065', 'predictedDemand': '9.68', 'replenishmentQty': '9', 'stockoutDays': '9.3'}
    for field, value in expected.items():
        check(Decimal(str(forecast[field])) == Decimal(value), '库存确定值 ' + field)
    check(forecast['dataStatus'] == 'AVAILABLE' and len(forecast['forecast']) == 30, '足够数据生成未来30日预测')
    check(all(Decimal(str(point['demand'])) == Decimal('0.32258065') for point in forecast['forecast']), '预测每日使用同一确定性均值')
    check(forecast['pendingPurchaseQty'] is None and forecast['pendingPurchaseDeducted'] is False, '未接入采购不虚构在途量')
    insufficient = ai('/inventory/' + SKUS[1]['code'] + '/forecast', token)
    check(insufficient['dataStatus'] == 'INSUFFICIENT_DATA' and all(insufficient[field] is None for field in ('dailySales', 'predictedDemand', 'replenishmentQty', 'stockoutDays')), '不足销售数据使用null而非演示预测')
    check(all(point['demand'] is None for point in insufficient['forecast']), '不足数据未来30日均为null')
    # 暂时移除并恢复仅本次库存夹具，验证有销量但未登记库存不能推断为零。
    sql('DELETE FROM erp_inventory.t_inventory WHERE id={} AND sku_code={} AND warehouse_id={};'.format(INVENTORY_ID, literal(sku), WAREHOUSE_ID))
    try:
        unknown_stock = ai('/inventory/' + sku + '/forecast', token)
        check(unknown_stock['inventoryRecordExists'] is False and unknown_stock['availableStock'] is None and unknown_stock['replenishmentQty'] is None and unknown_stock['stockoutDays'] is None, '有足够销量但未登记库存不能虚构补货或缺货天数')
    finally:
        generated = sql("SELECT EXTRA FROM information_schema.columns WHERE table_schema='erp_inventory' AND table_name='t_inventory' AND column_name='total_qty';").strip()
        columns = 'id,sku_code,warehouse_id,available_qty,locked_qty,safety_stock'
        values = '{},{},{},3,0,2'.format(INVENTORY_ID, literal(sku), WAREHOUSE_ID)
        if 'GENERATED' not in generated.upper():
            columns += ',total_qty'
            values += ',3'
        sql('INSERT INTO erp_inventory.t_inventory({}) VALUES({});'.format(columns, values))


def anomaly_checks():
    token, order = TOKENS[0], ORDERS[6]
    path = '/anomaly/' + str(order['id']) + '/confirm'
    initial = find_row('/anomaly', 'id', order['id'])
    check(initial['anomalous'] is True and initial['confirmationStatus'] == 'PENDING', '专用异常订单初始待确认')
    check(isinstance(initial['id'], str) and initial['id'] == str(order['id']) and initial['orderNo'] == order['code'], '超过2^53订单ID按字符串无损返回且单号精确匹配')
    rule = initial['ruleKey']
    # 先只读验证已部署精确范围契约，避免旧版忽略参数后全库写入。
    scoped = ai('/anomaly?orderId=' + str(order['id']), token)
    check(isinstance(scoped, list) and len(scoped) == 1 and int(scoped[0]['id']) == order['id'], '精确orderId范围契约已部署')
    query = '/anomaly/detect?orderId=' + str(order['id'])
    detected = ai(query, token, 'POST')
    check(detected['scanned'] == 1 and detected['scope'] == 'SINGLE_ORDER' and detected['orderId'] == str(order['id']) and len(detected['results']) == 1 and detected['results'][0]['id'] == str(order['id']), '异常检测只扫描精确测试订单')
    ai(path, token, 'POST', {'status': 'INVALID', 'expectedStatus': 'PENDING', 'expectedRuleKey': rule}, 400)
    ai(path, token, 'POST', {'status': 'CONFIRMED', 'expectedStatus': 'PENDING', 'expectedRuleKey': rule + '-STALE'}, 409)
    confirmed = ai(path, token, 'POST', {'status': 'CONFIRMED', 'expectedStatus': 'PENDING', 'expectedRuleKey': rule})
    check(confirmed['confirmationStatus'] == 'CONFIRMED' and confirmed['id'] == str(order['id']) and confirmed['orderNo'] == order['code'], '超过2^53订单精确人工确认成功')
    ai(path, token, 'POST', {'status': 'REJECTED', 'expectedStatus': 'PENDING', 'expectedRuleKey': rule}, 409)
    again = ai(query, token, 'POST')
    check(again['results'][0]['confirmationStatus'] == 'CONFIRMED', '重复检测保留人工确认')
    check(find_row('/anomaly', 'id', order['id'])['confirmationStatus'] == 'CONFIRMED', '异常确认状态回读')
    normal = ai('/anomaly?orderId=' + str(ORDERS[0]['id']), token)[0]
    ai('/anomaly/' + str(ORDERS[0]['id']) + '/confirm', token, 'POST', {'status': 'CONFIRMED', 'expectedStatus': 'PENDING', 'expectedRuleKey': normal['ruleKey']}, 400)
    ai('/anomaly/stats', token)


def models_disabled():
    configured = ai('/status', TOKENS[0])['modelConfigured']
    require(type(configured) is bool, '模型配置字段非法')
    return not configured


def language_checks():
    token = TOKENS[0]
    keyword = 'verificationkeyword' + uuid.uuid4().hex
    original = keyword + ' exact verification source text.'
    knowledge = ai('/knowledge', token, 'POST', {'title': PREFIX, 'content': original})
    kid = knowledge['id']
    rows = ai('/knowledge', token)
    check(any(row['id'] == kid and row['content'] == original for row in rows), '知识创建后真实回读原文')
    if not models_disabled():
        skip('模型已配置：禁止收费调用，跳过所有chat、知识回复、幂等与描述生成测试')
    else:
        body = {'message': keyword, 'requestId': str(uuid.uuid4())}
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        chat = ai('/assistant/chat', token, 'POST', body)
        check(chat['mode'] == 'KNOWLEDGE' and original in chat['reply'], '无模型知识命中返回KNOWLEDGE原文')
        check(any(row['id'] == kid and row['content'] == original for row in chat['sources']), '知识引用来自本次真实条目')
        sid = chat['sessionId']
        check(str(uuid.UUID(sid)) == sid, '真实会话ID为标准UUID')
        check(any(row['sessionId'] == sid for row in ai('/assistant/sessions', token)), '会话列表真实保存')
        history = ai('/assistant/history/' + sid, token)
        check(len(history) == 2 and [row['role'] for row in history] == ['user', 'assistant'], '会话历史包含一问一答')
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        replay = ai('/assistant/chat', token, 'POST', body)
        check(chat == replay and ai('/assistant/history/' + sid, token) == history, 'requestId重放完全幂等且不重复历史')
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        ai('/assistant/chat', token, 'POST', {'message': keyword + ' changed', 'requestId': body['requestId']}, 409)
        ai('/assistant/history/' + sid, TOKENS[1], expected=404)
        check(ai('/assistant/sessions', TOKENS[1]) == [], '第二管理员会话列表隔离')
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        ai('/assistant/chat', token, 'POST', {'sessionId': str(uuid.uuid4()), 'message': keyword, 'requestId': str(uuid.uuid4())}, 404)
        missing = {'message': 'unmatchedverification' + uuid.uuid4().hex, 'requestId': str(uuid.uuid4())}
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        ai('/assistant/chat', token, 'POST', missing, 503)
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        ai('/assistant/chat', token, 'POST', missing, 503)
        require(models_disabled(), '模型配置发生改变，拒绝调用')
        ai('/description/generate', token, 'POST', {'sku': SKUS[0]['code'], 'language': 'en', 'tone': 'neutral', 'keywords': [], 'requestId': str(uuid.uuid4())}, 503)
        check(ai('/description/history', token) == [], '缺模型不产生伪造描述历史')
    deleted = ai('/knowledge/' + str(kid), token, 'DELETE')
    check(deleted['deleted'] is True and not any(row['id'] == kid for row in ai('/knowledge', token)), '知识删除后回读不存在')


def description_save_checks():
    # 仅验证保存链路：显式人工测试文案，不是模型生成结果或真实商品声明。
    print('DESCRIPTION_SAVE_SCOPE', '仅测试人工夹具保存路径，不代表模型生成已验收')
    token = TOKENS[0]
    descriptions = []
    for language in ('zh', 'en', 'ja', 'es', 'zh'):
        did = new_id()
        text = PREFIX + '-SAVE-ONLY-' + language + '-' + str(did)
        descriptions.append({'id': did, 'language': language, 'description': text})
    check(sql('SELECT COUNT(*) FROM erp_inventory.t_ai_description WHERE id IN ({});'.format(ids(row['id'] for row in descriptions))).strip() == '0', '保存链路测试文案ID未占用')
    statements = ['START TRANSACTION']
    for row in descriptions:
        statements.append('INSERT INTO erp_inventory.t_ai_description(id,user_id,product_id,sku,language,description,model,original_description) VALUES({},{},{},{},{},{},{},NULL)'.format(row['id'], USERS[0]['id'], PRODUCT_ID, literal(SKUS[0]['code']), literal(row['language']), literal(row['description']), literal(PREFIX + '-NO-MODEL-FIXTURE')))
    statements.append('COMMIT')
    sql(';\n'.join(statements) + ';')
    own_ids = set(row['id'] for row in descriptions)
    check(own_ids.issubset(set(row['id'] for row in ai('/description/history', token))), '人工保存夹具历史可回读')
    check(not own_ids.intersection(set(row['id'] for row in ai('/description/history', TOKENS[1]))), '第二管理员无法读取他人文案历史')
    ai('/description/' + str(descriptions[0]['id']) + '/save', TOKENS[1], 'POST', expected=404)
    for row in descriptions[:4]:
        path = '/description/' + str(row['id']) + '/save'
        saved = ai(path, token, 'POST')
        updates_product = row['language'] in ('zh', 'en')
        check(saved['saved'] is True and saved['productUpdated'] is updates_product, '文案保存语义正确 ' + row['language'])
        check(ai(path, token, 'POST') == saved, '重复文案保存幂等 ' + row['language'])
        if updates_product:
            column = 'description' if row['language'] == 'zh' else 'description_en'
            check(sql('SELECT {}={} FROM erp_product.t_product WHERE id={};'.format(column, literal(row['description']), PRODUCT_ID)).strip() == '1', '商品对应语言真实写回 ' + row['language'])
    check(sql('SELECT description={} AND description_en={} FROM erp_product.t_product WHERE id={};'.format(literal(descriptions[0]['description']), literal(descriptions[1]['description']), PRODUCT_ID)).strip() == '1', '日语西语仅保存文案库未覆盖商品中英文')
    stale = descriptions[4]
    ai('/description/' + str(stale['id']) + '/save', token, 'POST', expected=409)
    histories = ai('/description/history', token)
    check(any(row['id'] == stale['id'] and row['saved'] is False for row in histories), '原描述过期冲突未误标保存成功')


def container_snapshot(stage):
    names = run(['docker', 'ps', '-a', '--format', '{{.Names}}']).splitlines()
    names = sorted(name for name in names if re.match(r'^erp-minimal-[a-z0-9-]+$', name))
    require(MYSQL in names and 'erp-minimal-warehouse-service' in names, '缺少验收必需容器')
    snapshot = {}
    for name in names:
        info = json.loads(run(['docker', 'inspect', name]))[0]
        state = info['State']
        row = {'running': bool(state['Running']), 'health': state.get('Health', {}).get('Status', 'not-configured'), 'restart': info['RestartCount'], 'oom': bool(state.get('OOMKilled')), 'memoryLimitBytes': info['HostConfig'].get('Memory', 0), 'nanoCpus': info['HostConfig'].get('NanoCpus', 0)}
        snapshot[name] = row
        print('CONTAINER', stage, name, json.dumps(row, sort_keys=True))
        check(row['running'] and not row['oom'] and row['health'] in ('healthy', 'not-configured'), '容器运行健康且未OOM ' + name)
    raw = run(['docker', 'stats', '--no-stream', '--format', '{{json .}}'] + names)
    for line in raw.splitlines():
        row = json.loads(line)
        print('RESOURCE', stage, json.dumps({key: row.get(key) for key in ('Name', 'CPUPerc', 'MemUsage', 'MemPerc', 'PIDs')}, sort_keys=True))
    return snapshot


def cleanup():
    failures = []
    for token in TOKENS:
        try:
            result = request('/auth/logout', 'POST', token=token, label='临时用户真实注销')
            require(isinstance(result, dict) and result.get('code') == 200, '注销业务状态失败')
            ai('/status', token, expected=401)
        except Exception:
            failures.append('临时令牌注销或失效核对失败')
    if ARMED:
        try:
            statements = ['START TRANSACTION']
            statements.extend('DELETE FROM {} WHERE {}'.format(table, where) for table, where in SCOPES)
            statements.append('COMMIT')
            sql(';\n'.join(statements) + ';')
            remaining = residuals()
            for table, count in remaining:
                print('CLEANUP', table, 'remaining=' + str(count))
            check(all(count == 0 for table, count in remaining), '全部临时用户业务记录及AI关联精确残留为0')
            print('AI_CLEANUP_OK', PREFIX)
        except Exception:
            failures.append('精确测试记录清理失败，须按VERIFY_PREFIX人工核对')
    TOKENS[:] = []
    require(not failures, '；'.join(failures))


def exercise():
    global PASSWORD
    print('VERIFY_PREFIX', PREFIX)
    info = json.loads(run(['docker', 'inspect', MYSQL]))[0]
    PASSWORD = next(value.split('=', 1)[1] for value in info['Config']['Env'] if value.startswith('MYSQL_ROOT_PASSWORD='))
    before = None
    try:
        before = container_snapshot('BEFORE')
        print('BASELINE_USER_COUNT', int(sql('SELECT COUNT(*) FROM erp_user.t_user;').strip()))
        create_users()
        initial_checks()
        create_business()
        analysis_checks()
        anomaly_checks()
        language_checks()
        description_save_checks()
    finally:
        try:
            cleanup()
        finally:
            PASSWORD = None
            after = container_snapshot('AFTER')
            if before is not None:
                check(set(before) == set(after), '验收期间容器集合未变化')
                check(all(after[name]['restart'] == before[name]['restart'] for name in before), '验收期间容器没有新增重启')
    print('AI_ACCEPTANCE_OK checks={} skipped={}'.format(CHECKS, SKIPPED))


if __name__ == '__main__':
    try:
        exercise()
    except BaseException as error:
        # 仅打印脚本自定义安全错误，外部异常可能含响应、SQL、凭据或个人数据。
        message = str(error) if isinstance(error, VerificationError) else '外部工具或数据格式异常，敏感详情已隐藏'
        print('AI_ACCEPTANCE_FAILED', type(error).__name__, message)
        print('AI_ACCEPTANCE_SUMMARY checks={} skipped={}'.format(CHECKS, SKIPPED))
        sys.exit(1)
