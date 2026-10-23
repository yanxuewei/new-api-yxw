import request from './index'

export const socialApi = {
  tiktokShop: {
    list:   (params: any) => request.get('/social/tiktok-shop', { params }),
    sync:   () => request.post('/social/tiktok-shop/sync'),
  },
  liveStream: {
    list:   (params: any) => request.get('/social/live-streams', { params }),
    create: (data: any)   => request.post('/social/live-streams', data),
    start:  (id: number)  => request.post(`/social/live-streams/${id}/start`),
    end:    (id: number)  => request.post(`/social/live-streams/${id}/end`),
  },
  cooperation: {
    list:    (params: any) => request.get('/social/cooperations', { params }),
    invite:  (data: any)   => request.post('/social/cooperations', data),
  },
  influencer: {
    list:   (params: any) => request.get('/social/influencers', { params }),
    detail: (id: number)  => request.get(`/social/influencers/${id}`),
  },
  douyinShop: {
    list: (params: any) => request.get('/social/douyin-shop', { params }),
    sync: () => request.post('/social/douyin-shop/sync'),
  },
}
