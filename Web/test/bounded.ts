// What bounded.test.mjs reads, in one bundle, so its effects watch the store's own signals.
export { Work, Store, archivedPage } from "../src/model/store";
export { keepingTurns } from "../src/model/turns";
export { effect } from "@preact/signals";
