<template>
  <div class="ai-page">
    <el-card shadow="never">
      <template #header><div class="toolbar"><strong>选品推荐</strong><div>
        <el-button :loading="loading" :disabled="busy" @click="load">重新加载</el-button>
        <el-button type="primary" :loading="refreshing" :disabled="loading || busy" @click="refresh">重新计算推荐</el-button>
      </div></div></template>
      <el-alert title="仅基于系统内的商品、订单与成本数据进行规则推荐，未接入外部平台热度。加入选品库不等于商品上架。" type="info" :closable="false" />
      <el-alert v-if="error" :title="error" type="error" :closable="false" />
      <el-tabs v-model="tab">
        <el-tab-pane label="推荐列表" name="recommended" />
        <el-tab-pane label="已采纳选品" name="adopted" />
      </el-tabs>
      <el-table v-loading="loading" :data="tab === 'recommended' ? list : adopted" stripe empty-text="暂无选品数据">
        <el-table-column prop="sku" label="SKU" min-width="160" />
        <el-table-column prop="productName" label="商品" min-width="180" />
        <template v-if="tab === 'recommended'">
          <el-table-column prop="sales90d" label="90 日销量" width="110" />
          <el-table-column label="规则得分" width="110"><template #default="{ row }">{{ row.score == null ? '数据不足' : row.score }}</template></el-table-column>
          <el-table-column label="当前毛利率" width="120"><template #default="{ row }">{{ row.grossMargin == null ? '数据不足' : `${row.grossMargin}%` }}</template></el-table-column>
          <el-table-column prop="reason" label="评分依据" min-width="240" />
          <el-table-column prop="basis" label="数据口径" min-width="260" />
        </template>
        <el-table-column v-if="tab === 'adopted'" prop="createTime" label="采纳时间" min-width="180" />
        <el-table-column v-else label="操作" width="130" fixed="right"><template #default="{ row }">
          <el-button link type="primary" :disabled="busy || loading || refreshing || isAdopted(row)" @click="adopt(row)">{{ isAdopted(row) ? '已采纳' : '加入选品库' }}</el-button>
        </template></el-table-column>
      </el-table>
      <div class="toolbar pager"><span>第 {{ page }} 页，每页最多 100 条；得分排序仅针对本页候选。</span><div><el-button :disabled="loading || busy || refreshing || page === 1" @click="page--; load()">上一页</el-button><el-button :disabled="loading || busy || refreshing || (tab === 'recommended' ? list.length : adopted.length) < 100" @click="page++; load()">下一页</el-button></div></div>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { aiCenterApi, aiError, type ProductRecommend } from '@/api/ai'

const list = ref<ProductRecommend[]>([])
const adopted = ref<ProductRecommend[]>([])
const tab = ref('recommended')
const page = ref(1)
const loading = ref(false)
const refreshing = ref(false)
const busy = ref(false)
const error = ref('')
const isAdopted = (row: ProductRecommend) => row.adopted || adopted.value.some(item => item.sku === row.sku)

async function load() {
  loading.value = true
  error.value = ''
  try { [list.value, adopted.value] = await Promise.all([aiCenterApi.recommendations({ limit: 100, offset: (page.value - 1) * 100 }), aiCenterApi.adoptedRecommendations({ limit: 100, offset: (page.value - 1) * 100 })]) }
  catch (e) { list.value = []; adopted.value = []; error.value = aiError(e) }
  finally { loading.value = false }
}

async function refresh() {
  if (refreshing.value || busy.value) return
  refreshing.value = true
  error.value = ''
  try {
    await aiCenterApi.refreshRecommendations()
    ElMessage.success('服务端已重新计算推荐')
    await load()
  } catch (e) { error.value = aiError(e) }
  finally { refreshing.value = false }
}

async function adopt(row: ProductRecommend) {
  if (busy.value || isAdopted(row)) return
  busy.value = true
  error.value = ''
  try {
    await aiCenterApi.adoptRecommendation(row.sku)
    ElMessage.success('已保存到选品库')
    await load()
  } catch (e) { error.value = aiError(e) }
  finally { busy.value = false }
}

onMounted(load)
</script>

<style scoped>
.ai-page { padding: 16px; }
.toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.el-alert { margin-bottom: 12px; }
.pager { margin-top: 16px; }
</style>
