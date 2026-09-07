import { createBrowserRouter } from 'react-router-dom'

import { parkingRoutes } from '@/features/Parking'

export const router = createBrowserRouter([
  { path: '/', children: parkingRoutes },
])
