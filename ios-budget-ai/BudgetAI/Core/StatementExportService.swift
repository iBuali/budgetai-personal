import Foundation
import UIKit
import PDFKit

// MARK: - Statement Export Service

enum StatementExportService {

    // MARK: - Excel Export (HTML / XML Spreadsheet readable by Microsoft Excel, Numbers, and Google Sheets)

    static func createExcelData(
        transactions: [MoneyTransaction],
        accounts: [Account],
        currency: String = "BHD"
    ) -> Data {
        let sorted = transactions.sorted { $0.date > $1.date }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var html = """
        <html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns="http://www.w3.org/TR/REC-html40">
        <head>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
        <!--[if gte mso 9]><xml><x:ExcelWorkbook><x:ExcelWorksheets><x:ExcelWorksheet><x:Name>Statement</x:Name><x:WorksheetOptions><x:DisplayGridlines/></x:WorksheetOptions></x:ExcelWorksheet></x:ExcelWorksheets></x:ExcelWorkbook></xml><![endif]-->
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
          table { border-collapse: collapse; width: 100%; }
          th { background-color: #2F6BFF; color: #FFFFFF; font-weight: bold; text-align: left; padding: 10px; border: 1px solid #D1D5DB; }
          td { padding: 8px 10px; border: 1px solid #E5E7EB; font-size: 13px; }
          .num { text-align: right; font-family: monospace; }
          .income { color: #16A34A; }
          .expense { color: #DC2626; }
          .header-title { font-size: 18px; font-weight: bold; margin-bottom: 4px; }
          .header-meta { font-size: 12px; color: #6B7280; margin-bottom: 16px; }
        </style>
        </head>
        <body>
        <div class="header-title">Budget AI — Transaction Statement</div>
        <div class="header-meta">Generated on \(df.string(from: Date())) | Total Transactions: \(sorted.count)</div>
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Description / Merchant</th>
              <th>Category</th>
              <th>Account</th>
              <th>Type</th>
              <th>Reference</th>
              <th>Amount (\(currency))</th>
            </tr>
          </thead>
          <tbody>
        """

        for tx in sorted {
            let accName = accounts.first(where: { $0.id == tx.accountID })?.name ?? (tx.smsBank ?? "Default Account")
            let dateStr = df.string(from: tx.date)
            let typeStr = tx.isIncome ? "Credit (Income)" : "Debit (Expense)"
            let amountClass = tx.isIncome ? "income" : "expense"
            let sign = tx.isIncome ? "+" : "-"
            let formattedAmount = String(format: "%.3f", tx.amount)
            let cleanRef = tx.smsReference ?? ""
            let cleanMerchant = escapeHTML(tx.merchant)
            let catName = escapeHTML(tx.category.title)

            html += """
            <tr>
              <td>\(dateStr)</td>
              <td>\(cleanMerchant)</td>
              <td>\(catName)</td>
              <td>\(escapeHTML(accName))</td>
              <td>\(typeStr)</td>
              <td>\(escapeHTML(cleanRef))</td>
              <td class="num \(amountClass)">\(sign)\(formattedAmount)</td>
            </tr>
            """
        }

        html += """
          </tbody>
        </table>
        </body>
        </html>
        """

        return html.data(using: .utf8) ?? Data()
    }

    // MARK: - PDF Export (Vector-drawn Crisp PDF Document)

    static func createPDFData(
        transactions: [MoneyTransaction],
        accounts: [Account],
        currency: String = "BHD"
    ) -> Data {
        let sorted = transactions.sorted { $0.date > $1.date }

        // Standard A4 Size: 595.2 x 841.8 points
        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 36.0
        let contentWidth = pageWidth - (margin * 2)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"

        let data = renderer.pdfData { ctx in
            var currentY: CGFloat = margin
            var pageIndex = 1

            func startNewPage() {
                ctx.beginPage()
                currentY = margin

                // Draw Header
                let titleFont = UIFont.systemFont(ofSize: 18, weight: .bold)
                let titleAttr: [NSAttributedString.Key: Any] = [
                    .font: titleFont,
                    .foregroundColor: UIColor(red: 0.08, green: 0.15, blue: 0.32, alpha: 1.0)
                ]
                "Budget AI — Bank Statement".draw(at: CGPoint(x: margin, y: currentY), withAttributes: titleAttr)
                currentY += 24

                let subFont = UIFont.systemFont(ofSize: 9, weight: .regular)
                let subAttr: [NSAttributedString.Key: Any] = [
                    .font: subFont,
                    .foregroundColor: UIColor.secondaryLabel
                ]
                let metaString = "Statement Date: \(df.string(from: Date()))   •   Page \(pageIndex)   •   Transactions: \(sorted.count)"
                metaString.draw(at: CGPoint(x: margin, y: currentY), withAttributes: subAttr)
                currentY += 16

                // Table Header Bar
                let headerRect = CGRect(x: margin, y: currentY, width: contentWidth, height: 22)
                let headerPath = UIBezierPath(roundedRect: headerRect, cornerRadius: 4)
                UIColor(red: 0.18, green: 0.42, blue: 1.0, alpha: 1.0).setFill()
                headerPath.fill()

                let thFont = UIFont.systemFont(ofSize: 9, weight: .bold)
                let thAttr: [NSAttributedString.Key: Any] = [.font: thFont, .foregroundColor: UIColor.white]

                "Date".draw(at: CGPoint(x: margin + 8, y: currentY + 5), withAttributes: thAttr)
                "Description / Merchant".draw(at: CGPoint(x: margin + 75, y: currentY + 5), withAttributes: thAttr)
                "Category".draw(at: CGPoint(x: margin + 250, y: currentY + 5), withAttributes: thAttr)
                "Account".draw(at: CGPoint(x: margin + 350, y: currentY + 5), withAttributes: thAttr)
                let amtHeader = "Amount (\(currency))"
                let amtHeaderSize = amtHeader.size(withAttributes: thAttr)
                amtHeader.draw(at: CGPoint(x: margin + contentWidth - amtHeaderSize.width - 8, y: currentY + 5), withAttributes: thAttr)

                currentY += 26
                pageIndex += 1
            }

            startNewPage()

            let rowFont = UIFont.systemFont(ofSize: 8.5, weight: .regular)
            let boldFont = UIFont.systemFont(ofSize: 8.5, weight: .semibold)
            let rowHeight: CGFloat = 20.0

            for (idx, tx) in sorted.enumerated() {
                if currentY + rowHeight > pageHeight - margin {
                    startNewPage()
                }

                // Alternating row background
                if idx % 2 == 1 {
                    let bgRect = CGRect(x: margin, y: currentY, width: contentWidth, height: rowHeight)
                    UIColor(white: 0.96, alpha: 1.0).setFill()
                    UIRectFill(bgRect)
                }

                let textAttr: [NSAttributedString.Key: Any] = [
                    .font: rowFont,
                    .foregroundColor: UIColor.label
                ]

                // Date
                let dStr = dateOnlyFormatter.string(from: tx.date)
                dStr.draw(at: CGPoint(x: margin + 8, y: currentY + 4), withAttributes: textAttr)

                // Merchant
                let mRect = CGRect(x: margin + 75, y: currentY + 4, width: 165, height: 14)
                tx.merchant.draw(with: mRect, options: [.truncatesLastVisibleLine], attributes: textAttr, context: nil)

                // Category
                let cRect = CGRect(x: margin + 250, y: currentY + 4, width: 95, height: 14)
                tx.category.title.draw(with: cRect, options: [.truncatesLastVisibleLine], attributes: textAttr, context: nil)

                // Account
                let accName = accounts.first(where: { $0.id == tx.accountID })?.name ?? (tx.smsBank ?? "-")
                let aRect = CGRect(x: margin + 350, y: currentY + 4, width: 85, height: 14)
                accName.draw(with: aRect, options: [.truncatesLastVisibleLine], attributes: textAttr, context: nil)

                // Amount
                let isIncome = tx.isIncome
                let amountColor = isIncome ? UIColor(red: 0.08, green: 0.65, blue: 0.35, alpha: 1.0) : UIColor(red: 0.85, green: 0.20, blue: 0.20, alpha: 1.0)
                let amtAttr: [NSAttributedString.Key: Any] = [
                    .font: boldFont,
                    .foregroundColor: amountColor
                ]
                let amtStr = "\(isIncome ? "+" : "-")\(String(format: "%.3f", tx.amount))"
                let amtSize = amtStr.size(withAttributes: amtAttr)
                amtStr.draw(at: CGPoint(x: margin + contentWidth - amtSize.width - 8, y: currentY + 4), withAttributes: amtAttr)

                currentY += rowHeight
            }
        }

        return data
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
