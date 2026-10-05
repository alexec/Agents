// The plan a plan approval asks about (#256): ToolCall.isPlanApproval, planFile and planText
// (Model/PermissionRequest.swift), ported by hand and held to Fixtures/web/plan.
import type { ToolCall } from "../protocol/generated";

/** ShownFile.markdownExtensions. */
const markdown = new Set(["md", "markdown", "mdown", "mkd"]);

/** A path made plain, as URL.standardizedFileURL makes it: no `.`, `..` or doubled slashes. */
function standardized(path: string): string {
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return "/" + parts.join("/");
}

/**
 * The plan being approved: as a file when the runtime wrote it to an absolute Markdown path
 * (`rawInput.planFilePath`), else as its text (`rawInput.plan`); null when this is not a plan.
 */
export function planOf(call: ToolCall): { file?: string; text?: string } | null {
  if (call.kind !== "switch_mode") return null;
  const input = call.rawInput as Record<string, unknown> | undefined;
  const plan: { file?: string; text?: string } = {};
  const path = typeof input?.planFilePath === "string" ? input.planFilePath.trim() : "";
  if (path.startsWith("/")) {
    const file = standardized(path);
    const name = file.split("/").pop() ?? "";
    const dot = name.lastIndexOf(".");
    if (dot > 0 && markdown.has(name.slice(dot + 1).toLowerCase())) plan.file = file;
  }
  if (typeof input?.plan === "string" && input.plan.trim() !== "") plan.text = input.plan;
  return plan;
}
