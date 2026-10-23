<template>
  <div class="logistics-page">
    <el-alert
      title="当前仅支持物流渠道和费率查询；运费计算、渠道新增、费率增删改及状态切换尚未实现，相关操作已禁用。"
      type="warning" :closable="false" show-icon class="section"
    />
    <el-card shadow="never" class="section">
      <template #header><span>运费计算器</span></template>
      <el-empty description="运费计算服务尚未实现，不提供模拟报价" :image-size="60" />
      <el-button type="primary" disabled title="运费计算尚未实现">计算运费</el-button>
    </el-card>

    <el-card shadow="never" class="section">
      <template #header>
        <div class="card-header">
          <span>物流渠道</span>
          <div>
            <el-button :loading="channelsLoading" @click="loadChannels">刷新</el-button>
            <el-button type="primary" disabled title="只读模式：渠道新增尚未实现">添加渠道</el-button>
          </div>
        </div>
      </template>
      <el-alert v-if="channelsError" :title="channelsError" type="error" :closable="false" show-icon class="section" />
      <div v-loading="channelsLoading">
        <el-empty v-if="channels.length === 0" description="暂无物流渠道数据" />
        <el-row :gutter="20">
          <el-col v-for="channel in channels" :key="channel.code" :span="8">
            <el-card class="section" shadow="hover">
              <div class="card-header">
                <strong>{{ channel.name }}</strong>
                <el-tag size="small">{{ channel.carrier }}</el-tag>
              </div>
              <p>类型：{{ getChannelTypeName(channel.type) }}</p>
              <p>覆盖：{{ channel.coverage?.join(', ') || '暂无数据' }}</p>
              <p>平均时效：{{ channel.avgDeliveryDays == null ? '暂无数据' : `${channel.avgDeliveryDays}天` }}</p>
              <p>追踪：{{ channel.trackingSupport == null ? '暂无数据' : channel.trackingSupport ? '支持' : '不支持' }}</p>
              <el-tag v-for="feature in channel.features" :key="feature" size="small" type="info" style="margin-right: 5px">{{ feature }}</el-tag>
            </el-card>
          </el-col>
        </el-row>
      </div>
    </el-card>

    <el-card shadow="never">
      <template #header><span>物流费率管理</span></template>
      <el-alert v-if="ratesError" :title="ratesError" type="error" :closable="false" show-icon class="section" />
      <el-form :inline="true" :model="rateSearchForm">
        <el-form-item label="渠道">
          <el-input v-model="rateSearchForm.channelCode" placeholder="渠道代码" clearable style="width: 140px" />
        </el-form-item>
        <el-form-item label="发货国">
          <el-input v-model="rateSearchForm.fromCountry" placeholder="发货国" clearable style="width: 100px" />
        </el-form-item>
        <el-form-item label="目的国">
          <el-input v-model="rateSearchForm.toCountry" placeholder="目的国" clearable style="width: 100px" />
        </el-form-item>
        <el-form-item>
          <el-button type="primary" @click="searchRates">搜索</el-button>
          <el-button @click="resetSearch">重置</el-button>
          <el-button type="success" disabled title="只读模式：费率新增尚未实现">新增费率</el-button>
        </el-form-item>
      </el-form>
      <el-table v-loading="ratesLoading" :data="rateList" stripe>
        <el-table-column prop="channelCode" label="渠道代码" width="140" />
        <el-table-column prop="channelName" label="渠道名称" width="150" />
        <el-table-column prop="carrier" label="承运商" width="100" />
        <el-table-column prop="fromCountry" label="发货国" width="80" />
        <el-table-column prop="toCountry" label="目的国" width="80" />
        <el-table-column prop="weightRangeMin" label="最小重量(kg)" width="120" />
        <el-table-column prop="weightRangeMax" label="最大重量(kg)" width="120" />
        <el-table-column label="基础价格" width="100">
          <template #default="{ row }">{{ formatPrice(row.basePrice) }}</template>
        </el-table-column>
        <el-table-column label="单价/kg" width="100">
          <template #default="{ row }">{{ formatPrice(row.pricePerKg) }}</template>
        </el-table-column>
        <el-table-column prop="currency" label="币种" width="80" />
        <el-table-column prop="estimatedDays" label="时效(天)" width="90" />
        <el-table-column label="状态" width="80">
          <template #default="{ row }"><el-switch :model-value="row.isActive" disabled /></template>
        </el-table-column>
        <el-table-column label="操作（只读）" width="140" fixed="right">
          <template #default>
            <el-button link type="primary" size="small" disabled>编辑</el-button>
            <el-button link type="danger" size="small" disabled>删除</el-button>
          </template>
        </el-table-column>
      </el-table>
      <el-pagination
        v-model:current-page="ratePagination.current"
        v-model:page-size="ratePagination.size"
        :total="ratePagination.total" :page-sizes="[10, 20, 50]"
        layout="total, sizes, prev, pager, next, jumper"
        @size-change="searchRates" @current-change="loadRates"
        style="margin-top: 20px; justify-content: flex-end"
      />
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { ref, reactive, onMounted } from 'vue'
import { logisticsApi, type LogisticsChannel, type LogisticsRate } from '@/api/inventory-alert'

const channels = ref<LogisticsChannel[]>([])
const channelsLoading = ref(false)
const channelsError = ref('')
const rateList = ref<LogisticsRate[]>([])
const ratesLoading = ref(false)
const ratesError = ref('')
const rateSearchForm = reactive({ channelCode: '', fromCountry: '', toCountry: '' })
const ratePagination = reactive({ current: 1, size: 20, total: 0 })

const loadChannels = async () => {
  channelsLoading.value = true
  channelsError.value = ''
  try {
    const result = await logisticsApi.getChannels()
    if (!Array.isArray(result)) throw new Error('物流渠道接口返回格式异常')
    channels.value = result
  } catch (error) {
    console.error('加载物流渠道失败', error)
    channelsError.value = '加载物流渠道失败，请检查登录状态或服务可用性后重试；当前保留上次查询结果。'
  } finally {
    channelsLoading.value = false
  }
}

const loadRates = async () => {
  ratesLoading.value = true
  ratesError.value = ''
  try {
    const result = await logisticsApi.getRates({
      page: ratePagination.current,
      size: ratePagination.size,
      channelCode: rateSearchForm.channelCode || undefined,
      fromCountry: rateSearchForm.fromCountry || undefined,
      toCountry: rateSearchForm.toCountry || undefined
    })
    if (!Array.isArray(result.records)) throw new Error('物流费率接口返回格式异常')
    rateList.value = result.records
    ratePagination.total = result.total
  } catch (error) {
    console.error('加载物流费率失败', error)
    ratesError.value = '加载物流费率失败，请检查登录状态或服务可用性后重试；当前保留上次查询结果。'
  } finally {
    ratesLoading.value = false
  }
}

const searchRates = () => { ratePagination.current = 1; loadRates() }
const resetSearch = () => {
  Object.assign(rateSearchForm, { channelCode: '', fromCountry: '', toCountry: '' })
  searchRates()
}
const formatPrice = (price: number | null) => price == null ? '-' : Number(price).toFixed(2)
const getChannelTypeName = (type: string) => {
  const names: Record<string, string> = { EXPRESS: '国际快递', SPECIAL: '专线物流', POST: '邮政小包', SEA: '海运', AIR: '空运' }
  return names[type] || type
}
onMounted(() => { loadChannels(); loadRates() })
</script>

<style scoped>
.logistics-page { padding: 20px; }
.section { margin-bottom: 20px; }
.card-header { display: flex; justify-content: space-between; align-items: center; }
</style>
