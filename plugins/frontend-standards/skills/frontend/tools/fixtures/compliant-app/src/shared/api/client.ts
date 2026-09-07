const DEFAULT_TIMEOUT_MS = 15_000

export async function apiRequest(path: string, init: RequestInit = {}): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => { controller.abort() }, DEFAULT_TIMEOUT_MS)
  try {
    return await fetch(path, { ...init, credentials: 'include', signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}
