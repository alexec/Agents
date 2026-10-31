// A value to pick for what a page shows (#2142): Reports' Range, By and Scope, a chart's Range. A native
// select drawn as a web button with its name before it ("Range: Last 7 days ▾"), in place of the iOS
// segmented control. A pane switch is tabs (`.tabs`, role tablist) instead.
export function Choice<T extends string>({ label, value, options, onPick, title, disabled, class: cls }: {
  label: string;
  value: T;
  /** Each value and the words it shows; a third, when given, is what a screen reader says. */
  options: readonly (readonly [T, string] | readonly [T, string, string])[];
  onPick: (value: T) => void;
  title?: string;
  disabled?: boolean;
  class?: string;
}) {
  return (
    <label class={`choice${cls ? ` ${cls}` : ""}`} title={title}>
      <span class="choice-name">{label}</span>
      <select value={value} disabled={disabled} onChange={(e) => onPick((e.currentTarget as HTMLSelectElement).value as T)}>
        {options.map(([v, words, spoken]) => <option key={v} value={v} aria-label={spoken}>{words}</option>)}
      </select>
    </label>
  );
}
