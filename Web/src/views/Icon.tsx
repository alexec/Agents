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
import ellipsis from "lucide:ellipsis";
import file from "lucide:file";
import fileQuestionMark from "lucide:file-question-mark";
import fileText from "lucide:file-text";
import folder from "lucide:folder";
import gitPullRequest from "lucide:git-pull-request";
import globe from "lucide:globe";
import hand from "lucide:hand";
import image from "lucide:image";
import info from "lucide:info";
import layers from "lucide:layers";
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
import plus from "lucide:plus";
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
import wifiOff from "lucide:wifi-off";
import folderSearch from "lucide:folder-search";
import userX from "lucide:user-x";
import history from "lucide:history";
import coins from "lucide:coins";
import building2 from "lucide:building-2";
import zap from "lucide:zap";
import pencil from "lucide:pencil";
import search from "lucide:search";
import brain from "lucide:brain";
import hammer from "lucide:hammer";
import squareArrowRight from "lucide:square-arrow-right";
import scrollText from "lucide:scroll-text";
import messageCircleQuestionMark from "lucide:message-circle-question-mark";
import undo2 from "lucide:undo-2";
import clockFading from "lucide:clock-fading";
import circleAlert from "lucide:circle-alert";
import gitBranch from "lucide:git-branch";
import gitMerge from "lucide:git-merge";
import cloud from "lucide:cloud";
import hash from "lucide:hash";
import squareDot from "lucide:square-dot";
import squarePlus from "lucide:square-plus";
import squareMinus from "lucide:square-minus";
import arrowRight from "lucide:arrow-right";
import shieldCheck from "lucide:shield-check";
import hourglass from "lucide:hourglass";
import pointer from "lucide:pointer";
import calendar from "lucide:calendar";
import loaderCircle from "lucide:loader-circle";
import cornerDownRight from "lucide:corner-down-right";

type Node = [string, Record<string, string>];

const icons = {
  "alarm-clock": alarmClock, archive, "arrow-down": arrowDown, "arrow-up": arrowUp, "arrow-up-to-line": arrowUpToLine,
  "audio-waveform": audioWaveform, ban, bell, "bell-off": bellOff, "chart-column": chartColumn, check,
  "chevron-down": chevronDown, "chevron-left": chevronLeft, "chevron-right": chevronRight, "chevron-up": chevronUp,
  circle, "circle-check": circleCheck, "circle-dashed": circleDashed, "circle-dot": circleDot, "circle-help": circleHelp,
  "circle-pause": circlePause, "circle-stop": circleStop, "circle-x": circleX, clock, dot, ellipsis, file,
  "file-question-mark": fileQuestionMark, "file-text": fileText, folder, "git-pull-request": gitPullRequest, globe, hand,
  image, info, layers, "layout-grid": layoutGrid, "list-ordered": listOrdered, lock, mail,
  "message-circle": messageCircle, "messages-square": messagesSquare, "octagon-alert": octagonAlert, paperclip,
  phone, play, plug, plus, radio, "rotate-cw": rotateCw, sparkles, "square-check": squareCheck, "square-pen": squarePen,
  "square-terminal": squareTerminal, sun, target, "trash-2": trash2, "triangle-alert": triangleAlert, workflow, x, zap,
  "wifi-off": wifiOff, "folder-search": folderSearch, "user-x": userX, history, coins, "building-2": building2,
  pencil, search, brain, hammer, "square-arrow-right": squareArrowRight, "scroll-text": scrollText, "message-circle-question-mark": messageCircleQuestionMark, "undo-2": undo2, "clock-fading": clockFading, "circle-alert": circleAlert,
  "git-branch": gitBranch, "git-merge": gitMerge, cloud, hash, "square-dot": squareDot, "square-plus": squarePlus, "square-minus": squareMinus, "arrow-right": arrowRight, "shield-check": shieldCheck, hourglass, pointer, calendar, "corner-down-right": cornerDownRight, "loader-circle": loaderCircle,
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
  "⎇": "git-branch", "⑂": "git-merge", "☁": "cloud", "#": "hash", "⊡": "square-dot", "⊞": "square-plus",
  "⊟": "square-minus", "⇥": "arrow-right", "↺": "undo-2", "🛡": "shield-check", "⧗": "hourglass", "☝": "pointer",
  "📅": "calendar", "❞": "corner-down-right", "⧉": "clock", "…": "ellipsis",
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
