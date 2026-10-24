<template>
  <div class="ai-page">
    <el-card shadow="never">
      <template #header><div class="toolbar"><strong>智能定价</strong><el-button :loading="loading" :disabled="busy" @click="load">重新加载</el-button></div></template>
      <el-alert title="建议仅依据已有业务数据，不包含外部竞品价格。币种未设置时请先核对商品计价口径。" type="info" :closable="false" />
      <el-alert v-if="error" :title="error" type="error" :closable="false" />
      <el-input v-model="keyword" clearable placeholder="筛选 SKU 或商品名称" class="search" />
      <el-table v-loading="loading" :data="filtered" stripe empty-text="暂无商品，请先录入商品 SKU">
        <el-table-column prop="sku" label="SKU" min-width="150" />
        <el-table-column prop="productName" label="商品" min-width="150" />
        <el-table-column label="当前价格" min-width="180"><template #default="{ row }">{{ formatAmount(row.currentPrice, row.currency) }}</template></el-table-column>
        <el-table-column label="成本价" min-width="180"><template #default="{ row }">{{ formatAmount(row.costPrice, row.currency) }}</template></el-table-column>
        <el-table-column label="建议价格" min-width="180"><template #default="{ row }">{{ formatAmount(row.suggestedPrice, row.currency) }}</template></el-table-column>
        <el-table-column label="预期毛利率" width="120"><template #default="{ row }">{{ row.expectedMargin == null ? '数据不足' : `${row.expectedMargin}%` }}</template></el-table-column>
        <el-table-column prop="strategy" label="策略" min-width="120" />
        <el-table-column prop="basis" label="依据" min-width="220" />
        <el-table-column label="操作" width="150" fixed="right"><template #default="{ row }">
          <el-button link type="primary" :disabled="busy || loading || historyLoading" @click="showHistory(row)">历史</el-button>
          <el-button link type="success" :disabled="busy || loading || row.suggestedPrice == null || row.suggestedPrice === row.currentPrice" @click="apply(row)">采纳</el-button>
        </template></el-table-column>
      </el-table>
      <div class="toolbar pager"><span>第 {{ page }} 页，每页最多 100 个 SKU；筛选仅作用于本页。</span><div><el-button :disabled="loading || busy || page === 1" @click="page--; load()">上一页</el-button><el-button :disabled="loading || busy || list.length < 100" @click="page++; load()">下一页</el-button></div></div>
    </el-card>
    <el-dialog v-model="historyVisible" :title="`${historySku} 调价历史`" width="760px">
      <el-alert v-if="historyError" :title="historyError" type="error" :closable="false" />
      <el-button v-if="historyError" :loading="historyLoading" @click="loadHistory">重试</el-button>
      <p>显示最近 100 条调价记录。</p>
      <el-table v-loading="historyLoading" :data="history" empty-text="暂无调价记录">
        <el-table-column prop="createTime" label="时间" min-width="170" />
        <el-table-column label="原价格" min-width="180"><template #default="{ row }">{{ formatAmount(row.previousPrice, row.currency) }}</template></el-table-column>
        <el-table-column label="新价格" min-width="180"><template #default="{ row }">{{ formatAmount(row.newPrice, row.currency) }}</template></el-table-column>
      </el-table>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { aiCenterApi, aiError, formatAmount, type PriceSuggest } from '@/api/ai'

const list = ref<PriceSuggest[]>([])
const keyword = ref('')
const page = ref(1)
const loading = ref(false)
const busy = ref(false)
const error = ref('')
const historyVisible = ref(false)
const historyLoading = ref(false)
const historyError = ref('')
const historySku = ref('')
const history = ref<any[]>([])
const filtered = computed(() => list.value.filter(row => `${row.sku} ${row.productName}`.toLowerCase().includes(keyword.value.trim().toLowerCase())))

async function load() {
  loading.value = true
  error.value = ''
  try { list.value = await aiCenterApi.pricing({ limit: 100, offset: (page.value - 1) * 100 }) }
  catch (e) { list.value = []; error.value = aiError(e) }
  finally { loading.value = false }
}

async function apply(row: PriceSuggest) {
  if (busy.value || row.suggestedPrice == null) return
  busy.value = true
  try {
    await ElMessageBox.confirm(`将 ${row.sku} 从 ${formatAmount(row.currentPrice, row.currency)} 调整为 ${formatAmount(row.suggestedPrice, row.currency)}？这会修改商品价格。`, '确认采纳建议', { type: 'warning' })
    await aiCenterApi.applyPrice(row.sku, row.suggestedPrice, row.currentPrice)
    ElMessage.success('价格已保存')
    await load()
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') { const message = aiError(e); await load(); error.value = message }
  } finally { busy.value = false }
}

async function showHistory(row: PriceSuggest) {
  historySku.value = row.sku
  historyVisible.value = true
  await loadHistory()
}

async function loadHistory() {
  historyLoading.value = true
  historyError.value = ''
  history.value = []
  try { history.value = await aiCenterApi.priceHistory(historySku.value) }
  catch (e) { historyError.value = aiError(e) }
  finally { historyLoading.value = false }
}

onMounted(load)
</script>

<style scoped>
.ai-page { padding: 16px; }
.toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.el-alert { margin-bottom: 12px; }
.search { max-width: 420px; margin-bottom: 16px; }
.pager { margin-top: 16px; flex-wrap: wrap; }
</style>
