import UIKit
import ChargeCheckCore

/// A made-up invoice so new users can see what the app does. Its example prices are
/// never added to the user's price list, and it is never saved to Reports.
enum SampleInvoice {
    static let supplier = "Northgate Wholesale Ltd (sample)"

    static let prices: [PriceItem] = [
        PriceItem(id: "demo_1", cat: "Meat & Poultry", name: "Chicken Breast Fillets 9kg", price: 47.50, supplier: supplier, aliases: ["chicken breast fillets"]),
        PriceItem(id: "demo_2", cat: "Meat & Poultry", name: "Chicken Wings 10kg", price: 15.99, supplier: supplier, aliases: ["chicken wings"]),
        PriceItem(id: "demo_3", cat: "Oils & Sauces", name: "Vegetable Oil 20L", price: 24.99, supplier: supplier, aliases: ["vegetable oil"]),
        PriceItem(id: "demo_4", cat: "Bakery", name: "Burger Buns 4x12", price: 7.29, supplier: supplier, aliases: ["burger buns"]),
        PriceItem(id: "demo_5", cat: "Oils & Sauces", name: "Mayonnaise 10L", price: 24.99, supplier: supplier, aliases: ["mayonnaise"])
    ]

    static var image: UIImage? {
        guard let url = Bundle.main.url(forResource: "SampleInvoice", withExtension: "jpg"), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
