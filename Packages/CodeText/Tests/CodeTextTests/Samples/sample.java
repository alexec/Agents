// A small shop's till, for the colour samples (041).
package shop;

import java.util.ArrayList;
import java.util.List;

/** Takes money and remembers it. */
public final class Till {
    public static final double FLOAT = 150.0;
    private static final int MASK = 0xFF;

    public record Receipt(String item, double total, int count) {}

    private double float_ = FLOAT;
    private final List<Receipt> receipts = new ArrayList<>();

    public Receipt sell(String item, double price, int count) {
        if (count <= 0) {
            throw new IllegalArgumentException("cannot sell " + count + " of " + item);
        }
        var receipt = new Receipt(item, price * count, count);
        receipts.add(receipt);
        float_ += receipt.total();
        return receipt;
    }

    @Override
    public String toString() {
        return String.format("Till(%.2f, %d receipts)", float_, receipts.size());
    }

    public static void main(String[] args) {
        var till = new Till();
        till.sell("coffee", 3.20, 2);
        System.out.println(till + " " + MASK + " " + true + " " + null);
    }
}
