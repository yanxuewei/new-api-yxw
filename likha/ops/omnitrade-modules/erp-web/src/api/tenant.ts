import request from './index'

export const tenantApi = {
  list:        () => request.get('/tenant/list'),
  create:      (data: any) => request.post('/tenant', data),
  update:      (id: number, data: any) => request.put(`/tenant/${id}`, data),
  remove:      (id: number) => request.delete(`/tenant/${id}`),
  config:      (id: number) => request.get(`/tenant/${id}/config`),
  dashboard:   (id: number) => request.get(`/tenant/${id}/dashboard`),
  billing:     (id: number) => request.get(`/tenant/${id}/billing`),
  usage:       (id: number) => request.get(`/tenant/${id}/usage`),
  platforms:   (id: number) => request.get(`/tenant/${id}/platforms`),
  auth:        {
    login:    (data: any) => request.post<any, { token: string; user: any }>('/tenant/auth/login', data),
    register: (data: any) => request.post('/tenant/auth/register', data),
    logout:   () => request.post('/tenant/auth/logout'),
  },
}

export const reportApi = {
  list:    (params: any) => request.get('/report/list', { params }),
  generate: (data: any) => request.post<any, { url: string }>('/report/generate', data),
  download: (id: string) => request.get(`/report/${id}/download`, { responseType: 'blob' }),
  templates: () => request.get('/report/templates'),
}
