//! A small shop's till, for the colour samples (041).
use std::fmt;

const FLOAT: f64 = 150.0;
const MASK: u8 = 0xFF;

#[derive(Debug, Clone, PartialEq)]
pub struct Receipt {
    pub item: String,
    pub total: f64,
}

pub struct Till {
    float: f64,
    receipts: Vec<Receipt>,
}

impl Till {
    /// Opens a till with the usual float.
    pub fn new() -> Self {
        Till { float: FLOAT, receipts: Vec::new() }
    }

    pub fn sell(&mut self, item: &str, price: f64, count: u32) -> Result<&Receipt, String> {
        if count == 0 {
            return Err(format!("cannot sell nothing of {item}"));
        }
        self.receipts.push(Receipt { item: item.to_owned(), total: price * count as f64 });
        self.float += price * count as f64;
        Ok(self.receipts.last().unwrap())
    }
}

impl fmt::Display for Till {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Till({}, {} receipts)", self.float, self.receipts.len())
    }
}

fn main() {
    let mut till = Till::new();
    let _ = till.sell("coffee", 3.20, 2);
    println!("{till} {}", MASK);
}
