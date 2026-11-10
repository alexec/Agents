// A secret's line (#4159): "On 3 machines · Added 27 d ago · Used 2 h ago", each part with its date and time in
// `title`, as the window's SecretInfoLine (Shared/UI/UserScope/SecretsPane.swift) has them on hover.
import type { Part } from "../model/secretInfo";

export function SecretInfoLine({ parts, class: kind = "hint" }: { parts: readonly Part[]; class?: string }) {
  return (
    <span class={kind}>
      {parts.map((part, i) => (
        <span key={i}>{i > 0 && " · "}<span title={part.help}>{part.text}</span></span>
      ))}
    </span>
  );
}
