import request from './index'

export interface AiStatus {
  modelConfigured: boolean
  model: string | null
  knowledgeCount: number
  notes: string | string[]
}

export interface PriceSuggest {
  sku: string
  productName: string
  currentPrice: number | null
  costPrice: number | null
  suggestedPrice: number | null
  expectedMargin: number | null
  strategy: string
  currency: string
  basis: string
}

export interface ProductRecommend {
  sku: string
  productName: string
  score: number | null
  reason: string
  grossMargin?: number | null
  sales90d?: number
  basis?: string
  adopted?: boolean
  createTime?: string
}

export interface AnomalyOrder {
  id: string
  ruleKey: string
  orderNo: string
  platform: string
  orderAmount: number | null
  currency?: string
  riskScore: number
  rules: { code: string; message: string; score: number }[]
  anomalous: boolean
  confirmationStatus: 'PENDING' | 'CONFIRMED' | 'REJECTED'
  confirmedAt?: string
  basis: string
  amountComparison: string
}

export interface InventoryPrediction {
  sku: string
  productName: string
  availableStock: number | null
  lockedStock: number | null
  totalStock: number | null
  inventoryRecordExists: boolean
  predictedDemand: number | null
  replenishmentQty: number | null
  safetyStock: number | null
  stockoutDays: number | null
  observationDays: number
  salesDays: number
  dataStatus: string
  basis?: string
  forecast?: { date: string; demand: number | null }[]
}

export interface KnowledgeEntry {
  id: number | string
  title: string
  content: string
  createdAt?: string
}

export interface ChatSource {
  id?: number
  title: string
  content?: string
}

export interface ChatMessage {
  id?: number | string
  role: string
  content: string
  mode?: 'MODEL' | 'KNOWLEDGE'
  sources?: ChatSource[]
  createdAt?: string
}

export interface ChatSession {
  sessionId: string
  title?: string
  updatedAt?: string
}

export interface DescriptionRequest {
  sku: string
  language: 'zh' | 'en' | 'ja' | 'es'
  tone?: string
  keywords?: string[]
  requestId: string
}

export interface GeneratedDescription {
  id: number | string
  sku: string
  language: string
  description: string
  model: string
  createdAt: string
  saved: boolean
  productUpdated: boolean
  saveNote: string
}

export interface AiListQuery { limit?: number; offset?: number }

const prefix = '/ai-center'
const segment = (value: string | number) => encodeURIComponent(String(value))

export const aiCenterApi = {
  status: () => request.get<any, AiStatus>(`${prefix}/status`),
  pricing: (params: AiListQuery = {}) => request.get<any, PriceSuggest[]>(`${prefix}/pricing`, { params }),
  applyPrice: (sku: string, price: number, expectedPrice: number | null) =>
    request.post(`${prefix}/pricing/${segment(sku)}/apply`, { price, expectedPrice }),
  priceHistory: (sku: string) => request.get<any, any[]>(`${prefix}/pricing/${segment(sku)}/history`),
  recommendations: (params: AiListQuery = {}) => request.get<any, ProductRecommend[]>(`${prefix}/recommend`, { params }),
  refreshRecommendations: () => request.post(`${prefix}/recommend/refresh`),
  adoptRecommendation: (sku: string) => request.post(`${prefix}/recommend/${segment(sku)}/adopt`),
  adoptedRecommendations: (params: AiListQuery = {}) => request.get<any, ProductRecommend[]>(`${prefix}/recommend/adopted`, { params }),
  anomalies: (params: AiListQuery = {}) => request.get<any, AnomalyOrder[]>(`${prefix}/anomaly`, { params }),
  detectAnomalies: () => request.post<any, { scanned: number; [key: string]: unknown }>(`${prefix}/anomaly/detect`),
  confirmAnomaly: (id: string, status: string, expectedStatus: string, expectedRuleKey: string) =>
    request.post(`${prefix}/anomaly/${segment(id)}/confirm`, { status, expectedStatus, expectedRuleKey }),
  anomalyStats: () => request.get<any, { totalOrders: number; scanned: number; anomalous: number; pending: number; confirmed: number; rejected: number; truncated: boolean; basis: string }>(`${prefix}/anomaly/stats`),
  inventory: (params: AiListQuery = {}) => request.get<any, InventoryPrediction[]>(`${prefix}/inventory`, { params }),
  forecast: (sku: string) => request.get<any, InventoryPrediction>(`${prefix}/inventory/${segment(sku)}/forecast`),
  sessions: () => request.get<any, ChatSession[]>(`${prefix}/assistant/sessions`),
  chatHistory: (sessionId: string) => request.get<any, ChatMessage[]>(`${prefix}/assistant/history/${segment(sessionId)}`),
  chat: (data: { sessionId?: string; message: string; requestId: string }) =>
    request.post<any, { sessionId: string; reply: string; sources: ChatSource[]; mode: 'MODEL' | 'KNOWLEDGE'; id: number | string }>(`${prefix}/assistant/chat`, data, { timeout: 90000 }),
  knowledge: () => request.get<any, KnowledgeEntry[]>(`${prefix}/knowledge`),
  addKnowledge: (data: { title: string; content: string }) => request.post(`${prefix}/knowledge`, data),
  deleteKnowledge: (id: number | string) => request.delete(`${prefix}/knowledge/${segment(id)}`),
  generateDescription: (data: DescriptionRequest) =>
    request.post<any, GeneratedDescription>(`${prefix}/description/generate`, data, { timeout: 90000 }),
  descriptionHistory: () => request.get<any, GeneratedDescription[]>(`${prefix}/description/history`),
  saveDescription: (id: number | string) => request.post<any, GeneratedDescription>(`${prefix}/description/${segment(id)}/save`),
}

export function aiError(error: unknown): string {
  const response = error as { response?: { data?: { message?: string; error?: string } }; message?: string }
  return response?.response?.data?.message || response?.response?.data?.error || response?.message || '请求失败，请重试'
}

export function formatAmount(value: number | null | undefined, currency?: string): string {
  if (value == null) return '暂无数据'
  return `${Number(value).toFixed(2)}（${!currency || currency === 'UNSPECIFIED' ? '币种未设置' : currency}）`
}
