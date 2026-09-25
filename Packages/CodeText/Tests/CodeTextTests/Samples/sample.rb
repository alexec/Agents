# A small shop's till, for the colour samples (041).
require "bigdecimal"

FLOAT = BigDecimal("150.00")
MASK = 0xFF

Receipt = Struct.new(:item, :total, :count)

class Till
  attr_reader :receipts

  def initialize(float = FLOAT)
    @float = float
    @receipts = []
  end

  # Sells `count` of an item.
  def sell(item, price, count: 1)
    raise ArgumentError, "cannot sell #{count} of #{item}" if count <= 0

    receipt = Receipt.new(item, price * count, count)
    @receipts << receipt
    @float += receipt.total
    receipt
  end

  def takings = @receipts.sum(&:total)
end

till = Till.new
till.sell("coffee", BigDecimal("3.20"), count: 2)
puts till.takings, :done, nil, true, 1.5e3
