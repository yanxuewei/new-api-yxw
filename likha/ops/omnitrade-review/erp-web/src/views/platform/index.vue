<template>
  <div class="platform-page">
    <el-alert
      title="当前仅支持查询平台配置；新增、编辑、删除、连接测试及订单/商品同步尚未实现，相关操作已禁用。"
      type="warning" :closable="false" show-icon style="margin-bottom: 16px"
    />
    <el-alert v-if="loadError" :title="loadError" type="error" :closable="false" show-icon style="margin-bottom: 16px" />
    <el-card shadow="never">
      <template #header>
        <div class="card-header">
          <span>平台配置</span>
          <div>
            <el-button :loading="loading" @click="loadConfigs">刷新</el-button>
            <el-button type="primary" :icon="Plus" disabled title="只读模式：新增尚未实现">添加配置</el-button>
          </div>
        </div>
      </template>
      <el-table v-loading="loading" :data="configList" stripe style="width: 100%">
        <el-table-column prop="platform" label="平台" width="120">
          <template #default="{ row }"><el-tag>{{ getPlatformName(row.platform) }}</el-tag></template>
        </el-table-column>
        <el-table-column prop="shopId" label="店铺ID" width="150" />
        <el-table-column prop="shopName" label="店铺名称" width="180" />
        <el-table-column prop="apiBaseUrl" label="API地址" min-width="200" show-overflow-tooltip />
        <el-table-column prop="status" label="状态" width="100">
          <template #default="{ row }">
            <el-tag :type="row.status === 1 ? 'success' : 'danger'">{{ row.status === 1 ? '启用' : '停用' }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="createTime" label="创建时间" width="160">
          <template #default="{ row }">{{ formatTime(row.createTime) }}</template>
        </el-table-column>
        <el-table-column label="操作（只读）" width="300" fixed="right">
          <template #default>
            <el-button link type="primary" size="small" disabled>同步订单</el-button>
            <el-button link type="success" size="small" disabled>同步商品</el-button>
            <el-button link type="primary" size="small" disabled>测试</el-button>
            <el-button link type="primary" size="small" disabled>编辑</el-button>
            <el-button link type="danger" size="small" disabled>删除</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { Plus } from '@element-plus/icons-vue'
import dayjs from 'dayjs'
import { platformApi, type PlatformConfig } from '@/api/platform'

const loading = ref(false)
const loadError = ref('')
const configList = ref<PlatformConfig[]>([])

const loadConfigs = async () => {
  loading.value = true
  loadError.value = ''
  try {
    const result = await platformApi.getConfigs()
    if (!Array.isArray(result)) throw new Error('平台配置接口返回格式异常')
    configList.value = result
  } catch (error) {
    console.error('加载平台配置失败', error)
    loadError.value = '加载平台配置失败，请检查登录状态或服务可用性后重试；当前保留上次查询结果。'
  } finally {
    loading.value = false
  }
}

const getPlatformName = (platform: string) => {
  const names: Record<string, string> = {
    amazon: '亚马逊', ebay: 'eBay', shopee: 'Shopee', lazada: 'Lazada',
    tiktok: 'TikTok Shop', temu: 'Temu', aliexpress: '速卖通', wish: 'Wish'
  }
  return names[platform] || platform
}
const formatTime = (time: string) => time ? dayjs(time).format('YYYY-MM-DD HH:mm:ss') : '-'
onMounted(loadConfigs)
</script>

<style scoped>
.platform-page { padding: 20px; }
.card-header { display: flex; justify-content: space-between; align-items: center; }
</style>
