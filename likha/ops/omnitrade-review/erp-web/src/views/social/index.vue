<template>
  <div class="social-page">
    <el-tabs v-model="tab">
      <el-tab-pane label="TikTok Shop" name="tiktok">
        <el-card shadow="never">
          <template #header>
            <div class="card-head">
              <span>TikTok Shop 商品同步状态</span>
              <el-button type="primary" @click="sync('TikTok')">立即同步</el-button>
            </div>
          </template>
          <el-table :data="tiktok" stripe>
            <el-table-column prop="productId" label="商品 ID" />
            <el-table-column prop="title"     label="标题" />
            <el-table-column prop="price"     label="价格" width="100" />
            <el-table-column prop="stock"     label="库存" width="80" />
            <el-table-column prop="syncStatus" label="同步状态" width="120">
              <template #default="{ row }">
                <el-tag :type="row.syncStatus === 'OK' ? 'success' : 'danger'" size="small">{{ row.syncStatus }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="syncedAt"  label="同步时间" width="200" />
          </el-table>
        </el-card>
      </el-tab-pane>

      <el-tab-pane label="直播" name="live">
        <el-card shadow="never">
          <template #header>
            <div class="card-head">
              <span>直播管理</span>
              <el-button type="primary" @click="newLive">新建直播</el-button>
            </div>
          </template>
          <el-table :data="lives" stripe>
            <el-table-column prop="title"    label="直播标题" />
            <el-table-column prop="platform" label="平台" width="120" />
            <el-table-column prop="host"     label="主播" width="120" />
            <el-table-column prop="viewers"  label="观看人数" width="100" />
            <el-table-column prop="gmv"      label="GMV（USD）" width="120" />
            <el-table-column prop="status"   label="状态" width="100">
              <template #default="{ row }">
                <el-tag :type="row.status === 'LIVE' ? 'danger' : (row.status === 'ENDED' ? 'info' : 'warning')" size="small">{{ row.status }}</el-tag>
              </template>
            </el-table-column>
          </el-table>
        </el-card>
      </el-tab-pane>

      <el-tab-pane label="达人合作" name="kol">
        <el-card shadow="never">
          <template #header>
            <div class="card-head">
              <span>达人合作</span>
              <el-button type="primary">邀请达人</el-button>
            </div>
          </template>
          <el-table :data="kols" stripe>
            <el-table-column prop="name"      label="达人昵称" />
            <el-table-column prop="platform"  label="平台" width="120" />
            <el-table-column prop="followers" label="粉丝数" width="140" />
            <el-table-column prop="category"  label="类目" />
            <el-table-column prop="cooperationStatus" label="合作状态" width="120">
              <template #default="{ row }">
                <el-tag size="small">{{ row.cooperationStatus }}</el-tag>
              </template>
            </el-table-column>
          </el-table>
        </el-card>
      </el-tab-pane>

      <el-tab-pane label="抖音小店" name="douyin">
        <el-card shadow="never">
          <template #header>
            <div class="card-head">
              <span>抖音小店订单</span>
              <el-button type="primary" @click="sync('抖音')">同步订单</el-button>
            </div>
          </template>
          <el-table :data="douyin" stripe>
            <el-table-column prop="orderId" label="订单号" />
            <el-table-column prop="product" label="商品" />
            <el-table-column prop="amount"  label="金额（CNY）" width="120" />
            <el-table-column prop="status"  label="状态" width="100" />
          </el-table>
        </el-card>
      </el-tab-pane>
    </el-tabs>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import { socialApi } from '@/api/social'

const tab = ref('tiktok')
const tiktok = ref<any[]>([])
const lives = ref<any[]>([])
const kols = ref<any[]>([])
const douyin = ref<any[]>([])

onMounted(load)

async function load() {
  try {
    tiktok.value = await socialApi.tiktokShop.list({})
    lives.value = await socialApi.liveStream.list({})
    kols.value = await socialApi.influencer.list({})
    douyin.value = await socialApi.douyinShop.list({})
  } catch {
    // mock
    tiktok.value = [
      { productId: 'TTK-556677', title: '20000mAh 充电宝', price: 199.00, stock: 350, syncStatus: 'OK',   syncedAt: '2026-07-06 02:15' },
      { productId: 'TTK-556678', title: '便携手机支架',     price: 39.00,  stock: 800, syncStatus: 'FAIL', syncedAt: '2026-07-06 02:15' },
      { productId: 'TTK-556679', title: '硅胶厨具套装',     price: 129.00, stock: 200, syncStatus: 'OK',   syncedAt: '2026-07-06 02:15' },
    ]
    lives.value = [
      { title: '今晚上新：蓝牙耳机 Pro', platform: 'TikTok', host: '小美', viewers: 12850, gmv: 3460,  status: 'LIVE'  },
      { title: '充电宝专场直播',         platform: '抖音',   host: '老王', viewers: 8920,  gmv: 1820,  status: 'ENDED' },
      { title: '智能穿戴下午茶',         platform: 'Shopee Live', host: 'Mei', viewers: 4560, gmv: 980, status: 'SCHEDULED' },
    ]
    kols.value = [
      { name: '@美妆小美',  platform: 'TikTok',  followers: '1.2M', category: '美妆个护', cooperationStatus: '已合作' },
      { name: '@数码大叔',  platform: '抖音',    followers: '860K', category: '数码',     cooperationStatus: '洽谈中' },
      { name: '@HomeDesign', platform: 'Instagram', followers: '320K', category: '家居',     cooperationStatus: '已合作' },
      { name: '@TechTik',   platform: 'TikTok',  followers: '540K', category: '数码',     cooperationStatus: '已合作' },
    ]
    douyin.value = [
      { orderId: 'DYD-001', product: '65W GaN 充电器', amount: 89,  status: '待发货' },
      { orderId: 'DYD-002', product: '充电宝 黑色',    amount: 199, status: '已发货' },
      { orderId: 'DYD-003', product: '瑜伽裤 M',       amount: 129, status: '已完成' },
    ]
  }
}

async function sync(platform: string) {
  try { await socialApi.tiktokShop.sync() } catch {}
  ElMessage.success(`${platform} 同步任务已提交`)
}

function newLive() {
  ElMessage.info('请填写直播信息（弹窗 demo）')
}
</script>

<style scoped>
.social-page { padding: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
</style>
