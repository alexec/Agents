// A small shop's till, for the colour samples (041).
import { EventEmitter } from "node:events";

export interface Receipt {
  readonly item: string;
  readonly total: number;
  readonly at: Date;
}

type Listener = (receipt: Receipt) => void;

enum Currency {
  Pound = "GBP",
  Euro = "EUR",
}

const FLOAT: number = 150.0;
const MASK = 0xff as const;

/** Takes money and remembers it. */
export class Till<T extends Receipt = Receipt> extends EventEmitter {
  private receipts: T[] = [];
  public currency: Currency = Currency.Pound;

  constructor(private float: number = FLOAT) {
    super();
  }

  sell(item: string, price: number, count = 1): Receipt {
    if (count <= 0) {
      throw new RangeError(`cannot sell ${count} of ${item}`);
    }
    const receipt: Receipt = { item, total: price * count, at: new Date() };
    this.receipts.push(receipt as T);
    this.float += receipt.total;
    return receipt;
  }

  get takings(): number {
    return this.receipts.reduce((sum, r) => sum + r.total, 0);
  }

  onSold(listener: Listener): this {
    return this.on("sold", listener);
  }
}

export async function openTill(): Promise<Till> {
  const till = new Till();
  await Promise.resolve(null);
  return till;
}
