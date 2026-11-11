import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Statement Export Sheet

struct StatementExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var allTransactions: [MoneyTransaction]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var exportFormat: ExportFormat = .pdf
    @State private var selectedAccountFilter: UUID? = nil
    @State private var dateRange: ExportDateRange = .allTime
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEndDate: Date = .now
    @State private var isExporting = false
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false

    enum ExportFormat: String, CaseIterable, Identifiable {
        case pdf = "PDF Document (.pdf)"
        case excel = "Excel Spreadsheet (.xls)"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .pdf: return "doc.richtext.fill"
            case .excel: return "tablecells.fill"
            }
        }
    }

    enum ExportDateRange: String, CaseIterable, Identifiable {
        case thisMonth = "This Month"
        case lastMonth = "Last Month"
        case last3Months = "Last 3 Months"
        case thisYear = "This Year"
        case allTime = "All Time"
        case custom = "Custom Range"

        var id: String { rawValue }
    }

    private var targetTransactions: [MoneyTransaction] {
        var list = allTransactions.filter { !$0.isPending }

        // Filter by Account
        if let accID = selectedAccountFilter {
            list = list.filter { $0.accountID == accID || $0.toAccountID == accID }
        }

        // Filter by Date
        let cal = Calendar.current
        let now = Date()

        switch dateRange {
        case .thisMonth:
            if let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) {
                list = list.filter { $0.date >= start }
            }
        case .lastMonth:
            if let lastMonthDate = cal.date(byAdding: .month, value: -1, to: now),
               let start = cal.date(from: cal.dateComponents([.year, .month], from: lastMonthDate)),
               let end = cal.date(byAdding: .month, value: 1, to: start) {
                list = list.filter { $0.date >= start && $0.date < end }
            }
        case .last3Months:
            if let start = cal.date(byAdding: .month, value: -3, to: now) {
                list = list.filter { $0.date >= start }
            }
        case .thisYear:
            if let start = cal.date(from: cal.dateComponents([.year], from: now)) {
                list = list.filter { $0.date >= start }
            }
        case .allTime:
            break
        case .custom:
            list = list.filter { $0.date >= customStartDate && $0.date <= customEndDate }
        }

        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Export Format") {
                    Picker("Format", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Label(fmt.rawValue, systemImage: fmt.symbol).tag(fmt)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Filter by Account") {
                    Picker("Account", selection: $selectedAccountFilter) {
                        Text("All Accounts & Cards").tag(UUID?.none)
                        ForEach(accounts) { acc in
                            HStack {
                                Image(systemName: acc.kind.symbol)
                                Text("\(acc.name) (\(acc.kind.title))")
                            }
                            .tag(UUID?.some(acc.id))
                        }
                    }
                }

                Section("Date Range") {
                    Picker("Range", selection: $dateRange) {
                        ForEach(ExportDateRange.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }

                    if dateRange == .custom {
                        DatePicker("Start Date", selection: $customStartDate, displayedComponents: [.date])
                        DatePicker("End Date", selection: $customEndDate, displayedComponents: [.date])
                    }
                }

                Section("Summary") {
                    HStack {
                        Text("Transactions Included")
                        Spacer()
                        Text("\(targetTransactions.count)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.cobalt)
                    }

                    let income = targetTransactions.filter(\.isIncome).reduce(0) { $0 + $1.amount }
                    let expense = targetTransactions.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }

                    HStack {
                        Text("Total Income")
                        Spacer()
                        Text(Money.format(income, currency))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.positive)
                    }

                    HStack {
                        Text("Total Expense")
                        Spacer()
                        Text(Money.format(expense, currency))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                    }
                }

                Section {
                    Button {
                        generateAndShareExport()
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Image(systemName: "square.and.arrow.up.fill")
                            Text("Export Statement")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(targetTransactions.isEmpty || isExporting)
                }
            }
            .navigationTitle("Export Statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheetView(activityItems: [url])
                }
            }
        }
    }

    private func generateAndShareExport() {
        isExporting = true
        let txs = targetTransactions
        let accs = accounts
        let cur = currency
        let fmt = exportFormat

        DispatchQueue.global(qos: .userInitiated).async {
            let data: Data
            let ext: String
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmm"
            let timestamp = df.string(from: Date())

            if fmt == .pdf {
                data = StatementExportService.createPDFData(transactions: txs, accounts: accs, currency: cur)
                ext = "pdf"
            } else {
                data = StatementExportService.createExcelData(transactions: txs, accounts: accs, currency: cur)
                ext = "xls"
            }

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("BudgetAI-Statement-\(timestamp).\(ext)")

            try? data.write(to: fileURL)

            DispatchQueue.main.async {
                self.isExporting = false
                self.exportedFileURL = fileURL
                self.showShareSheet = true
            }
        }
    }
}

// MARK: - UIActivityViewController Wrapper for SwiftUI

struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
