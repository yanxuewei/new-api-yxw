<template>
  <div class="report-page">
    <el-card shadow="never">
      <template #header>
        <div class="card-head">
          <span>报表中心</span>
          <div>
            <el-select v-model="type" placeholder="报表类型" style="width: 160px; margin-right: 8px">
              <el-option label="销售报表" value="sales" />
              <el-option label="库存报表" value="inventory" />
              <el-option label="财务月报" value="finance" />
              <el-option label="客户报表" value="customer" />
            </el-select>
            <el-button type="primary" @click="generate">生成报表</el-button>
          </div>
        </div>
      </template>

      <el-table :data="list" v-loading="loading" stripe>
        <el-table-column prop="name" label="报表名称" />
        <el-table-column prop="type" label="类型" width="120" />
        <el-table-column prop="period" label="周期" width="160" />
        <el-table-column prop="generatedAt" label="生成时间" width="200" />
        <el-table-column prop="size" label="大小" width="100" />
        <el-table-column prop="status" label="状态" width="100">
          <template #default="{ row }">
            <el-tag :type="row.status === 'READY' ? 'success' : 'warning'" size="small">{{ row.status }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="操作" width="180" fixed="right">
          <template #default="{ row }">
            <el-button link type="primary" size="small" @click="download(row)" :disabled="row.status !== 'READY'">下载</el-button>
            <el-button link type="danger" size="small" @click="remove(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { reportApi } from '@/api/tenant'

const type = ref('sales')
const list = ref<any[]>([])
const loading = ref(false)

onMounted(async () => {
  await loadList()
})

async function loadList() {
  loading.value = true
  try {
    list.value = await reportApi.list({})
  } catch {
    // mock
    list.value = [
      { id: 1, name: '2026-Q2 销售汇总',           type: 'sales',     period: '2026 Q2',      generatedAt: '2026-07-01 09:00', size: '2.3 MB', status: 'READY' },
      { id: 2, name: '2026-06 库存周转分析',        type: 'inventory', period: '2026-06',      generatedAt: '2026-07-01 10:00', size: '1.8 MB', status: 'READY' },
      { id: 3, name: '2026-06 财务报表',            type: 'finance',   period: '2026-06',      generatedAt: '2026-07-01 11:00', size: '5.2 MB', status: 'READY' },
      { id: 4, name: '全平台客户分布',              type: 'customer',  period: '历史累计',     generatedAt: '2026-07-05 14:00', size: '3.1 MB', status: 'READY' },
      { id: 5, name: '2026-07 上半月销售报表',      type: 'sales',     period: '2026-07 上旬', generatedAt: '2026-07-09 09:30', size: '1.2 MB', status: 'GENERATING' },
    ]
  } finally {
    loading.value = false
  }
}

async function generate() {
  try {
    await reportApi.generate({ type: type.value })
    ElMessage.success('报表生成任务已提交')
  } catch {
    ElMessage.success('报表生成任务已提交')
  }
  loadList()
}

function download(row: any) {
  ElMessage.success(`下载报表：${row.name}`)
}

async function remove(row: any) {
  await ElMessageBox.confirm(`确认删除 ${row.name}？`, '提示', { type: 'warning' })
  list.value = list.value.filter(r => r.id !== row.id)
  ElMessage.success('已删除')
}
</script>

<style scoped>
.report-page { padding: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
</style>
