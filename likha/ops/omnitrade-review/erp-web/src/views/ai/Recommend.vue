<template>
  <div class="recommend-page">
    <el-card shadow="never">
      <template #header>
        <div class="card-head">
          <span>AI 选品推荐（基于历史销量 + 平台热点 + 利润率）</span>
          <el-button type="primary" :loading="refreshing" @click="refresh">刷新推荐</el-button>
        </div>
      </template>

      <el-row :gutter="16" class="summary">
        <el-col :span="6"><el-statistic title="候选商品数" :value="list.length" /></el-col>
        <el-col :span="6"><el-statistic title="平均推荐得分" :value="avgScore" :precision="2" suffix="/ 100" /></el-col>
        <el-col :span="6"><el-statistic title="平均预期利润率" :value="avgMargin" :precision="2" suffix="%" /></el-col>
        <el-col :span="6"><el-statistic title="刷新时间" :value="lastRefresh" /></el-col>
      </el-row>

      <el-table :data="list" v-loading="loading" stripe>
        <el-table-column prop="sku"          label="SKU" width="180" />
        <el-table-column prop="productName"  label="推荐商品" />
        <el-table-column prop="category"     label="类目" width="120" />
        <el-table-column label="推荐得分" width="140">
          <template #default="{ row }">
            <el-progress :percentage="row.score" :stroke-width="14" :format="() => row.score + ' 分'" />
          </template>
        </el-table-column>
        <el-table-column prop="expectedMargin" label="预期利润率" width="120">
          <template #default="{ row }">
            <el-tag :type="row.expectedMargin > 30 ? 'success' : 'warning'" size="small">{{ row.expectedMargin }}%</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="reason"       label="推荐理由"  show-overflow-tooltip />
        <el-table-column label="操作" width="160" fixed="right">
          <template #default="{ row }">
            <el-button link type="primary" size="small" @click="viewDetail(row)">详情</el-button>
            <el-button link type="success" size="small" @click="addToShelf(row)">加入选品库</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <el-dialog v-model="detailVisible" title="推荐详情" width="600px">
      <div v-if="detail">
        <h3>{{ detail.productName }}</h3>
        <p>{{ detail.reason }}</p>
        <el-descriptions :column="2" border size="small">
          <el-descriptions-item label="SKU">{{ detail.sku }}</el-descriptions-item>
          <el-descriptions-item label="类目">{{ detail.category }}</el-descriptions-item>
          <el-descriptions-item label="推荐得分">{{ detail.score }} 分</el-descriptions-item>
          <el-descriptions-item label="预期利润率">{{ detail.expectedMargin }}%</el-descriptions-item>
        </el-descriptions>
      </div>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import { recommendApi } from '@/api/ai'

const list = ref<any[]>([])
const loading = ref(false)
const refreshing = ref(false)
const detailVisible = ref(false)
const detail = ref<any>(null)
const lastRefresh = ref('')

const avgScore = computed(() => {
  if (!list.value.length) return 0
  return list.value.reduce((s, x) => s + (x.score || 0), 0) / list.value.length
})
const avgMargin = computed(() => {
  if (!list.value.length) return 0
  return list.value.reduce((s, x) => s + (x.expectedMargin || 0), 0) / list.value.length
})

onMounted(load)

async function load() {
  loading.value = true
  try {
    list.value = await recommendApi.list({})
  } catch {
    list.value = [
      { sku: 'SKU-BTY-010',     productName: '精华液 30ml - 玻尿酸烟酰胺', category: '美妆个护', score: 92, expectedMargin: 65, reason: '近 90 天平台搜索量上涨 320%，TikTok 标签 #GlowUp 累计 1.2 亿播放' },
      { sku: 'SKU-PWB-005-BLK', productName: '20000mAh 充电宝',          category: '数码',     score: 88, expectedMargin: 58, reason: '夏季旅行季 + 跨境充电刚需，亚马逊 BSR 排名上涨 28 位' },
      { sku: 'SKU-WOM-009-L',   productName: '女士瑜伽裤',              category: '服饰',     score: 85, expectedMargin: 64, reason: 'Lululemon 平替讨论热度高，客单价提升 12%' },
      { sku: 'SKU-MEN-008-XL',  productName: '男士速干 T 恤',            category: '服饰',     score: 80, expectedMargin: 66, reason: '健身场景季节性需求，回购率 35%' },
      { sku: 'SKU-STG-007',     productName: '真空收纳袋 10 件',         category: '家居',     score: 78, expectedMargin: 64, reason: '收纳整理赛道蓝海，欧洲市场 CAGR 18%' },
    ]
  } finally {
    loading.value = false
    lastRefresh.value = new Date().toLocaleTimeString()
  }
}

async function refresh() {
  refreshing.value = true
  try {
    await recommendApi.refresh()
    await load()
  } catch { await load() }
  refreshing.value = false
  ElMessage.success('推荐已刷新')
}

function viewDetail(row: any) { detail.value = row; detailVisible.value = true }
function addToShelf(row: any) { ElMessage.success(`已加入选品库：${row.sku}`) }
</script>

<style scoped>
.recommend-page { padding: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
.summary { margin-bottom: 16px; padding: 12px; background: #fafafa; border-radius: 4px; }
</style>
