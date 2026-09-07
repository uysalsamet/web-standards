import { apiRequest } from '@/shared/api/client'

export async function fetchParkings(): Promise<unknown> {
  const response = await apiRequest('/api/parkings')
  return response.json()
}
