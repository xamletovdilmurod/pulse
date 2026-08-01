import Foundation

/// Whether money moved out of or into the user's hands.
public enum TransactionKind: String, Hashable, Sendable, Codable, CaseIterable {
    case expense
    case income
}

/// A spending or earning category.
///
/// The raw values are a fixed, stable vocabulary shared by three things that must agree exactly: this
/// enum, the deterministic parser's keyword tables, and the LLM's training corpus. If they drift, the
/// model starts emitting category names the app cannot decode. Treat the raw strings as a wire format —
/// renaming one is a migration, not a refactor.
public enum TransactionCategory: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {

    // MARK: Expense

    case groceries
    case dining
    case cafeCoffee = "cafe_coffee"
    case transport
    case fuel
    case rent
    case utilities
    case health
    case education
    case clothing
    case entertainment
    case gifts
    case travel
    case communication
    case subscriptions
    case family
    case household
    case beauty
    case pets
    case charity
    case fees
    case other

    // MARK: Income

    case salary
    case freelance
    case business
    case giftReceived = "gift_received"
    case refund
    case investment
    case otherIncome = "other_income"

    public var id: String { rawValue }

    /// Which side of the ledger this category belongs to.
    public var kind: TransactionKind {
        switch self {
        case .salary, .freelance, .business, .giftReceived, .refund, .investment, .otherIncome:
            .income
        default:
            .expense
        }
    }

    public static let expenseCategories: [TransactionCategory] = allCases.filter { $0.kind == .expense }
    public static let incomeCategories: [TransactionCategory] = allCases.filter { $0.kind == .income }

    /// The fallback for each side of the ledger, used when nothing else matches.
    public static func fallback(for kind: TransactionKind) -> TransactionCategory {
        kind == .income ? .otherIncome : .other
    }

    /// SF Symbol name for the category.
    public var symbolName: String {
        switch self {
        case .groceries: "cart.fill"
        case .dining: "fork.knife"
        case .cafeCoffee: "cup.and.saucer.fill"
        case .transport: "bus.fill"
        case .fuel: "fuelpump.fill"
        case .rent: "house.fill"
        case .utilities: "bolt.fill"
        case .health: "cross.case.fill"
        case .education: "book.fill"
        case .clothing: "tshirt.fill"
        case .entertainment: "gamecontroller.fill"
        case .gifts: "gift.fill"
        case .travel: "airplane"
        case .communication: "antenna.radiowaves.left.and.right"
        case .subscriptions: "arrow.trianglehead.2.clockwise.rotate.90"
        case .family: "figure.2.and.child.holdinghands"
        case .household: "sofa.fill"
        case .beauty: "scissors"
        case .pets: "pawprint.fill"
        case .charity: "hand.raised.fill"
        case .fees: "percent"
        case .other: "square.grid.2x2.fill"
        case .salary: "banknote.fill"
        case .freelance: "laptopcomputer"
        case .business: "briefcase.fill"
        case .giftReceived: "gift"
        case .refund: "arrow.uturn.backward"
        case .investment: "chart.line.uptrend.xyaxis"
        case .otherIncome: "plus.circle.fill"
        }
    }

    /// Untranslated English name. The UI resolves a localized string from the String Catalog and falls
    /// back to this; keeping it here means logs and exports are always readable.
    public var englishName: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .cafeCoffee: "Cafe & Coffee"
        case .transport: "Transport"
        case .fuel: "Fuel"
        case .rent: "Rent"
        case .utilities: "Utilities"
        case .health: "Health"
        case .education: "Education"
        case .clothing: "Clothing"
        case .entertainment: "Entertainment"
        case .gifts: "Gifts"
        case .travel: "Travel"
        case .communication: "Communication"
        case .subscriptions: "Subscriptions"
        case .family: "Family"
        case .household: "Household"
        case .beauty: "Beauty"
        case .pets: "Pets"
        case .charity: "Charity"
        case .fees: "Fees"
        case .other: "Other"
        case .salary: "Salary"
        case .freelance: "Freelance"
        case .business: "Business"
        case .giftReceived: "Gift received"
        case .refund: "Refund"
        case .investment: "Investment"
        case .otherIncome: "Other income"
        }
    }
}
