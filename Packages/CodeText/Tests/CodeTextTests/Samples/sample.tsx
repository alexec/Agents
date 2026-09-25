// A small shop's till badge, for the colour samples (041).
import React, { useState } from "react";

interface BadgeProps {
  takings: number;
  label?: string;
}

export function Badge({ takings, label = "Takings" }: BadgeProps): JSX.Element {
  const [open, setOpen] = useState<boolean>(false);
  const busy = takings > 100;
  return (
    <button className={busy ? "badge busy" : "badge"} onClick={() => setOpen(!open)}>
      {label}: £{takings.toFixed(2)}
      {open && <span aria-hidden="true">▾</span>}
    </button>
  );
}
