<template>
  <div class="purchase-page">
    <el-card shadow="never">
      <template #header>
        <div class="card-head">
          <span>采购订单</span>
          <div>
            <el-select v-model="filter.status" placeholder="状态" clearable style="width: 140px; margin-right: 8px" @change="load">
              <el-option label="草稿" value="DRAFT" />
              <el-option label="待审核" value="PENDING" />
              <el-option label="已审核" value="APPROVED" />
              <el-option label="已发货" value="SHIPPED" />
              <el-option label="已完成" value="COMPLETED" />
              <el-option label="已取消" value="CANCELLED" />
            </el-select>
            <el-button type="primary" @click="newPo">新建采购单</el-button>
          </div>
        </div>
      </template>

      <el-table :data="list" v-loading="loading" stripe>
        <el-table-column prop="poNo"           label="采购单号"  width="160" />
        <el-table-column prop="supplierName"   label="供应商" />
        <el-table-column prop="totalAmount"    label="总额"      width="120">
          <template #default="{ row }">¥ {{ row.totalAmount.toLocaleString() }}</template>
        </el-table-column>
        <el-table-column prop="currencyCode"   label="币种"      width="80" />
        <el-table-column prop="status"         label="状态"      width="100">
          <template #default="{ row }">
            <el-tag :type="statusType(row.status)" size="small">{{ row.status }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="expectedDate"   label="预计到货"  width="120" />
        <el-table-column prop="createdAt"      label="创建时间"  width="180" />
        <el-table-column label="操作" width="240" fixed="right">
          <template #default="{ row }">
            <el-button link type="primary" size="small" @click="view(row)">查看</el-button>
            <el-button link type="success" size="small" v-if="row.status === 'PENDING'"  @click="approve(row)">审核</el-button>
            <el-button link type="warning" size="small" v-if="row.status === 'APPROVED'"  @click="receive(row)">收货</el-button>
            <el-button link type="danger"  size="small" v-if="['DRAFT','PENDING'].includes(row.status)" @click="cancel(row)">取消</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-card>

    <!-- 详情 dialog -->
    <el-dialog v-model="detailVisible" title="采购单详情" width="700px">
      <div v-if="detail">
        <el-descriptions :column="2" border size="small">
          <el-descriptions-item label="采购单号">{{ detail.poNo }}</el-descriptions-item>
          <el-descriptions-item label="供应商">{{ detail.supplierName }}</el-descriptions-item>
          <el-descriptions-item label="状态">{{ detail.status }}</el-descriptions-item>
          <el-descriptions-item label="币种">{{ detail.currencyCode }}</el-descriptions-item>
          <el-descriptions-item label="创建时间">{{ detail.createdAt }}</el-descriptions-item>
          <el-descriptions-item label="预计到货">{{ detail.expectedDate }}</el-descriptions-item>
        </el-descriptions>
        <h4 style="margin-top: 16px">采购明细</h4>
        <el-table :data="detail.items" border size="small">
          <el-table-column prop="sku"         label="SKU" />
          <el-table-column prop="productName" label="商品" />
          <el-table-column prop="quantity"    label="数量" width="100" />
          <el-table-column prop="unitPrice"   label="单价" width="120" />
        </el-table>
      </div>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { purchaseApi } from '@/api/purchase'

const list = ref<any[]>([])
const loading = ref(false)
const filter = ref({ status: '' })
const detailVisible = ref(false)
const detail = ref<any>(null)

const statusType = (s: string) => ({
  DRAFT: 'info', PENDING: 'warning', APPROVED: 'primary',
  SHIPPED: 'success', COMPLETED: 'success', CANCELLED: 'danger',
}[s] || '')

onMounted(load)

async function load() {
  loading.value = true
  try {
    list.value = await purchaseApi.list(filter.value)
  } catch {
    // mock
    list.value = [
      { id: 1, poNo: 'PO-2026-0001', supplierName: 'AcmeSound',   totalAmount:  38400.00, currencyCode: 'CNY', status: 'COMPLETED', expectedDate: '2026-04-15', createdAt: '2026-04-01 10:00' },
      { id: 2, poNo: 'PO-2026-0002', supplierName: 'TechWear',    totalAmount:  56000.00, currencyCode: 'CNY', status: 'COMPLETED', expectedDate: '2026-04-20', createdAt: '2026-04-05 11:00' },
      { id: 3, poNo: 'PO-2026-0003', supplierName: 'ChargeMax',   totalAmount:  35000.00, currencyCode: 'CNY', status: 'APPROVED',  expectedDate: '2026-07-15', createdAt: '2026-07-01 14:00' },
      { id: 4, poNo: 'PO-2026-0004', supplierName: 'HomePlus',    totalAmount:  22500.00, currencyCode: 'CNY', status: 'PENDING',   expectedDate: '2026-07-25', createdAt: '2026-07-08 09:00' },
      { id: 5, poNo: 'PO-2026-0005', supplierName: 'FitWear',     totalAmount:  18000.00, currencyCode: 'CNY', status: 'DRAFT',     expectedDate: '2026-08-01', createdAt: '2026-07-09 09:30' },
      { id: 6, poNo: 'PO-2026-0006', supplierName: 'GlowLab',     totalAmount:  14000.00, currencyCode: 'CNY', status: 'PENDING',   expectedDate: '2026-07-30', createdAt: '2026-07-09 10:00' },
    ]
  } finally { loading.value = false }
}

async function view(row: any) {
  try {
    detail.value = await purchaseApi.detail(row.id)
  } catch {
    detail.value = {
      ...row,
      items: [
        { sku: 'SKU-BLU-001-BLK', productName: '蓝牙耳机-黑色', quantity: 320, unitPrice: 120.00 },
        { sku: 'SKU-BLU-001-WHT', productName: '蓝牙耳机-白色', quantity: 200, unitPrice: 120.00 },
      ],
    }
  }
  detailVisible.value = true
}

async function approve(row: any) {
  await ElMessageBox.confirm(`审核通过采购单 ${row.poNo}？`, '提示')
  row.status = 'APPROVED'
  ElMessage.success('已审核')
}

async function receive(row: any) {
  await ElMessageBox.confirm(`确认收货 ${row.poNo}？`, '提示')
  row.status = 'COMPLETED'
  ElMessage.success('已收货入库')
}

async function cancel(row: any) {
  const { value } = await ElMessageBox.prompt('取消原因', '提示')
  row.status = 'CANCELLED'
  ElMessage.success(`已取消：${value}`)
}

function newPo() {
  ElMessage.info('新建采购单 dialog（demo 占位）')
}
</script>

<style scoped>
.purchase-page { padding: 16px; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
</style>
