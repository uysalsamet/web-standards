import maplibregl from 'maplibre-gl'
import { useEffect, useRef } from 'react'

export function MapContainer({ styleUrl }: { styleUrl: string }) {
  const hostRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const map = new maplibregl.Map({ container: host, style: styleUrl })
    return () => { map.remove() }
  }, [styleUrl])

  return <div ref={hostRef} className="h-full w-full" />
}
