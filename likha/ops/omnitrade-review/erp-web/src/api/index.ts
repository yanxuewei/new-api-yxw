import axios, { AxiosInstance } from 'axios'
import { ElMessage } from 'element-plus'

const request: AxiosInstance = axios.create({
  baseURL: '/api',
  timeout: 15000
})

request.interceptors.request.use(config => {
  const token = localStorage.getItem('token')
  if (token) {
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

request.interceptors.response.use(
  response => response.data,
  error => {
    if (error.response && error.response.status === 401) {
      // 未登录，跳登录页
      if (window.location.pathname !== '/login') {
        localStorage.removeItem('token')
        window.location.href = '/login'
      }
    } else {
      ElMessage.error(error.response?.data?.message || error.message || '请求失败')
    }
    return Promise.reject(error)
  }
)

/** 统一网关路径，所有微服务通过 erp-gateway 路由转发 */
export const GW = {
  auth:        '/auth',       // erp-user-service
  order:       '/order',      // erp-order-service
  product:     '/product',    // erp-product-service
  platform:    '/platform',   // erp-platform-service
  inventory:   '/inventory',  // erp-inventory-service
  warehouse:   '/warehouse',  // erp-warehouse-service
  customer:    '/customer',   // erp-customer-service
  supplier:    '/supplier',   // erp-supplier-service
  finance:     '/finance',    // erp-finance-service
  user:        '/user',       // 用户管理
  // AI / 新模块
  ai:          '/ai',         // erp-ai-assistant-service（兼容）
  v1Anomaly:   '/v1/anomaly', // erp-anomaly-detection-service
  v1Recommend: '/v1/recommend',// erp-product-recommendation-service
  purchase:    '/purchase',   // erp-purchase-service
  analytics:   '/analytics',  // erp-analytics-service
  report:      '/report',     // erp-reporting-service
  social:      '/social',     // erp-social-commerce-service
  tenant:      '/tenant',     // erp-tenant-service
}

export interface PageReq {
  page?: number
  size?: number
  keyword?: string
}

export interface PageResp<T> {
  total: number
  list: T[]
  page?: number
  size?: number
}

export default request
