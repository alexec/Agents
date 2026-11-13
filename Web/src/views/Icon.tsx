// Paper v2's one icon set (#4996; specs/4926-paper-v2/spec.md, Icons): Lucide at a 1.5 stroke, the
// same icon for the same meaning as the Mac and the Remote (design/icons.json). Web/lucide.mjs puts
// each icon's elements in the bundle at build time; only the icons named here are in it.
import type { JSX } from "preact";
import alarmClock from "lucide:alarm-clock";
import archive from "lucide:archive";
import arrowDown from "lucide:arrow-down";
import arrowUp from "lucide:arrow-up";
import arrowUpToLine from "lucide:arrow-up-to-line";
import audioWaveform from "lucide:audio-waveform";
import ban from "lucide:ban";
import bell from "lucide:bell";
import bellOff from "lucide:bell-off";
import chartColumn from "lucide:chart-column";
import check from "lucide:check";
import chevronDown from "lucide:chevron-down";
import chevronLeft from "lucide:chevron-left";
import chevronRight from "lucide:chevron-right";
import chevronUp from "lucide:chevron-up";
import circle from "lucide:circle";
import circleCheck from "lucide:circle-check";
import circleDashed from "lucide:circle-dashed";
import circleDot from "lucide:circle-dot";
import circleHelp from "lucide:circle-help";
import circlePause from "lucide:circle-pause";
import circleStop from "lucide:circle-stop";
import circleX from "lucide:circle-x";
import clock from "lucide:clock";
import dot from "lucide:dot";
import file from "lucide:file";
import fileQuestionMark from "lucide:file-question-mark";
import fileText from "lucide:file-text";
import folder from "lucide:folder";
import gitPullRequest from "lucide:git-pull-request";
import globe from "lucide:globe";
import hand from "lucide:hand";
import image from "lucide:image";
import info from "lucide:info";
import layoutGrid from "lucide:layout-grid";
import listOrdered from "lucide:list-ordered";
import lock from "lucide:lock";
import mail from "lucide:mail";
import messageCircle from "lucide:message-circle";
import messagesSquare from "lucide:messages-square";
import octagonAlert from "lucide:octagon-alert";
import paperclip from "lucide:paperclip";
import phone from "lucide:phone";
import play from "lucide:play";
import plug from "lucide:plug";
import radio from "lucide:radio";
import rotateCw from "lucide:rotate-cw";
import sparkles from "lucide:sparkles";
import squareCheck from "lucide:square-check";
import squarePen from "lucide:square-pen";
import squareTerminal from "lucide:square-terminal";
import sun from "lucide:sun";
import target from "lucide:target";
import trash2 from "lucide:trash-2";
import triangleAlert from "lucide:triangle-alert";
import workflow from "lucide:workflow";
import x from "lucide:x";
import zap from "lucide:zap";

type Node = [string, Record<string, string>];

const icons = {
  "alarm-clock": alarmClock, archive, "arrow-down": arrowDown, "arrow-up": arrowUp, "arrow-up-to-line": arrowUpToLine,
  "audio-waveform": audioWaveform, ban, bell, "bell-off": bellOff, "chart-column": chartColumn, check,
  "chevron-down": chevronDown, "chevron-left": chevronLeft, "chevron-right": chevronRight, "chevron-up": chevronUp,
  circle, "circle-check": circleCheck, "circle-dashed": circleDashed, "circle-dot": circleDot, "circle-help": circleHelp,
  "circle-pause": circlePause, "circle-stop": circleStop, "circle-x": circleX, clock, dot, file,
  "file-question-mark": fileQuestionMark, "file-text": fileText, folder, "git-pull-request": gitPullRequest, globe, hand,
  image, info, "layout-grid": layoutGrid, "list-ordered": listOrdered, lock, mail,
  "message-circle": messageCircle, "messages-square": messagesSquare, "octagon-alert": octagonAlert, paperclip,
  phone, play, plug, radio, "rotate-cw": rotateCw, sparkles, "square-check": squareCheck, "square-pen": squarePen,
  "square-terminal": squareTerminal, sun, target, "trash-2": trash2, "triangle-alert": triangleAlert, workflow, x, zap,
} satisfies Record<string, Node[]>;

export type IconName = keyof typeof icons;

/** One Lucide icon, the size of the text around it and its colour (ink, or a state's tint from its class).
 *  It is never the only sign of a state: a word goes with it, as a title, a label or text. */
export function Icon({ name, class: className, title }: { name: IconName; class?: string; title?: string }): JSX.Element {
  return (
    <svg class={className ? `lucide ${className}` : "lucide"} viewBox="0 0 24 24" width="1em" height="1em" fill="none"
      stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      {title !== undefined && <title>{title}</title>}
      {(icons[name] as Node[]).map(([tag, attributes]) => h(tag, attributes))}
    </svg>
  );
}

function h(tag: string, attributes: Record<string, string>): JSX.Element {
  const Tag = tag as "path";
  return <Tag {...attributes} />;
}

/** The icon for a glyph the model still names a mark by (✓, ⚠, ◷ …), by its meaning, or the glyph
 *  itself when it has no icon (a letter, a count, a key such as ⌘). */
const byGlyph: Record<string, IconName> = {
  "✓": "check", "✔": "check", "☑": "square-check", "✕": "x", "✗": "circle-x", "×": "x",
  "⚠": "triangle-alert", "!": "circle-help", "ⓘ": "info", "ℹ": "info", "⛔": "octagon-alert",
  "✋": "hand", "⏸": "circle-pause", "■": "circle-stop", "▶": "play", "↻": "rotate-cw", "⟳": "workflow",
  "▣": "archive", "🗃": "archive", "◷": "clock", "⏰": "alarm-clock", "⊘": "ban", "◉": "circle-dot", "◎": "target",
  "●": "dot", "○": "circle", "◌": "circle-dashed", "◐": "circle-dashed", "✦": "sparkles", "≡": "list-ordered",
  "☰": "list-ordered", "▤": "file-text", "◍": "message-circle", "⇄": "git-pull-request", "▦": "layout-grid",
  "✎": "square-pen", "📄": "file", "🗎": "file", "📁": "folder", "🖼": "image", "📎": "paperclip", "🗑": "trash-2",
  "🔒": "lock", "🔔": "bell", "🔕": "bell-off", "🌐": "globe", "📝": "file-text", "❓": "file-question-mark",
  "📊": "chart-column", "🔀": "workflow", "✉": "mail", "✆": "phone", "💬": "messages-square", "⚡": "zap",
  "☀": "sun", "↑": "arrow-up", "↓": "arrow-down", "⤒": "arrow-up-to-line", "▾": "chevron-down", "⌄": "chevron-down",
  "▸": "chevron-right", "›": "chevron-right", "‹": "chevron-left", "▴": "chevron-up", "⌁": "audio-waveform",
};

export function iconForGlyph(glyph: string): IconName | undefined {
  return byGlyph[glyph.replace(/[︎️]/g, "").trim()];
}

/** A mark the model names by a glyph: its icon (see `iconForGlyph`), or the glyph as text. */
export function Glyph({ of, class: className }: { of: string; class?: string }): JSX.Element {
  const name = iconForGlyph(of);
  if (name) return <Icon name={name} {...(className ? { class: className } : {})} />;
  return className ? <span class={className} aria-hidden="true">{of}</span> : <>{of}</>;
}
