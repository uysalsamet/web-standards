import DOMPurify from 'dompurify'

export function SafeHtml({ html }: { html: string }) {
  return <span dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(html) }} />
}
