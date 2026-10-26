<template>
  <div class="ai-page">
    <el-card shadow="never">
      <template #header><div class="toolbar"><strong>库存预测与补货建议</strong><el-button :loading="loading" @click="load">重新加载预测</el-button></div></template>
      <el-alert title="预测仅依据系统内实际销售记录；数据不足时不推算销量或补货数量。采购需到采购管理填写供应商、采购价格等信息，本页不会生成采购单。" type="info" :closable="false" />
      <el-alert v-if="error" :title="error" type="error" :closable="false" />
      <el-table v-loading="loading" :data="list" stripe empty-text="暂无商品库存数据">
        <el-table-column prop="sku" label="SKU" min-width="160" />
        <el-table-column prop="productName" label="商品" min-width="180" />
        <el-table-column label="可用库存" width="110"><template #default="{ row }">{{ row.inventoryRecordExists ? row.availableStock : '无库存记录' }}</template></el-table-column>
        <el-table-column label="预测 30 天销量" width="140"><template #default="{ row }">{{ predictionValue(row, row.predictedDemand) }}</template></el-table-column>
        <el-table-column label="建议补货量" width="130"><template #default="{ row }">{{ predictionValue(row, row.replenishmentQty) }}</template></el-table-column>
        <el-table-column label="安全库存" width="110"><template #default="{ row }">{{ row.inventoryRecordExists ? row.safetyStock : '未设置' }}</template></el-table-column>
        <el-table-column label="预计可售天数" width="130"><template #default="{ row }">{{ predictionValue(row, row.stockoutDays) }}</template></el-table-column>
        <el-table-column prop="basis" label="计算依据" min-width="240" />
        <el-table-column label="操作" width="110" fixed="right"><template #default="{ row }"><el-button link type="primary" :disabled="forecastLoading" @click="showForecast(row)">预测详情</el-button></template></el-table-column>
      </el-table>
      <div class="toolbar pager"><span>第 {{ page }} 页，每页最多 100 个 SKU。</span><div><el-button :disabled="loading || page === 1" @click="page--; load()">上一页</el-button><el-button :disabled="loading || list.length < 100" @click="page++; load()">下一页</el-button></div></div>
    </el-card>
    <el-dialog v-model="forecastVisible" :title="`${selectedSku} 预测详情`" width="760px">
      <el-alert v-if="forecastError" :title="forecastError" type="error" :closable="false" />
      <el-button v-if="forecastError" :loading="forecastLoading" @click="loadForecast">重试</el-button>
      <div v-loading="forecastLoading" class="forecast">
        <el-empty v-if="!forecast && !forecastLoading" description="暂无预测数据" />
        <template v-if="forecast">
          <el-alert v-if="forecast.dataStatus === 'INSUFFICIENT_DATA'" title="历史销售数据不足，暂不提供预测。" type="warning" :closable="false" />
          <el-descriptions :column="1" border>
            <el-descriptions-item label="商品">{{ forecast.productName || selectedSku }}</el-descriptions-item>
            <el-descriptions-item label="可用库存">{{ forecast.inventoryRecordExists ? forecast.availableStock : '无库存记录' }}</el-descriptions-item>
            <el-descriptions-item label="观察期 / 销售日">{{ forecast.observationDays }} 天 / {{ forecast.salesDays }} 天</el-descriptions-item>
            <el-descriptions-item label="预测 30 天销量">{{ predictionValue(forecast, forecast.predictedDemand) }}</el-descriptions-item>
            <el-descriptions-item label="建议补货量">{{ predictionValue(forecast, forecast.replenishmentQty) }}</el-descriptions-item>
            <el-descriptions-item label="计算依据">{{ forecast.basis || '暂无说明' }}</el-descriptions-item>
          </el-descriptions>
          <el-table v-if="forecast.dataStatus !== 'INSUFFICIENT_DATA'" :data="forecast.forecast || []" max-height="300" empty-text="暂无逐日预测">
            <el-table-column prop="date" label="日期" />
            <el-table-column label="预计销量（历史日均值）"><template #default="{ row }">{{ row.demand == null ? '数据不足' : Number(row.demand).toFixed(2) }}</template></el-table-column>
          </el-table>
        </template>
      </div>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { aiCenterApi, aiError, type InventoryPrediction } from '@/api/ai'

const list = ref<InventoryPrediction[]>([])
const page = ref(1)
const loading = ref(false)
const error = ref('')
const forecastVisible = ref(false)
const forecastLoading = ref(false)
const forecastError = ref('')
const selectedSku = ref('')
const forecast = ref<InventoryPrediction | null>(null)
const predictionValue = (row: InventoryPrediction, value: number | null | undefined) => row.dataStatus === 'INSUFFICIENT_DATA' || value == null ? '数据不足' : value

async function load() {
  loading.value = true
  error.value = ''
  try { list.value = await aiCenterApi.inventory({ limit: 100, offset: (page.value - 1) * 100 }) }
  catch (e) { list.value = []; error.value = aiError(e) }
  finally { loading.value = false }
}

async function showForecast(row: InventoryPrediction) {
  selectedSku.value = row.sku
  forecastVisible.value = true
  await loadForecast()
}

async function loadForecast() {
  forecastLoading.value = true
  forecastError.value = ''
  forecast.value = null
  try { forecast.value = await aiCenterApi.forecast(selectedSku.value) }
  catch (e) { forecastError.value = aiError(e) }
  finally { forecastLoading.value = false }
}

onMounted(load)
</script>

<style scoped>
.ai-page { padding: 16px; }
.toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.el-alert { margin-bottom: 12px; }
.forecast { min-height: 120px; }
.pager { margin-top: 16px; flex-wrap: wrap; }
</style>
