// GH-90 (auth solo `az login`, decisión del dueño 2026-10-20): de dónde salen
// los tenants y las suscripciones del árbol. `az account list` da lo que la
// sesión del CLI conoce (incluidas las cuentas); ARM REST, con el token de `az`,
// da nombres de tenant y el estado vivo de las suscripciones.
import AuthKit
import Foundation

/// Tenants y suscripciones visibles para la cuenta.
public protocol AzureAccountDirectory: Sendable {
    func tenants(homeTenantID: String) async throws -> [AzureTenant]
    /// Suscripciones accesibles con el token de `tenantID`.
    func subscriptions(tenantID: String) async throws -> [AzureSubscription]
}

/// Solo ARM REST (`GET /tenants`, `GET /subscriptions`).
extension AzureARMClient: AzureAccountDirectory {}

/// `az account list` + ARM REST:
/// - tenants: los de `az account list` (el de origen primero) unidos a
///   `GET /tenants`, que aporta nombre y dominio; si ARM falla, quedan los de `az`.
/// - suscripciones: `GET /subscriptions` con el token del tenant (estado
///   actual, incluidas las creadas tras el `az login`); si ARM falla, las que
///   `az` tenía en su caché para ese tenant.
public struct AzCliAccountDirectory: AzureAccountDirectory {
    private let arm: AzureARMClient
    private let list: AccountListMemo

    /// - Parameter accounts: `az account list` (en la App,
    ///   `AzCliTokenSource.accounts`). Se invoca una vez por directorio.
    public init(arm: AzureARMClient, accounts: @escaping @Sendable () async throws -> [AzCliAccount]) {
        self.arm = arm
        list = AccountListMemo(load: accounts)
    }

    public func tenants(homeTenantID: String) async throws -> [AzureTenant] {
        let accounts = try await list.value()
        var order: [String] = [homeTenantID.lowercased()]
        var tenants: [String: AzureTenant] = [homeTenantID.lowercased(): AzureTenant(tenantID: homeTenantID)]
        for account in accounts where tenants[account.tenantID.lowercased()] == nil {
            order.append(account.tenantID.lowercased())
            tenants[account.tenantID.lowercased()] = AzureTenant(tenantID: account.tenantID)
        }
        if let named = try? await arm.tenants(homeTenantID: homeTenantID) {
            for tenant in named {
                let key = tenant.tenantID.lowercased()
                if tenants[key] == nil { order.append(key) }
                tenants[key] = tenant
            }
        }
        return order.compactMap { tenants[$0] }
    }

    public func subscriptions(tenantID: String) async throws -> [AzureSubscription] {
        do {
            return try await arm.subscriptions(tenantID: tenantID)
        } catch {
            let cached = try await list.value()
                .filter { !$0.isTenantLevel && $0.tenantID.caseInsensitiveCompare(tenantID) == .orderedSame }
                .map { AzureSubscription(subscriptionID: $0.id, tenantID: $0.homeTenantID ?? $0.tenantID, displayName: $0.name, state: $0.state ?? "Enabled") }
            if cached.isEmpty { throw error }
            return cached
        }
    }
}

/// Una sola invocación de `az account list` por directorio (el discovery
/// pide tenants y luego suscripciones de cada tenant).
private actor AccountListMemo {
    private let load: @Sendable () async throws -> [AzCliAccount]
    private var task: Task<[AzCliAccount], any Error>?

    init(load: @escaping @Sendable () async throws -> [AzCliAccount]) {
        self.load = load
    }

    func value() async throws -> [AzCliAccount] {
        if let task { return try await task.value }
        let load = self.load
        let task = Task { try await load() }
        self.task = task
        return try await task.value
    }
}
