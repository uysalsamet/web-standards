export interface RuntimeConfig { apiBaseUrl: string }

declare global {
  interface Window { __APP_CONFIG__?: unknown }
}

export function loadRuntimeConfig(): Readonly<RuntimeConfig> {
  const raw = window.__APP_CONFIG__
  if (typeof raw !== 'object' || raw === null || !('apiBaseUrl' in raw)) {
    throw new Error('Invalid runtime config (/config.js): apiBaseUrl')
  }
  return Object.freeze({ apiBaseUrl: String((raw as { apiBaseUrl: unknown }).apiBaseUrl) })
}
