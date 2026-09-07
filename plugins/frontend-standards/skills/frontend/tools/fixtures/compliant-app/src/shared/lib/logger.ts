type Level = 'debug' | 'info' | 'warn' | 'error'

export function log(level: Level, message: string, context?: Record<string, unknown>): void {
  if (import.meta.env.DEV) {
    console[level](message, context)
  }
}
