import Foundation
import Contacts

public protocol ContactResolver: AnyObject {
    func name(for handle: String) -> String?
}

/// Normalizes a phone number or email so "+1 (555) 010-2000" and "5550102000" match.
public func normalizeHandle(_ h: String) -> String {
    if h.contains("@") { return h.lowercased().trimmingCharacters(in: .whitespaces) }
    let digits = h.filter(\.isNumber)
    return digits.count > 10 ? String(digits.suffix(10)) : digits
}

/// Fixed name table, used by tests and demo mode.
public final class StaticContacts: ContactResolver {
    private let table: [String: String]
    public init(_ names: [String: String]) {
        table = Dictionary(names.map { (normalizeHandle($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
    public func name(for handle: String) -> String? { table[normalizeHandle(handle)] }
}

/// Reads names from the macOS Contacts database (needs the Contacts permission).
public final class SystemContacts: ContactResolver {
    private var table: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public static var isAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    public func requestAccess(_ done: @escaping (Bool) -> Void) {
        CNContactStore().requestAccess(for: .contacts) { ok, _ in
            if ok { self.reload() }
            done(ok)
        }
    }

    public func reload() {
        guard Self.isAuthorized else { return }
        var t: [String: String] = [:]
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                     CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = !full.isEmpty ? full : (!c.nickname.isEmpty ? c.nickname : c.organizationName)
            guard !name.isEmpty else { return }
            for p in c.phoneNumbers { t[normalizeHandle(p.value.stringValue)] = name }
            for e in c.emailAddresses { t[normalizeHandle(e.value as String)] = name }
        }
        lock.lock(); table = t; lock.unlock()
    }

    public func name(for handle: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[normalizeHandle(handle)]
    }
}
