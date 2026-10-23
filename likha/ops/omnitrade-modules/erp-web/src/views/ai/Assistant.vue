<template>
  <div class="ai-assistant">
    <el-card shadow="never" class="chat-card">
      <template #header>
        <div class="card-head">
          <span><el-icon><MagicStick /></el-icon> AI 客服助手（基于 RAG 知识库）</span>
          <el-button size="small" @click="newSession">新会话</el-button>
        </div>
      </template>

      <div class="chat-messages" ref="msgBox">
        <div v-for="(m, i) in messages" :key="i" :class="['msg', m.role]">
          <div class="avatar">{{ m.role === 'user' ? '我' : 'AI' }}</div>
          <div class="bubble">{{ m.content }}</div>
        </div>
        <div v-if="loading" class="msg bot">
          <div class="avatar">AI</div>
          <div class="bubble typing">正在思考...</div>
        </div>
      </div>

      <div class="chat-input">
        <el-input v-model="input" type="textarea" :rows="2" placeholder="问点什么：如何查询订单？运费怎么算？" @keydown.enter.exact.prevent="send" />
        <div class="input-actions">
          <el-button @click="askFAQ('如何查询我的订单？')">订单查询</el-button>
          <el-button @click="askFAQ('运费怎么算？')">运费</el-button>
          <el-button @click="askFAQ('如何申请退款？')">退款</el-button>
          <el-button type="primary" :loading="loading" @click="send">发送 (Enter)</el-button>
        </div>
      </div>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { ref, nextTick } from 'vue'
import { aiAssistantApi } from '@/api/ai'
import { MagicStick } from '@element-plus/icons-vue'

const messages = ref<{ role: 'user' | 'bot'; content: string }[]>([
  { role: 'bot', content: '您好，我是 AI 助手。基于 330+ 行业知识库，可以回答订单、物流、库存、财务、退款等问题。' },
])
const input = ref('')
const loading = ref(false)
const sessionId = ref<string>('')
const msgBox = ref<HTMLElement>()

const FAQ: Record<string, string> = {
  '如何查询我的订单？': '您可以在「订单管理」页面查看所有订单信息，包括待付款、待发货、已发货等状态。支持按订单号、买家国家、商品 SKU 等多条件筛选。',
  '运费怎么算？': '国际运费根据目的地、重量、物流方式（DHL/YANWEN/SF）综合计算。具体可在「订单详情 → 物流信息」查看分摊的运费。',
  '如何申请退款？': '在订单详情页点击「申请售后」，选择退款类型和原因，提交后客服将在 24h 内处理。',
}

function askFAQ(q: string) { input.value = q; send() }

async function send() {
  if (!input.value.trim() || loading.value) return
  const text = input.value.trim()
  messages.value.push({ role: 'user', content: text })
  input.value = ''
  loading.value = true
  await nextTick(); scrollBottom()

  try {
    const r = await aiAssistantApi.chat({ sessionId: sessionId.value || undefined, message: text })
    messages.value.push({ role: 'bot', content: r.reply })
    sessionId.value = r.sessionId
  } catch {
    // 后端无响应时降级到 FAQ 或模板回答
    const fallback = FAQ[text] || '抱歉，AI 服务暂不可用。请稍后再试，或在左侧菜单「报表中心」查看数据。'
    messages.value.push({ role: 'bot', content: fallback })
  } finally {
    loading.value = false
    await nextTick(); scrollBottom()
  }
}

function scrollBottom() {
  if (msgBox.value) msgBox.value.scrollTop = msgBox.value.scrollHeight
}

function newSession() {
  messages.value = [{ role: 'bot', content: '新会话已开始，请提问。' }]
  sessionId.value = ''
}
</script>

<style scoped>
.ai-assistant { padding: 16px; height: calc(100vh - 100px); }
.chat-card { display: flex; flex-direction: column; height: 100%; }
.card-head { display: flex; justify-content: space-between; align-items: center; }
.chat-messages {
  flex: 1; overflow-y: auto; padding: 16px; background: #fafafa;
  border-radius: 4px; margin-bottom: 12px;
}
.msg { display: flex; gap: 10px; margin-bottom: 16px; }
.msg.user { flex-direction: row-reverse; }
.msg.user .bubble { background: #409eff; color: #fff; }
.msg .avatar {
  width: 36px; height: 36px; border-radius: 50%; display: flex; align-items: center;
  justify-content: center; background: #409eff; color: #fff; font-weight: 600; flex-shrink: 0;
}
.msg.bot .avatar { background: #67c23a; }
.msg .bubble {
  max-width: 75%; background: #fff; padding: 12px 16px; border-radius: 8px;
  box-shadow: 0 1px 2px rgba(0,0,0,0.06); line-height: 1.6;
}
.msg .bubble.typing { color: #999; font-style: italic; }
.chat-input { padding-top: 8px; }
.input-actions { margin-top: 8px; display: flex; gap: 8px; }
</style>
