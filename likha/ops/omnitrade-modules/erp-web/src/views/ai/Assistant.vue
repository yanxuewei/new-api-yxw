<template>
  <div class="ai-page">
    <el-card shadow="never">
      <template #header><div class="toolbar"><strong>AI 客服助手</strong><el-button :loading="loading" :disabled="sending || historyLoading || knowledgeBusy" @click="load">重新加载</el-button></div></template>
      <el-alert v-if="error" :title="error" type="error" :closable="false" />
      <el-alert v-if="status" :title="status.modelConfigured ? `已配置模型：${status.model || '未提供名称'}；知识库 ${status.knowledgeCount} 条` : `未配置模型：仅返回匹配的知识原文，不生成模型回答。当前知识库 ${status.knowledgeCount} 条，可继续维护知识库。`" :type="status.modelConfigured ? 'info' : 'warning'" :closable="false" />
      <p v-if="status?.notes" class="notes">{{ Array.isArray(status.notes) ? status.notes.join('；') : status.notes }}</p>
      <p class="notes">会话列表及会话消息分别展示最近 200 条记录；知识列表展示最近 50 条完整知识。</p>
      <el-tabs v-model="tab">
        <el-tab-pane label="对话" name="chat">
          <div class="toolbar session-toolbar">
            <el-select :model-value="sessionId" clearable placeholder="选择历史会话" :disabled="sending || historyLoading || loading" @change="switchSession">
              <el-option v-for="session in sessions" :key="session.sessionId" :label="session.title || session.sessionId" :value="session.sessionId" />
            </el-select>
            <el-button :disabled="sending || historyLoading || loading" @click="newSession">新会话</el-button>
          </div>
          <el-alert v-if="chatError" :title="chatError" type="error" :closable="false" />
          <el-button v-if="chatError && sessionId && !sending" :disabled="historyLoading" @click="switchSession(sessionId)">重新加载会话</el-button>
          <div ref="messageBox" v-loading="historyLoading" class="messages">
            <el-empty v-if="!messages.length && !historyLoading" description="暂无消息，请输入问题" />
            <div v-for="(message, index) in messages" :key="message.id || index" :class="['message', { user: message.role === 'user' }]">
              <strong>{{ message.role === 'user' ? '我' : '助手' }}</strong>
              <el-tag v-if="message.mode" size="small" :type="message.mode === 'MODEL' ? 'primary' : 'info'">{{ message.mode === 'MODEL' ? '模型回答' : '知识原文' }}</el-tag>
              <div class="content">{{ message.content }}</div>
              <div v-if="message.sources?.length" class="sources"><span>引用知识：</span><el-tag v-for="(source, i) in message.sources" :key="source.id || i" size="small" type="info">{{ source.title }}</el-tag></div>
            </div>
            <p v-if="sending" class="notes">正在请求服务端，请勿重复发送或切换会话…</p>
          </div>
          <el-input v-model="input" type="textarea" :rows="3" :maxlength="4000" show-word-limit :disabled="sending || historyLoading || historyFailed || loading || !status" placeholder="输入问题；Enter 发送，Shift+Enter 换行" @keydown.enter.exact.prevent="send" />
          <div class="actions"><el-button type="primary" :loading="sending" :disabled="!input.trim() || historyLoading || historyFailed || loading || !status" @click="send">{{ failedRequest ? '查询 / 重试原请求' : '发送' }}</el-button><el-button v-if="failedRequest && !sending" :disabled="historyLoading || historyFailed || loading || !status" @click="newRequest">发起新请求</el-button></div>
        </el-tab-pane>
        <el-tab-pane label="知识库管理" name="knowledge">
          <el-alert v-if="knowledgeError" :title="knowledgeError" type="error" :closable="false" />
          <el-form label-position="top">
            <el-form-item label="知识标题"><el-input v-model="knowledgeForm.title" maxlength="200" :disabled="knowledgeBusy" /></el-form-item>
            <el-form-item label="知识正文"><el-input v-model="knowledgeForm.content" type="textarea" :rows="4" maxlength="20000" show-word-limit :disabled="knowledgeBusy" /></el-form-item>
            <el-button type="primary" :loading="knowledgeBusy" :disabled="!knowledgeForm.title.trim() || !knowledgeForm.content.trim()" @click="addKnowledge">添加知识</el-button>
          </el-form>
          <el-table v-loading="loading" :data="knowledge" empty-text="知识库为空，请添加真实业务知识">
            <el-table-column prop="title" label="标题" min-width="180" />
            <el-table-column prop="content" label="正文" min-width="300"><template #default="{ row }"><div class="knowledge-content">{{ row.content }}</div></template></el-table-column>
            <el-table-column label="操作" width="90"><template #default="{ row }"><el-button link type="danger" :disabled="knowledgeBusy || sending" @click="removeKnowledge(row)">删除</el-button></template></el-table-column>
          </el-table>
        </el-tab-pane>
      </el-tabs>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { nextTick, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { aiCenterApi, aiError, type AiStatus, type ChatMessage, type ChatSession, type KnowledgeEntry } from '@/api/ai'

const status = ref<AiStatus | null>(null)
const sessions = ref<ChatSession[]>([])
const knowledge = ref<KnowledgeEntry[]>([])
const messages = ref<ChatMessage[]>([])
const loading = ref(false)
const sending = ref(false)
const historyLoading = ref(false)
const historyFailed = ref(false)
const knowledgeBusy = ref(false)
const error = ref('')
const chatError = ref('')
const knowledgeError = ref('')
const sessionId = ref('')
const input = ref('')
const tab = ref('chat')
const messageBox = ref<HTMLElement>()
const knowledgeForm = reactive({ title: '', content: '' })
const failedRequest = ref<{ sessionId?: string; message: string; requestId: string } | null>(null)

async function load() {
  loading.value = true
  error.value = ''
  try { [status.value, sessions.value, knowledge.value] = await Promise.all([aiCenterApi.status(), aiCenterApi.sessions(), aiCenterApi.knowledge()]) }
  catch (e) { status.value = null; error.value = aiError(e) }
  finally { loading.value = false }
}

async function switchSession(value: string) {
  if (sending.value || historyLoading.value) return
  if (!value) { newSession(); return }
  historyLoading.value = true
  historyFailed.value = false
  chatError.value = ''
  messages.value = []
  sessionId.value = value
  failedRequest.value = null
  try { messages.value = await aiCenterApi.chatHistory(value); await scrollBottom() }
  catch (e) { historyFailed.value = true; chatError.value = aiError(e) }
  finally { historyLoading.value = false }
}

function newSession() {
  if (sending.value || historyLoading.value) return
  sessionId.value = ''
  historyFailed.value = false
  messages.value = []
  input.value = ''
  chatError.value = ''
  failedRequest.value = null
}

async function send() {
  if (!input.value.trim() || sending.value || historyLoading.value || historyFailed.value || loading.value || !status.value) return
  sending.value = true
  chatError.value = ''
  const text = input.value.trim()
  const previous = failedRequest.value
  try {
    const payload = previous && previous.message === text && (previous.sessionId || '') === sessionId.value
      ? previous : { sessionId: sessionId.value || undefined, message: text, requestId: crypto.randomUUID() }
    failedRequest.value = payload
    const result = await aiCenterApi.chat(payload)
    messages.value.push({ role: 'user', content: text }, { id: result.id, role: 'assistant', content: result.reply, mode: result.mode, sources: result.sources })
    sessionId.value = result.sessionId
    input.value = ''
    failedRequest.value = null
    try { sessions.value = await aiCenterApi.sessions() }
    catch (e) { error.value = `回复已收到，但会话列表刷新失败：${aiError(e)}` }
  } catch (e) { chatError.value = `${aiError(e)}。未收到有效回复；可重试同一消息确认结果。` }
  finally { sending.value = false; await scrollBottom() }
}

async function newRequest() {
  try {
    await ElMessageBox.confirm('新请求可能重新调用收费模型。请先查看历史记录，确认不是重复发送。', '确认新请求', { type: 'warning' })
    failedRequest.value = null
    await send()
  } catch (e) { if (e !== 'cancel' && e !== 'close') chatError.value = aiError(e) }
}

async function scrollBottom() {
  await nextTick()
  if (messageBox.value) messageBox.value.scrollTop = messageBox.value.scrollHeight
}

async function addKnowledge() {
  if (knowledgeBusy.value || !knowledgeForm.title.trim() || !knowledgeForm.content.trim()) return
  knowledgeBusy.value = true
  knowledgeError.value = ''
  try {
    await aiCenterApi.addKnowledge({ title: knowledgeForm.title.trim(), content: knowledgeForm.content.trim() })
    knowledgeForm.title = ''
    knowledgeForm.content = ''
    ElMessage.success('知识已保存')
    await load()
  } catch (e) { knowledgeError.value = aiError(e) }
  finally { knowledgeBusy.value = false }
}

async function removeKnowledge(row: KnowledgeEntry) {
  if (knowledgeBusy.value || sending.value) return
  knowledgeBusy.value = true
  try {
    await ElMessageBox.confirm(`删除知识“${row.title}”？`, '确认删除', { type: 'warning' })
    await aiCenterApi.deleteKnowledge(row.id)
    ElMessage.success('知识已删除')
    await load()
  } catch (e) { if (e !== 'cancel' && e !== 'close') knowledgeError.value = aiError(e) }
  finally { knowledgeBusy.value = false }
}

onMounted(load)
</script>

<style scoped>
.ai-page { padding: 16px; }
.toolbar { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
.session-toolbar { margin-bottom: 12px; justify-content: flex-start; }
.session-toolbar .el-select { width: 360px; max-width: 70%; }
.el-alert { margin-bottom: 12px; }
.messages { height: 390px; overflow-y: auto; padding: 12px; background: var(--el-fill-color-light); margin: 12px 0; }
.message { padding: 12px; margin-bottom: 12px; background: var(--el-bg-color); border-radius: 6px; }
.message.user { border-left: 3px solid var(--el-color-primary); }
.message > .el-tag { margin-left: 12px; }
.content, .knowledge-content { white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.7; }
.content { margin-top: 8px; }
.knowledge-content { max-height: 140px; overflow: auto; }
.sources { margin-top: 12px; color: var(--el-text-color-secondary); }
.sources .el-tag { margin: 4px; }
.notes { color: var(--el-text-color-secondary); line-height: 1.6; }
.actions { margin-top: 12px; text-align: right; }
.el-form { margin-bottom: 20px; }
</style>
