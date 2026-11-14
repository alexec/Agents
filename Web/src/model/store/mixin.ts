/** Puts a slice's methods on a class's prototype, as the class's own methods: not enumerable, as in a class body (#5384). */
export function mixin(target: { prototype: object }, ...slices: object[]): void {
  for (const slice of slices) {
    for (const [name, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(slice))) {
      Object.defineProperty(target.prototype, name, { ...descriptor, enumerable: false });
    }
  }
}
