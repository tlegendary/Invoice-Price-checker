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

    /// The same invoice as a PDF with real text in it, like the ones suppliers email
    /// (the cloud check reads it with "-demoScan pdf").
    static func textPDF() -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            func put(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 10, bold: Bool = false, right: Bool = false) {
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                let string = text as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                let width = string.size(withAttributes: attributes).width
                string.draw(at: CGPoint(x: right ? x - width : x, y: y), withAttributes: attributes)
            }
            put("NORTHGATE WHOLESALE LTD", 160, 40, size: 20, bold: true)
            put("Invoice No", 400, 100, bold: true); put("10452", 490, 100)
            put("Invoice Date", 400, 116, bold: true); put("06/11/2026", 490, 116)
            put("Quantity", 30, 170, bold: true); put("Description", 90, 170, bold: true)
            put("Unit Price", 330, 170, bold: true, right: true); put("Net Amt", 420, 170, bold: true, right: true)
            put("VAT %", 480, 170, bold: true, right: true); put("VAT", 540, 170, bold: true, right: true)
            let lines: [(String, String, String, String)] = [
                ("3.00", "CHICKEN BREAST FILLETS 9KG", "50.99", "152.97"),
                ("2.00", "CHICKEN WINGS 10KG", "15.99", "31.98"),
                ("4.00", "VEGETABLE OIL 20L", "26.50", "106.00"),
                ("5.00", "BURGER BUNS 4X12", "7.29", "36.45"),
                ("2.00", "MAYONNAISE 10L", "24.99", "49.98")
            ]
            for (index, line) in lines.enumerated() {
                let y = 192 + CGFloat(index) * 20
                put(line.0, 30, y); put(line.1, 90, y)
                put(line.2, 330, y, right: true); put(line.3, 420, y, right: true)
                put("0.00", 480, y, right: true); put("0.00", 540, y, right: true)
            }
            put("Total Net Amount", 380, 320, bold: true); put("377.38", 540, 320, right: true)
            put("Total Tax Amount", 380, 336, bold: true); put("0.00", 540, 336, right: true)
            put("Invoice Total", 380, 352, bold: true); put("377.38", 540, 352, right: true)
        }
    }

    static var image: UIImage? {
        guard let url = Bundle.main.url(forResource: "SampleInvoice", withExtension: "jpg"), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
