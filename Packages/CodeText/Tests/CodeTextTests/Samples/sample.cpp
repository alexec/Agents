// A small shop's till, for the colour samples (041).
#include <iostream>
#include <string>
#include <vector>

namespace shop {

struct Receipt {
    std::string item;
    double total;
};

class Till {
public:
    explicit Till(double float_ = 150.0) : float_(float_) {}

    const Receipt& sell(const std::string& item, double price, int count = 1) {
        if (count <= 0) throw std::invalid_argument("cannot sell nothing");
        receipts_.push_back({item, price * count});
        float_ += receipts_.back().total;
        return receipts_.back();
    }

    template <typename F> void each(F&& f) const {
        for (const auto& r : receipts_) f(r);
    }

private:
    double float_;
    std::vector<Receipt> receipts_;
};

}  // namespace shop

int main() {
    shop::Till till;
    till.sell("coffee", 3.20, 2);
    till.each([](const auto& r) { std::cout << r.item << " " << r.total << '\n'; });
    return 0;
}
