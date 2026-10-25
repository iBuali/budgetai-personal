import SwiftUI
import SwiftData
import Charts

struct NetWorthView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var range = 2
    @State private var editing: Account?
    @State private var showNew = false
    @State private var selectedDate: Date?

    private let ranges = [(label: "3M", months: 3), (label: "6M", months: 6), (label: "1Y", months: 12), (label: "All", months: 1200)]

    private var finance: Finance { Finance(transactions: [], accounts: accounts) }

    private var points: [ChartPoint] {
        let start = Calendar.current.date(byAdding: .month, value: -ranges[range].months, to: .now) ?? .distantPast
        return snapshots.filter { $0.day >= start }.map { ChartPoint(date: $0.day, value: $0.netWorth) }
    }

    var body: some View {
        let f = finance
        let pts = points
        let change = (pts.last?.value ?? f.netWorth) - (pts.first?.value ?? f.netWorth)
        let selected = selectedDate.flatMap { d in pts.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) }
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Net worth")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(selected?.value ?? f.netWorth, currency))
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("\(Money.format(change, currency, signed: true)) in \(ranges[range].label == "All" ? "total" : ranges[range].label)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(change >= 0 ? Theme.positive : Theme.negative)
                    Chart(pts) { p in
                        AreaMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [Theme.cobalt.opacity(0.16), Theme.cobalt.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.cobalt)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        if let selected, selected.date == p.date {
                            RuleMark(x: .value("Date", p.date)).foregroundStyle(Theme.ink.opacity(0.2))
                            PointMark(x: .value("Date", p.date), y: .value("Net worth", p.value)).foregroundStyle(Theme.cobalt)
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis {
                        AxisMarks(position: .trailing) { v in
                            AxisGridLine().foregroundStyle(Theme.track)
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(d)) } }
                        }
                    }
                    .frame(height: 180)
                    .padding(.top, 8)
                    .overlay {
                        if pts.count < 2 {
                            Text("History builds up as you use the app").font(.footnote).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    Picker("Range", selection: $range) {
                        ForEach(ranges.indices, id: \.self) { Text(ranges[$0].label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 6)
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent("Assets") { Text(Money.format(f.totalAssets, currency)).monospacedDigit().foregroundStyle(Theme.positive) }
                LabeledContent("Liabilities") { Text(Money.format(f.totalLiabilities, currency)).monospacedDigit().foregroundStyle(Theme.negative) }
            }

            let assets = accounts.filter { !$0.kind.isLiability }
            let liabilities = accounts.filter { $0.kind.isLiability }
            if !assets.isEmpty {
                Section("Assets") { ForEach(assets, content: accountRow) }
            }
            if !liabilities.isEmpty {
                Section("Loans & liabilities") { ForEach(liabilities, content: accountRow) }
            }
            Section {
                Button("Add account or asset", systemImage: "plus.circle.fill") { showNew = true }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $showNew) { AccountEditor(account: nil) }
    }

    private func accountRow(_ account: Account) -> some View {
        Button { editing = account } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: account.kind.symbol, color: account.kind.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).foregroundStyle(Theme.ink)
                    Text(account.institution.isEmpty ? account.kind.title : "\(account.kind.title) · \(account.institution)")
                        .font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Text(Money.format(account.kind.isLiability ? -account.balance : account.balance, currency))
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(account.kind.isLiability ? Theme.negative : Theme.ink)
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                context.delete(account)
                Ledger.recordSnapshot(context: context)
                try? context.save()
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct AccountEditor: View {
    let account: Account?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var institution = ""
    @State private var balanceText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. NBB Current)", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Bank or provider (optional)", text: $institution)
                }
                Section {
                    HStack {
                        Text(kind.isLiability ? "Amount owed" : (kind == .property || kind == .investment ? "Current value" : "Balance"))
                        Spacer()
                        TextField(Money.format(0, currency), text: $balanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                } footer: {
                    Text(kind.isLiquid ? "Counts toward your total balance and Safe to Spend." : (kind.isLiability ? "Subtracted from your net worth." : "Counts toward your net worth."))
                }
                if let account {
                    Section {
                        Button("Delete", role: .destructive) {
                            context.delete(account)
                            Ledger.recordSnapshot(context: context)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let account else { return }
                name = account.name
                kind = account.kind
                institution = account.institution
                balanceText = Money.number(account.balance, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                if account.balance < 0 { balanceText = "-" + balanceText }
            }
        }
    }

    private func save() {
        let balance = Money.parse(balanceText) ?? 0
        if let account {
            account.name = name.trimmingCharacters(in: .whitespaces)
            account.kind = kind
            account.institution = institution
            account.balance = balance
        } else {
            context.insert(Account(name: name.trimmingCharacters(in: .whitespaces), kind: kind, institution: institution, balance: balance))
        }
        Ledger.recordSnapshot(context: context)
        try? context.save()
        dismiss()
    }
}
