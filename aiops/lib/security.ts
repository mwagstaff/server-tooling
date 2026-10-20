import {timingSafeEqual, createHash} from 'node:crypto';

export function equal(a: string, b: string): boolean {
  return timingSafeEqual(createHash('sha256').update(a).digest(), createHash('sha256').update(b).digest());
}

export function redact(value: unknown): string {
  let text = typeof value === 'string' ? value : JSON.stringify(value);
  // Exact installed credentials first, followed by common credential and PII forms.
  for (const [name, secret] of Object.entries(process.env)) {
    if (/KEY|TOKEN|SECRET|PASSWORD|URI|SESSION/i.test(name) && secret && secret.length >= 8)
      text = text.split(secret).join('[redacted]');
  }
  return text
    .replace(/-----BEGIN [\s\S]*?PRIVATE KEY-----[\s\S]*?-----END [\s\S]*?PRIVATE KEY-----/g, '[private key redacted]')
    .replace(/(mongodb(?:\+srv)?:\/\/|https?:\/\/)[^\s/"@]+:[^\s/"@]+@/gi, '$1[redacted]@')
    .replace(/\b(?:sk-[\w-]{12,}|sk-ant-[\w-]{12,}|eyJ[\w-]{15,}\.[\w-]+\.[\w-]+)\b/g, '[token redacted]')
    .replace(/((?:authorization|api[_-]?key|password|secret|access[_-]?token|cookie)\s*["']?\s*[:=]\s*["']?)(?:Bearer\s+|Token\s+)?[^"'\s,;}]+/gi, '$1[redacted]')
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[email redacted]')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '[ip redacted]');
}

export async function boundedBody(response: Response, limit = 128 * 1024): Promise<string> {
  if (!response.body) return '';
  const reader = response.body.getReader();
  let size = 0;
  const chunks: Uint8Array[] = [];
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) throw new Error('Response exceeds size limit');
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  return Buffer.concat(chunks).toString('utf8');
}
