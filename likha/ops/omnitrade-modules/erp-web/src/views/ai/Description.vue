<template>
  <div class="ai-page">
    <el-card shadow="never">
      <template #header><div class="toolbar"><strong>商品描述生成</strong><el-button :loading="loading" :disabled="generating || saving" @click="load">重新加载</el-button></div></template>
      <el-alert v-if="error" :title="error" type="error" :closable="false" />
      <el-alert v-if="status && !status.modelConfigured" title="未配置模型，无法生成商品描述。请联系管理员配置模型；已有历史记录仍可查看。" type="warning" :closable="false" />
      <el-alert v-if="!loading && !error && !products.length" title="暂无商品 SKU，请先在商品管理录入商品。" type="info" :closable="false" />
      <el-alert v-if="products.length === 500" title="下拉列表展示首批 500 个商品；可直接输入其他真实 SKU，生成时由服务端校验商品是否存在且已启用。" type="warning" :closable="false" />
      <el-alert title="生成内容仅为草稿，请核实商品事实、认证及售后承诺。中文、英文保存会更新所属商品对应语言描述；日语、西语仅保存到文案库，不写入商品。" type="info" :closable="false" />
      <div class="workspace">
        <el-form label-position="top" :disabled="generating || saving || loading">
          <el-form-item label="商品 SKU"><el-select v-model="form.sku" filterable allow-create default-first-option placeholder="选择或直接输入真实商品 SKU" style="width: 100%"><el-option v-for="product in products" :key="product.sku" :label="`${product.sku} - ${product.productName}`" :value="product.sku" /></el-select></el-form-item>
          <el-form-item label="目标语言"><el-select v-model="form.language" style="width: 100%"><el-option label="中文" value="zh" /><el-option label="英文" value="en" /><el-option label="日语" value="ja" /><el-option label="西班牙语" value="es" /></el-select></el-form-item>
          <el-form-item label="语气"><el-select v-model="form.tone" style="width: 100%"><el-option label="专业严谨" value="professional" /><el-option label="轻松自然" value="casual" /><el-option label="平实日常" value="everyday" /></el-select></el-form-item>
          <el-form-item label="关键词（须符合商品事实）"><el-input v-model="form.keywordsText" type="textarea" :rows="3" maxlength="1000" placeholder="多个关键词以逗号分隔" /></el-form-item>
          <el-button type="primary" :loading="generating" :disabled="!status?.modelConfigured || !form.sku || loading || saving" @click="generate">{{ pendingRequest ? '查询 / 重试原请求' : '生成描述' }}</el-button>
          <el-button v-if="pendingRequest && !generating" :disabled="!status?.modelConfigured || saving" @click="newGeneration">发起新请求</el-button>
        </el-form>
        <div class="result" v-loading="generating">
          <el-alert v-if="generationError" :title="generationError" type="error" :closable="false" />
          <template v-if="result">
            <div class="toolbar"><strong>{{ result.sku }} · {{ languageLabels[result.language] || result.language }}</strong><el-tag :type="result.saved ? 'success' : 'info'">{{ result.saved ? '已保存' : '未保存草稿' }}</el-tag></div>
            <p class="metadata">模型：{{ result.model }} · {{ result.createdAt }}</p>
            <div class="description-text">{{ result.description }}</div>
            <p class="metadata">{{ result.saveNote }}</p>
            <div class="actions"><el-button :disabled="generating" @click="copy">复制正文</el-button><el-button type="success" :loading="saving" :disabled="generating || result.saved" @click="save">{{ ['ja', 'es'].includes(result.language) ? '保存到文案库' : '保存到商品' }}</el-button></div>
          </template>
          <el-empty v-else description="选择商品并生成描述，或查看历史记录" />
        </div>
      </div>
      <el-divider />
      <h3>生成历史（最近 200 条）</h3>
      <el-alert v-if="historyError" :title="historyError" type="error" :closable="false" />
      <el-button v-if="historyError" :disabled="loading" @click="loadHistory">重试历史加载</el-button>
      <el-table v-loading="loading" :data="history" empty-text="暂无生成记录">
        <el-table-column prop="sku" label="SKU" min-width="170" />
        <el-table-column label="语言" width="100"><template #default="{ row }">{{ languageLabels[row.language] || row.language }}</template></el-table-column>
        <el-table-column prop="model" label="模型" min-width="180" />
        <el-table-column prop="createdAt" label="生成时间" min-width="180" />
        <el-table-column label="状态" width="100"><template #default="{ row }">{{ row.saved ? '已保存' : '未保存' }}</template></el-table-column>
        <el-table-column label="操作" width="100"><template #default="{ row }"><el-button link type="primary" :disabled="generating || saving" @click="result = row">查看</el-button></template></el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { aiCenterApi, aiError, type AiStatus, type DescriptionRequest, type GeneratedDescription, type PriceSuggest } from '@/api/ai'

const status = ref<AiStatus | null>(null)
const products = ref<PriceSuggest[]>([])
const history = ref<GeneratedDescription[]>([])
const result = ref<GeneratedDescription | null>(null)
const loading = ref(false)
const generating = ref(false)
const saving = ref(false)
const error = ref('')
const generationError = ref('')
const historyError = ref('')
const pendingRequest = ref<DescriptionRequest | null>(null)
const form = reactive({ sku: '', language: 'zh' as DescriptionRequest['language'], tone: 'professional', keywordsText: '' })
const languageLabels: Record<string, string> = { zh: '中文', en: '英文', ja: '日语', es: '西班牙语' }

async function loadHistory() {
  historyError.value = ''
  try { history.value = await aiCenterApi.descriptionHistory() }
  catch (e) { history.value = []; historyError.value = aiError(e) }
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    [status.value, products.value] = await Promise.all([aiCenterApi.status(), aiCenterApi.pricing({ limit: 500 })])
  } catch (e) { status.value = null; products.value = []; error.value = aiError(e) }
  await loadHistory()
  loading.value = false
}

async function generate() {
  if (generating.value || saving.value || !status.value?.modelConfigured || !form.sku) return
  generating.value = true
  generationError.value = ''
  result.value = null
  try {
    const data = { sku: form.sku, language: form.language, tone: form.tone, keywords: form.keywordsText.split(/[,，]/).map(value => value.trim()).filter(Boolean) }
    const previous = pendingRequest.value
    const sameRequest = previous && previous.sku === data.sku && previous.language === data.language && previous.tone === data.tone && JSON.stringify(previous.keywords) === JSON.stringify(data.keywords)
    const payload: DescriptionRequest = previous && sameRequest ? previous : { ...data, requestId: crypto.randomUUID() }
    pendingRequest.value = payload
    result.value = await aiCenterApi.generateDescription(payload)
    pendingRequest.value = null
    await loadHistory()
  } catch (e) { generationError.value = `${aiError(e)}。未收到有效生成结果，可重试当前参数。` }
  finally { generating.value = false }
}

async function newGeneration() {
  try {
    await ElMessageBox.confirm('新请求会重新调用模型，可能产生额外费用。请先查看历史记录，确认确实需要再次生成。', '确认新请求', { type: 'warning' })
    pendingRequest.value = null
    await generate()
  } catch (e) { if (e !== 'cancel' && e !== 'close') generationError.value = aiError(e) }
}

async function copy() {
  if (!result.value) return
  try { await navigator.clipboard.writeText(result.value.description); ElMessage.success('正文已复制') }
  catch { ElMessage.error('复制失败，请手动选择正文复制') }
}

async function save() {
  if (!result.value || saving.value || generating.value || result.value.saved) return
  saving.value = true
  const selected = result.value
  try {
    const libraryOnly = ['ja', 'es'].includes(selected.language)
    await ElMessageBox.confirm(libraryOnly
      ? `将 ${selected.sku} 的${languageLabels[selected.language]}描述保存到文案库？商品表没有对应语言字段，不会写入商品。`
      : `将 ${selected.sku} 的这份${languageLabels[selected.language] || selected.language}描述保存到所属商品？请确认内容真实，保存将覆盖该语言的现有描述。`, '确认保存', { type: 'warning' })
    result.value = await aiCenterApi.saveDescription(selected.id)
    ElMessage.success(result.value.productUpdated ? '描述已保存到商品' : '描述已保存到文案库，未写入商品')
    await loadHistory()
  } catch (e) { if (e !== 'cancel' && e !== 'close') generationError.value = aiError(e) }
  finally { saving.value = false }
}

onMounted(load)
</script>

<style scoped>
.ai-page { padding: 16px; }
.toolbar { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
.el-alert { margin-bottom: 12px; }
.workspace { display: grid; grid-template-columns: minmax(240px, 1fr) minmax(320px, 2fr); gap: 24px; margin-top: 20px; }
.result { min-height: 300px; border: 1px solid var(--el-border-color); border-radius: 6px; padding: 20px; }
.description-text { white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.8; }
.metadata { color: var(--el-text-color-secondary); }
.actions { margin-top: 20px; }
@media (max-width: 800px) { .workspace { grid-template-columns: 1fr; } }
</style>
