/* A small shop's till, for the colour samples (041). */
#include <stdio.h>
#include <stdlib.h>

#define FLOAT 150.0
#define MASK 0xFF

typedef struct {
    const char *item;
    double total;
    int count;
} Receipt;

// Sells `count` of an item and returns the receipt.
static Receipt sell(const char *item, double price, int count) {
    if (count <= 0) {
        fprintf(stderr, "cannot sell %d of %s\n", count, item);
        exit(1);
    }
    Receipt receipt = { item, price * count, count };
    return receipt;
}

int main(void) {
    Receipt r = sell("coffee", 3.20, 2);
    printf("%s: %.2f (%c)\n", r.item, r.total + FLOAT, 'x');
    return 0;
}
