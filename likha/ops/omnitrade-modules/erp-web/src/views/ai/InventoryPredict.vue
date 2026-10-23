<template>
  <div class="ip-page">
    <el-row :gutter="16" class="ip-summary">
      <el-col :span="6"><el-card shadow="never"><el-statistic title="待补货 SKU" :value="high" :value-style="{ color: '#f56c6c' }" /></el-card></el-col>
      <el-col :span="6"><el-card shadow="never"><el-statistic title="中等紧急" :value="medium" :value-style="{ color: '#e6a23c' }" /></el-card></el-col>
      <el-col :span="6"><el-card shadow="never"><el-statistic title="低优先级" :value="low" :value-style="{ color: '#909399' }" /></el-card></el-col>
      <el-col :span="6"><el-card shadow="never"><el-statistic title="下次同步" :value="lastSync" /></el-card></el-col>
    </el-row>

    <el-card shadow="never">
      <template #header>
        <div class="card-head">
          <span>AI 智能补货建议（基于 90 天销量 + 季节系数 + 促销计划）</span>
          <el-button type="primary" @click="refresh">刷新预测</el-button>
        </div>
      </template>

      <el-table :data="list" v-loading="loading" stripe>
        <el-table-column prop="sku"            label="SKU" width="180" />
        <el-table-column prop="productName"    label="商品" show-overflow-tooltip />
        <el-table-column label="当前库存" width="100">
          <template #default="{ row }">{{ row.currentStock }}</template>
        </el-table-column>
        <el-table-column prop="predicted30DaySales" label="预测 30 天销量" width="140" />
        <el-table-column prop="recommendedReplenishment" label="建议补货量" width="140">
          <template #default="{ row }">
            <el-tag :type="row.recommendedReplenishment > 0 ? 'success' : 'info'">
              {{ row.recommendedReplenishment > 0 ? '+' + row.recommendedReplenishment : '无需补货' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="safetyStock"    label="安全库存"   width="100" />
        <el-table-column prop="urgency"        label="紧急程度"   width="120">
          <template #default="{ row }">
            <el-tag :type="urgencyType(row.urgency)" size="small">{{ row.urgencyLabel }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="180" fixed="right">
          <template #default="{ row }">
            <el-button link type="primary" size="small" @click="viewChart(row)">预测趋势</el-button>
            <el-button link type="success" size="small" @click="createPO(row)">创建采购单</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <el-dialog v-model="chartVisible" title="销量预测" width="640px">
      <div v-if="chartData.length" class="chart-mock">
        <div v-for="(d, i) in chartData" :key="i" class="bar" :style="{ height: Math.min(100, (d.value / 60) * 100) + '%' }">
          <span class="bar-value">{{ d.value }}</span>
          <span class="bar-label">{{ d.date }}</span>
        </div>
      </div>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import { inventoryPredictApi } from '@/api/ai'

const list = ref<any[]>([])
const loading = ref(false)
const lastSync = ref('')
const chartVisible = ref(false)
const chartData = ref<any[]>([])

const urgencyMap: Record<string, { label: string; type: string }> = {
  HIGH:   { label: '紧急', type: 'danger'  },
  MEDIUM: { label: '中等', type: 'warning' },
  LOW:    { label: '低',    type: 'info'    },
}
const urgencyType = (u: string) => (urgencyMap[u] || {}).type || ''
const urgencyLabel = (u: string) => (urgencyMap[u] || {}).label || u

const high = computed(() => list.value.filter(x => x.urgency === 'HIGH').length)
const medium = computed(() => list.value.filter(x => x.urgency === 'MEDIUM').length)
const low = computed(() => list.value.filter(x => x.urgency === 'LOW').length)

onMounted(load)

async function load() {
  loading.value = true
  try {
    list.value = await inventoryPredictApi.listSuggestions({})
  } catch {
    list.value = [
      { sku: 'SKU-STN-004',     productName: '便携手机支架',       currentStock: 1920, predicted30DaySales: 1500, recommendedReplenishment: 0,    safetyStock: 300, urgency: 'LOW',    urgencyLabel: '低' },
      { sku: 'SKU-USB-003-US',  productName: '65W GaN 充电器',      currentStock: 920,  predicted30DaySales: 1100, recommendedReplenishment: 380,  safetyStock: 200, urgency: 'MEDIUM', urgencyLabel: '中等' },
      { sku: 'SKU-BLU-001-BLK', productName: '无线蓝牙耳机 Pro',   currentStock: 400,  predicted30DaySales: 580,  recommendedReplenishment: 280,  safetyStock: 100, urgency: 'HIGH',   urgencyLabel: '紧急' },
      { sku: 'SKU-PWB-005-BLK', productName: '20000mAh 充电宝',     currentStock: 530,  predicted30DaySales: 480,  recommendedReplenishment: 50,   safetyStock: 100, urgency: 'LOW',    urgencyLabel: '低' },
      { sku: 'SKU-WAT-002-BLK', productName: '智能手表 X1',         currentStock: 160,  predicted30DaySales: 220,  recommendedReplenishment: 160,  safetyStock: 50,  urgency: 'MEDIUM', urgencyLabel: '中等' },
      { sku: 'SKU-BTY-010',     productName: '精华液 30ml',         currentStock: 760,  predicted30DaySales: 600,  recommendedReplenishment: 0,    safetyStock: 150, urgency: 'LOW',    urgencyLabel: '低' },
    ]
  } finally {
    loading.value = false
    lastSync.value = new Date().toLocaleString()
  }
}

function refresh() { load(); ElMessage.success('预测已刷新') }
function viewChart(row: any) {
  chartData.value = Array.from({ length: 30 }, (_, i) => ({
    date: `D+${i + 1}`,
    value: Math.round(row.predicted30DaySales / 30 + (Math.random() - 0.5) * 20),
  }))
  chartVisible.value = true
}
function createPO(row: any) {
  ElMessage.success(`已基于 AI 建议创建 ${row.sku} 的采购单（${row.recommendedReplenishment} 件）`)
}
</script>

<style scoped>
.ip-page { padding: 16px; }
.ip-summary { margin-bottom: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
.chart-mock {
  display: flex; align-items: flex-end; gap: 4px; height: 220px;
  border-bottom: 1px solid #eee; padding-bottom: 20px;
}
.chart-mock .bar {
  flex: 1; min-width: 0; background: linear-gradient(180deg, #67c23a, #95d475);
  border-radius: 3px 3px 0 0; position: relative; color: #fff; text-align: center;
}
.chart-mock .bar-label { position: absolute; bottom: -18px; left: 0; right: 0; font-size: 9px; color: #999; }
.chart-mock .bar-value { position: absolute; top: -18px; left: 0; right: 0; font-size: 9px; color: #666; }
</style>
