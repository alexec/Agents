// An issue's or a pull request's title as the forge draws it: its code spans as code, the rest as
// it was written (forgeMarkdown.ts).
import { titleParts } from "../model/forgeMarkdown";

export function ForgeTitle({ text }: { text: string }) {
  return <>{titleParts(text).map((part, i) => part.code ? <code key={i}>{part.text}</code> : part.text)}</>;
}
