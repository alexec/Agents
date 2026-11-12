// The store and the local copy in one bundle, so both read the same signals (#4790).
export { Store } from "../src/model/store";
export { LocalCopy, MemoryCopyStore, overCaps, startLocalCopy, machineRef, sessionRef, transcriptsKept, entriesKept, writeAfter } from "../src/model/localCopy";
export { workRef, workKept } from "../src/model/localCopy";
