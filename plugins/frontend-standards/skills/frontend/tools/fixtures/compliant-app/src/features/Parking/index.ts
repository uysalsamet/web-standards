import type { RouteObject } from 'react-router-dom'

export { ParkingList } from './components/ParkingList'

export const parkingRoutes: RouteObject[] = [
  { path: 'parkings', lazy: () => import('./components/ParkingList').then((m) => ({ Component: m.ParkingList })) },
]
