// One bundle for the signal and the helper, so they share the signals library (steadyNotice test).
export { signal } from "@preact/signals";
export { steadyNotice } from "../src/model/macHostNotice";
