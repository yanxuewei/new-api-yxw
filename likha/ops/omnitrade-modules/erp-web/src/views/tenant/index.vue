<template>
  <div class="tenant-page">
    <el-tabs v-model="tab">
      <!-- 租户列表 -->
      <el-tab-pane label="租户管理" name="list">
        <el-card shadow="never">
          <template #header>
            <div class="card-head">
              <span>租户列表（{{ list.length }}）</span>
              <el-button type="primary" @click="newTenant">新建租户</el-button>
            </div>
          </template>
          <el-table :data="list" v-loading="loading" stripe>
            <el-table-column prop="code"     label="租户编码"  width="120" />
            <el-table-column prop="name"     label="租户名称" />
            <el-table-column prop="plan"     label="套餐"      width="120">
              <template #default="{ row }">
                <el-tag size="small" :type="row.plan === 'ENTERPRISE' ? 'danger' : (row.plan === 'PRO' ? 'warning' : '')">
                  {{ row.plan }}
                </el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="contact"  label="联系人"    width="120" />
            <el-table-column prop="phone"    label="手机"      width="140" />
            <el-table-column prop="status"   label="状态"      width="100">
              <template #default="{ row }">
                <el-tag :type="row.status === 'ACTIVE' ? 'success' : 'info'" size="small">{{ row.status }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="expireAt" label="到期时间"  width="180" />
            <el-table-column label="操作" width="220" fixed="right">
              <template #default="{ row }">
                <el-button link type="primary" size="small" @click="goDashboard(row)">看板</el-button>
                <el-button link type="primary" size="small" @click="goBilling(row)">账单</el-button>
                <el-button link type="warning" size="small" @click="goConfig(row)">配置</el-button>
                <el-button link type="danger" size="small" @click="remove(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
        </el-card>
      </el-tab-pane>

      <!-- 套餐说明 -->
      <el-tab-pane label="套餐" name="plans">
        <el-row :gutter="16">
          <el-col :span="8" v-for="p in plans" :key="p.code">
            <el-card shadow="hover" class="plan-card">
              <h3>{{ p.name }}</h3>
              <div class="plan-price">¥ {{ p.price }}<span> / 月</span></div>
              <ul class="plan-features">
                <li v-for="f in p.features" :key="f">✓ {{ f }}</li>
              </ul>
              <el-button type="primary" plain class="plan-btn" @click="onPlanSelected(p.code)">选择</el-button>
            </el-card>
          </el-col>
        </el-row>
      </el-tab-pane>
    </el-tabs>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { tenantApi } from '@/api/tenant'

const tab = ref('list')
const list = ref<any[]>([])
const loading = ref(false)

const plans = [
  {
    code: 'FREE', name: '免费版', price: 0,
    features: ['1 个店铺', '基础订单/商品管理', '社区支持', '1000 单/月'],
  },
  {
    code: 'PRO', name: '专业版', price: 999,
    features: ['10 个店铺', '完整 ERP + 智能定价', '邮件支持', '10 万单/月', 'AI 智能客服'],
  },
  {
    code: 'ENTERPRISE', name: '企业版', price: 4999,
    features: ['不限店铺', '全模块 + 定制开发', '7×24 专属客服', '不限单量', '私有部署支持'],
  },
]

onMounted(load)

async function load() {
  loading.value = true
  try {
    list.value = await tenantApi.list()
  } catch {
    list.value = [
      { id: 1, code: 'T00001', name: '深圳跨境电商有限公司',    plan: 'ENTERPRISE', contact: '李总',   phone: '13800138001', status: 'ACTIVE', expireAt: '2027-06-30 23:59' },
      { id: 2, code: 'T00002', name: 'ShopSmart Global',         plan: 'PRO',       contact: 'John',   phone: '+1-213-555-0100', status: 'ACTIVE', expireAt: '2027-03-31 23:59' },
      { id: 3, code: 'T00003', name: '广州南沙出口商',          plan: 'PRO',       contact: '王经理', phone: '13900139002',     status: 'ACTIVE', expireAt: '2026-09-30 23:59' },
      { id: 4, code: 'T00004', name: '杭州独立站工作室',         plan: 'FREE',      contact: '小陈',   phone: '13700137004',     status: 'ACTIVE', expireAt: '永久' },
      { id: 5, code: 'T00005', name: '厦门物流贸易公司',         plan: 'ENTERPRISE', contact: '林总',  phone: '13600136005',     status: 'EXPIRED', expireAt: '2026-04-30 23:59' },
    ]
  } finally { loading.value = false }
}

function newTenant() { ElMessage.info('新建租户 dialog（demo）') }
function goDashboard(row: any)   { ElMessage.success(`打开 ${row.name} 看板`) }
function goBilling(row: any)     { ElMessage.success(`打开 ${row.name} 账单`) }
function goConfig(row: any)      { ElMessage.success(`打开 ${row.name} 配置`) }
function onPlanSelected(code: string) { ElMessage.success(`已选择套餐：${code}`) }

async function remove(row: any) {
  await ElMessageBox.confirm(`确认删除租户 ${row.name}？`, '提示', { type: 'warning' })
  list.value = list.value.filter(r => r.id !== row.id)
  ElMessage.success('已删除')
}
</script>

<style scoped>
.tenant-page { padding: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
.plan-card { text-align: center; padding: 16px; }
.plan-card h3 { margin-top: 0; }
.plan-price { font-size: 28px; color: #f56c6c; font-weight: 600; margin: 12px 0; }
.plan-price span { font-size: 14px; color: #999; font-weight: normal; }
.plan-features { text-align: left; list-style: none; padding: 0; color: #666; }
.plan-features li { padding: 4px 0; }
.plan-btn { width: 100%; margin-top: 12px; }
</style>
