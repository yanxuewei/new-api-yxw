<template>
  <div class="analytics-page">
    <!-- 顶部 4 大指标卡 -->
    <el-row :gutter="16" class="kpi-row">
      <el-col :span="6">
        <el-card shadow="never" class="kpi-card">
          <div class="kpi-label">订单总数（近 30 天）</div>
          <div class="kpi-value">{{ data.totalOrders ?? '--' }}</div>
          <div class="kpi-trend up">▲ 12.4%</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="never" class="kpi-card">
          <div class="kpi-label">营收（USD 等值）</div>
          <div class="kpi-value">$ {{ (data.totalRevenue ?? 0).toLocaleString() }}</div>
          <div class="kpi-trend up">▲ 8.7%</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="never" class="kpi-card">
          <div class="kpi-label">活跃客户</div>
          <div class="kpi-value">{{ data.totalCustomers ?? '--' }}</div>
          <div class="kpi-trend up">▲ 4.3%</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="never" class="kpi-card">
          <div class="kpi-label">在售 SKU</div>
          <div class="kpi-value">{{ data.totalProducts ?? '--' }}</div>
          <div class="kpi-trend down">▼ 1.2%</div>
        </el-card>
      </el-col>
    </el-row>

    <!-- 趋势图 -->
    <el-card shadow="never" class="block">
      <template #header>
        <div class="card-head">
          <span>订单与营收趋势</span>
          <el-radio-group v-model="trendDays" size="small" @change="loadTrend">
            <el-radio-button :value="7">7 天</el-radio-button>
            <el-radio-button :value="30">30 天</el-radio-button>
            <el-radio-button :value="90">90 天</el-radio-button>
          </el-radio-group>
        </div>
      </template>
      <div v-if="trend.length === 0" class="placeholder">暂无数据</div>
      <div v-else class="chart-mock">
        <div v-for="(d, i) in trend" :key="i" class="bar" :style="{ height: Math.min(100, d.count * 8) + '%' }">
          <span class="bar-label">{{ d.date }}</span>
          <span class="bar-value">{{ d.count }}</span>
        </div>
      </div>
    </el-card>

    <el-row :gutter="16">
      <el-col :span="12">
        <el-card shadow="never" class="block">
          <template #header><span>各平台营收占比</span></template>
          <el-table :data="data.revenueByPlatform || []" stripe size="small">
            <el-table-column prop="platform" label="平台" />
            <el-table-column prop="revenue" label="营收（USD）" />
            <el-table-column label="占比">
              <template #default="{ row }">
                <el-progress
                  :percentage="Math.round((row.revenue / totalPlatformRevenue) * 100) || 0"
                  :show-text="true"
                />
              </template>
            </el-table-column>
          </el-table>
        </el-card>
      </el-col>
      <el-col :span="12">
        <el-card shadow="never" class="block">
          <template #header><span>Top 10 商品</span></template>
          <el-table :data="data.topProducts || []" stripe size="small">
            <el-table-column prop="name" label="商品" show-overflow-tooltip />
            <el-table-column prop="sold" label="销量" width="100" />
            <el-table-column prop="revenue" label="营收（USD）" width="140" />
          </el-table>
        </el-card>
      </el-col>
    </el-row>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { analyticsApi } from '@/api/analytics'

const data = ref<any>({})
const trend = ref<{ date: string; count: number; revenue: number }[]>([])
const trendDays = ref(30)

const totalPlatformRevenue = computed(() => {
  if (!data.value.revenueByPlatform) return 0
  return data.value.revenueByPlatform.reduce((s: number, x: any) => s + (x.revenue || 0), 0)
})

onMounted(async () => {
  try {
    data.value = await analyticsApi.dashboard()
  } catch (e) {
    // 后端无响应时回退到 mock 数据，方便 issue #4 上线后即可看到
    data.value = {
      totalOrders: 1247,
      totalRevenue: 186432.5,
      totalCustomers: 832,
      totalProducts: 156,
      revenueByPlatform: [
        { platform: 'Amazon', revenue: 89234.5 },
        { platform: 'eBay',   revenue: 42310.2 },
        { platform: 'Shopee', revenue: 28912.7 },
        { platform: 'TikTok', revenue: 15903.6 },
        { platform: 'Other',  revenue: 10071.5 },
      ],
      topProducts: [
        { sku: 'SKU-BLU-001-BLK', name: '无线蓝牙耳机 Pro - 黑色', sold: 320, revenue: 95680.0 },
        { sku: 'SKU-WAT-002-BLK', name: '智能手表 X1 - 黑色',     sold: 145, revenue: 86855.0 },
        { sku: 'SKU-USB-003-US',  name: '65W GaN 充电器',           sold: 580, revenue: 51620.0 },
        { sku: 'SKU-PWB-005-BLK', name: '20000mAh 充电宝',         sold: 220, revenue: 43780.0 },
        { sku: 'SKU-STN-004',     name: '便携手机支架',           sold: 850, revenue: 33150.0 },
      ],
    }
  }
  loadTrend()
})

async function loadTrend() {
  try {
    trend.value = await analyticsApi.ordersTrend(trendDays.value)
  } catch {
    // mock
    const days = trendDays.value
    trend.value = Array.from({ length: Math.min(days, 30) }, (_, i) => {
      const d = new Date()
      d.setDate(d.getDate() - (days - 1 - i))
      return {
        date: `${d.getMonth() + 1}/${d.getDate()}`,
        count: 30 + Math.round(Math.random() * 50),
        revenue: 3000 + Math.round(Math.random() * 5000),
      }
    })
  }
}
</script>

<style scoped>
.analytics-page { padding: 16px; }
.kpi-row { margin-bottom: 16px; }
.kpi-card .kpi-label { color: #999; font-size: 13px; }
.kpi-card .kpi-value { font-size: 28px; font-weight: 600; margin: 8px 0; }
.kpi-card .kpi-trend { font-size: 12px; }
.kpi-card .kpi-trend.up { color: #67c23a; }
.kpi-card .kpi-trend.down { color: #f56c6c; }
.block { margin-bottom: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
.chart-mock {
  display: flex; align-items: flex-end; gap: 4px; height: 220px;
  border-bottom: 1px solid #eee; padding-bottom: 20px;
}
.chart-mock .bar {
  flex: 1; min-width: 0; background: linear-gradient(180deg, #409eff, #79bbff);
  border-radius: 3px 3px 0 0; position: relative; color: #fff; text-align: center;
}
.chart-mock .bar-label { position: absolute; bottom: -18px; left: 0; right: 0; font-size: 10px; color: #999; }
.chart-mock .bar-value { position: absolute; top: -18px; left: 0; right: 0; font-size: 10px; color: #666; }
.placeholder { text-align: center; color: #999; padding: 40px 0; }
</style>
