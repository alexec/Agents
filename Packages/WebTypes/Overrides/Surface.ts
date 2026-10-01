/** Surface (Attention/Surface.swift): a tagged object, `{ mac: {} }` or `{ device: "<uuid>" }`. */
export type Surface = { mac: Record<string, never> } | { device: UUID };
