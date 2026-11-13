import type { ElicitationRequest } from "../protocol/generated";

/**
 * A question card's head (#5028): its title and the line under it. A form that asks one
 * question with choices, as the host's confirm cards do ("Start a session on devbox?",
 * workspacetools.go personSaysYes), takes that question as its title: the form's own title
 * ("Claude wants to…") says only who asks, and the asker line says that already. Any other
 * card keeps the form's title, then its message when that says more (the window's
 * ElicitationRequest.title and message).
 */
export function askHead(request: ElicitationRequest): { title: string; message?: string } {
  if (!("form" in request.mode)) return { title: "The agent wants you to open a page" };
  const schema = request.mode.form._0;
  const formTitle = schema.title ?? request.message ?? "The agent needs something";
  const only = schema.properties.length === 1 ? schema.properties[0] : undefined;
  const question = only && "string" in only.kind && only.kind.string.choices?.length && !request.secret && !request.handOff
    ? only.title?.trim() : undefined;
  const title = question || formTitle;
  const message = request.message;
  return message && message !== title && message !== formTitle ? { title, message } : { title };
}
