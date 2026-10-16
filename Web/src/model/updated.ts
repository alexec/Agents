// When the Needs You count was last true, said beside it while the link is lost (#1163): the
// Remote's SmartHeading.updated and the widget's line, in the page's words.

/** "Updated 14:02" the same day, "Updated Tue 14:02" before. */
export function updatedLine(at: number, now: number = Date.now()): string {
  const date = new Date(at);
  const time = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  if (date.toDateString() === new Date(now).toDateString()) return `Updated ${time}`;
  return `Updated ${date.toLocaleDateString(undefined, { weekday: "short" })} ${time}`;
}
