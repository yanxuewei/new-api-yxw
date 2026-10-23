import { createRouter, createWebHistory, RouteRecordRaw } from 'vue-router'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    redirect: '/dashboard'
  },
  {
    path: '/login',
    component: () => import('@/views/Login.vue'),
    meta: { title: '登录' }
  },
  {
    path: '/register',
    component: () => import('@/views/Register.vue'),
    meta: { title: '注册' }
  },
  {
    path: '/layout',
    component: () => import('@/layout/index.vue'),
    children: [
      {
        path: '/dashboard',
        component: () => import('@/views/Dashboard.vue'),
        meta: { title: '数据看板' }
      },
      {
        path: '/order',
        component: () => import('@/views/order/OrderList.vue'),
        meta: { title: '订单管理' }
      },
      {
        path: '/order/detail/:id',
        component: () => import('@/views/order/index.vue'),
        meta: { title: '订单详情' }
      },
      {
        path: '/product',
        component: () => import('@/views/product/index.vue'),
        meta: { title: '商品管理' }
      },
      {
        path: '/platform',
        component: () => import('@/views/platform/index.vue'),
        meta: { title: '平台配置' }
      },
      {
        path: '/inventory',
        component: () => import('@/views/inventory/index.vue'),
        meta: { title: '库存管理' }
      },
      {
        path: '/inventory-alert',
        component: () => import('@/views/inventory-alert/InventoryAlert.vue'),
        meta: { title: '库存预警' }
      },
      {
        path: '/warehouse',
        component: () => import('@/views/warehouse/index.vue'),
        meta: { title: '仓库管理' }
      },
      {
        path: '/logistics',
        component: () => import('@/views/logistics/Logistics.vue'),
        meta: { title: '物流管理' }
      },
      {
        path: '/customer',
        component: () => import('@/views/customer/CustomerList.vue'),
        meta: { title: '客户管理' }
      },
      {
        path: '/supplier',
        component: () => import('@/views/supplier/SupplierList.vue'),
        meta: { title: '供应商管理' }
      },
      {
        path: '/finance',
        component: () => import('@/views/finance/index.vue'),
        meta: { title: '财务管理' }
      },
      {
        path: '/user',
        component: () => import('@/views/user/index.vue'),
        meta: { title: '用户管理' }
      },

      // ====== 新增模块（issue #4 补全）======
      // 数据分析
      { path: '/analytics',           component: () => import('@/views/analytics/index.vue'),       meta: { title: '数据分析看板' } },

      // AI 智能中心
      { path: '/ai/assistant',        component: () => import('@/views/ai/Assistant.vue'),           meta: { title: 'AI 客服助手' } },
      { path: '/ai/pricing',          component: () => import('@/views/ai/Pricing.vue'),             meta: { title: '智能定价' } },
      { path: '/ai/recommend',        component: () => import('@/views/ai/Recommend.vue'),           meta: { title: '选品推荐' } },
      { path: '/ai/anomaly',          component: () => import('@/views/ai/Anomaly.vue'),             meta: { title: '订单异常检测' } },
      { path: '/ai/description',      component: () => import('@/views/ai/Description.vue'),         meta: { title: '商品描述生成' } },
      { path: '/ai/inventory-predict',component: () => import('@/views/ai/InventoryPredict.vue'),     meta: { title: '库存预测' } },

      // 采购管理
      { path: '/purchase',            component: () => import('@/views/purchase/index.vue'),         meta: { title: '采购订单' } },

      // 报表中心
      { path: '/report',              component: () => import('@/views/report/index.vue'),           meta: { title: '报表中心' } },

      // 社交电商
      { path: '/social',              component: () => import('@/views/social/index.vue'),           meta: { title: '社交电商中心' } },

      // 租户与系统
      { path: '/tenant',              component: () => import('@/views/tenant/index.vue'),           meta: { title: '租户管理' } },
    ]
  },
  // 404
  { path: '/:pathMatch(.*)*', redirect: '/dashboard' }
]

const router = createRouter({
  history: createWebHistory(),
  routes
})

// 路由守卫
router.beforeEach((to, from, next) => {
  const token = localStorage.getItem('token')

  if (to.path !== '/login' && to.path !== '/register' && !token) {
    next('/login')
  } else if (to.path === '/login' && token) {
    next('/dashboard')
  } else {
    next()
  }
})

export default router
