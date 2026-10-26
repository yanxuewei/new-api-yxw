<template>
  <div class="ai-page">
    <el-card shadow="never">
      <template #header><div class="toolbar"><strong>订单异常检测</strong><div>
        <el-button :loading="loading" :disabled="busy || detecting" @click="load">重新加载</el-button>
        <el-button type="primary" :loading="detecting" :disabled="loading || busy" @click="detect">执行规则检测</el-button>
      </div></div></template>
      <el-alert title="依据实际订单数据进行规则检查，分数只用于辅助审核，不代表已确认异常。" type="info" :closable="false" />
      <el-alert v-if="error" :title="error" type="error" :closable="false" />
      <div v-if="stats" class="summary">
        <span>订单总数：{{ stats.totalOrders }}</span>
        <span>统计扫描：{{ stats.scanned }}</span>
        <span>范围内异常：{{ stats.anomalous }}</span>
        <span>待处理：{{ stats.pending ?? '—' }}</span>
        <span>已确认：{{ stats.confirmed ?? '—' }}</span>
        <span>已驳回：{{ stats.rejected ?? '—' }}</span>
      </div>
      <el-alert v-if="stats" :title="`${stats.basis}${stats.truncated ? ' 当前统计已达到扫描上限。' : ''}`" type="info" :closable="false" />
      <el-alert v-if="detectionNote" :title="detectionNote" type="success" :closable="false" />
      <el-select v-model="status" placeholder="全部状态" clearable class="filter">
        <el-option label="待处理" value="PENDING" /><el-option label="已确认" value="CONFIRMED" /><el-option label="已驳回" value="REJECTED" />
      </el-select>
      <el-table v-loading="loading" :data="filtered" stripe empty-text="暂无异常记录，可执行规则检测">
        <el-table-column prop="orderNo" label="订单号" min-width="180" />
        <el-table-column prop="platform" label="平台" width="110" />
        <el-table-column label="订单金额" min-width="180"><template #default="{ row }">{{ formatAmount(row.orderAmount, row.currency) }}</template></el-table-column>
        <el-table-column prop="riskScore" label="规则分数" width="100" />
        <el-table-column label="检测依据" min-width="260"><template #default="{ row }"><div v-for="rule in row.rules" :key="rule.code">{{ rule.message }}</div></template></el-table-column>
        <el-table-column label="金额核对" min-width="160"><template #default="{ row }">{{ row.amountComparison === 'COMPARED' ? '同币种明细已核对' : '币种或金额不完整，未比较' }}</template></el-table-column>
        <el-table-column prop="confirmedAt" label="审核时间" min-width="180" />
        <el-table-column label="状态" width="100"><template #default="{ row }">{{ labels[row.confirmationStatus] || row.confirmationStatus }}</template></el-table-column>
        <el-table-column label="操作" width="150" fixed="right"><template #default="{ row }">
          <template v-if="row.confirmationStatus === 'PENDING'">
            <el-button link type="danger" :disabled="busy || detecting || loading" @click="confirm(row, 'CONFIRMED')">确认异常</el-button>
            <el-button link :disabled="busy || detecting || loading" @click="confirm(row, 'REJECTED')">驳回</el-button>
          </template>
          <span v-else>已审核</span>
        </template></el-table-column>
      </el-table>
      <div class="toolbar pager"><span>第 {{ page }} 页，展示本批最多 100 笔订单中的异常记录；状态筛选仅作用于本页。</span><div><el-button :disabled="loading || busy || detecting || page === 1" @click="page--; load()">上一页</el-button><el-button :disabled="loading || busy || detecting || list.length < 100" @click="page++; load()">下一页</el-button></div></div>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { aiCenterApi, aiError, formatAmount, type AnomalyOrder } from '@/api/ai'

const list = ref<AnomalyOrder[]>([])
const stats = ref<Awaited<ReturnType<typeof aiCenterApi.anomalyStats>> | null>(null)
const detectionNote = ref('')
const status = ref('')
const page = ref(1)
const loading = ref(false)
const detecting = ref(false)
const busy = ref(false)
const error = ref('')
const labels: Record<string, string> = { PENDING: '待处理', CONFIRMED: '已确认', REJECTED: '已驳回' }
const filtered = computed(() => list.value.filter(row => row.anomalous && (!status.value || row.confirmationStatus === status.value)))

async function load() {
  loading.value = true
  error.value = ''
  try { [list.value, stats.value] = await Promise.all([aiCenterApi.anomalies({ limit: 100, offset: (page.value - 1) * 100 }), aiCenterApi.anomalyStats()]) }
  catch (e) { list.value = []; stats.value = null; error.value = aiError(e) }
  finally { loading.value = false }
}

async function detect() {
  if (detecting.value || busy.value) return
  detecting.value = true
  error.value = ''
  try {
    const result = await aiCenterApi.detectAnomalies()
    detectionNote.value = `检测完成，实际扫描 ${result.scanned} 笔订单${result.truncated ? '；已达到扫描上限，尚未覆盖全部订单' : ''}。`
    ElMessage.success(detectionNote.value)
    await load()
  } catch (e) { error.value = aiError(e) }
  finally { detecting.value = false }
}

async function confirm(row: AnomalyOrder, nextStatus: 'CONFIRMED' | 'REJECTED') {
  if (busy.value) return
  busy.value = true
  try {
    await ElMessageBox.confirm(`将订单 ${row.orderNo} 的异常记录标记为“${labels[nextStatus]}”？`, '审核确认', { type: 'warning' })
    await aiCenterApi.confirmAnomaly(row.id, nextStatus, row.confirmationStatus, row.ruleKey)
    ElMessage.success('审核结果已保存')
    await load()
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') {
      const message = aiError(e)
      await load()
      error.value = message
    }
  } finally { busy.value = false }
}

onMounted(load)
</script>

<style scoped>
.ai-page { padding: 16px; }
.toolbar, .summary { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
.summary { padding: 16px 0; justify-content: flex-start; }
.el-alert { margin-bottom: 12px; }
.filter { width: 180px; margin-bottom: 16px; }
.pager { margin-top: 16px; }
</style>
