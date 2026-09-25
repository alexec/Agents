// A small shop's till, for the colour samples (041).
import { EventEmitter } from "node:events";

const FLOAT = 150.0;
const MASK = 0xff;

/**
 * Takes money and remembers it.
 */
export class Till extends EventEmitter {
  #receipts = [];

  constructor(float = FLOAT) {
    super();
    this.float = float;
  }

  sell(item, price, count = 1) {
    if (count <= 0) throw new RangeError(`cannot sell ${count} of ${item}`);
    const receipt = { item, total: price * count, at: new Date() };
    this.#receipts.push(receipt);
    this.float += receipt.total;
    this.emit("sold", receipt);
    return receipt;
  }

  get takings() {
    return this.#receipts.reduce((sum, r) => sum + r.total, 0);
  }
}

export const Badge = ({ till }) => (
  <span className="badge" title={`£${till.takings}`}>
    {till.takings > 100 ? "busy" : "quiet"}
  </span>
);

const till = new Till();
till.on("sold", (r) => console.log("sold", r.item, r.total, /\d+/.test(String(r.total))));
till.sell("coffee", 3.2, 2);
console.log(till.takings, null, undefined, true);
