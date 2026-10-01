// uses: ContentBlock
/**
 * ToolCallContent (ACP/ToolCallContent.swift): the protocol's shapes, as sent. Anything else is
 * written back as it came, so another `type` may arrive.
 */
export type ToolCallContent =
  | { type: "content"; content: ContentBlock }
  | { type: "diff"; path: string; newText: string; oldText?: string }
  | { type: "terminal"; terminalId: string };
