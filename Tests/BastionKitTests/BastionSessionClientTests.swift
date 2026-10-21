// GH-93: plano de datos `/api/tokens` (research §9.5 (1) y (5)).
import Foundation
import Testing
@testable import BastionKit

struct BastionSessionClientTests {
    @Test func firstPostSendsExactlyTheFourFormFieldsAndNoChaining() async throws {
        let http = StubBastionHTTP()
        let session = try await BastionSessionClient(transport: http)
            .open(target, armToken: Secrets.armToken, previous: nil)

        let post = try #require(http.postRequests.first)
        #expect(post.url == "https://bst-123.bastion.azure.com/api/tokens")
        #expect(post.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(post.headers["X-Node-Id"] == nil)
        #expect(post.formKeys == ["resourceId", "protocol", "workloadHostPort", "aztoken"])
        #expect(post.form["resourceId"] == vmID)
        #expect(post.form["protocol"] == "tcptunnel")
        #expect(post.form["workloadHostPort"] == "22")
        #expect(post.form["aztoken"] == Secrets.armToken)
        #expect(session == .init(authToken: Secrets.authToken(1), nodeID: "node-7", websocketToken: Secrets.websocketToken(1)))
    }

    @Test func chainedPostAddsTokenAndNodeHeader() async throws {
        let http = StubBastionHTTP()
        let client = BastionSessionClient(transport: http)
        let first = try await client.open(target, armToken: Secrets.armToken, previous: nil)
        _ = try await client.open(target, armToken: Secrets.armToken, previous: first)

        let second = http.postRequests[1]
        #expect(second.formKeys == ["resourceId", "protocol", "workloadHostPort", "aztoken", "token"])
        #expect(second.form["token"] == first.authToken)
        #expect(second.headers["X-Node-Id"] == "node-7")
    }

    @Test func formEncodingMatchesQuotePlus() {
        let body = BastionSessionClient.formEncode([("resourceId", "/subscriptions/a b/x+y"), ("t", "a.b_c-d~e")])
        #expect(String(decoding: body, as: UTF8.self) == "resourceId=%2Fsubscriptions%2Fa%20b%2Fx%2By&t=a.b_c-d~e")
    }

    @Test func deleteCarriesNodeHeaderAndToleratesNotFound() async throws {
        let http = StubBastionHTTP(deleteStatus: 404)
        let client = BastionSessionClient(transport: http)
        let session = BastionSessionClient.Session(authToken: "abc", nodeID: "node-9", websocketToken: "w")

        #expect(try await client.close(target, session) == .alreadyGone)
        let delete = try #require(http.deleteRequests.first)
        #expect(delete.url == "https://bst-123.bastion.azure.com/api/tokens/abc")
        #expect(delete.headers["X-Node-Id"] == "node-9")

        http.deleteStatus = 204
        #expect(try await client.close(target, session) == .deleted)
    }

    @Test(arguments: [
        (401, BastionTunnelError.unauthorized(message: "No access")),
        (403, BastionTunnelError.unauthorized(message: "No access")),
        (404, BastionTunnelError.targetNotFound),
        (500, BastionTunnelError.serviceError(status: 500, message: "No access")),
    ])
    func httpErrorsAreTyped(status: Int, expected: BastionTunnelError) async {
        let http = StubBastionHTTP(postStatus: status, postBody: Data(#"{"message":"No access"}"#.utf8))
        await #expect(throws: expected) {
            try await BastionSessionClient(transport: http).open(target, armToken: Secrets.armToken, previous: nil)
        }
    }

    @Test func nonJSONSuccessMeansProtocolChanged() async {
        let http = StubBastionHTTP(postBody: Data("<html>login</html>".utf8))
        await #expect(throws: BastionTunnelError.protocolChanged(status: 200)) {
            try await BastionSessionClient(transport: http).open(target, armToken: Secrets.armToken, previous: nil)
        }
    }

    @Test func descriptionsNeverContainTokens() {
        let session = BastionSessionClient.Session(
            authToken: Secrets.authToken(1), nodeID: "node-7", websocketToken: Secrets.websocketToken(1))
        let request = BastionWebSocketRequest.tunnel(dnsName: target.dnsName, session: session)
        for text in [String(describing: session), String(describing: request), String(describing: target)] {
            #expect(!text.contains(Secrets.authToken(1)))
            #expect(!text.contains(Secrets.websocketToken(1)))
            #expect(!text.contains(Secrets.armToken))
        }
        #expect(String(describing: session).contains("‹redacted len="))
        #expect(String(describing: request).contains("X-Node-Id=node-7"))
    }

    @Test func gateRejectsBastionsWithoutNativeClient() throws {
        #expect(throws: BastionTunnelError.nativeClientDisabled(sku: "Basic")) {
            try BastionTarget.validated(bastionSKU: "Basic", enableTunneling: true, dnsName: "x", vmResourceID: vmID, port: 22)
        }
        #expect(throws: BastionTunnelError.nativeClientDisabled(sku: "Standard")) {
            try BastionTarget.validated(bastionSKU: "Standard", enableTunneling: false, dnsName: "x", vmResourceID: vmID, port: 22)
        }
        #expect(throws: BastionTunnelError.missingDNSName) {
            try BastionTarget.validated(bastionSKU: "Premium", enableTunneling: true, dnsName: nil, vmResourceID: vmID, port: 22)
        }
        let ok = try BastionTarget.validated(
            bastionSKU: "Standard", enableTunneling: true, dnsName: "bst.example", vmResourceID: vmID, port: 3389)
        #expect(ok.vmName == "vm-linux")
    }
}

struct BastionSessionPoolTests {
    @Test func concurrentAcquiresChainAndLastReleaseDeletesOnce() async throws {
        let http = StubBastionHTTP()
        let pool = BastionSessionPool(target: target, client: BastionSessionClient(transport: http)) { Secrets.armToken }

        async let a = pool.acquire()
        async let b = pool.acquire()
        _ = try await (a, b)

        let posts = http.postRequests
        #expect(posts.count == 2)
        #expect(posts[0].form["token"] == nil)
        #expect(posts[1].form["token"] == Secrets.authToken(1))

        await pool.release()
        #expect(http.deleteRequests.isEmpty)
        await pool.release()
        await pool.release()  // de más: no repite el DELETE
        #expect(http.deleteRequests.count == 1)
        #expect(http.deleteRequests[0].url.hasSuffix("/api/tokens/\(Secrets.authToken(2))"))
    }

    @Test func failedAcquireDoesNotLeakTheCounter() async {
        let http = StubBastionHTTP(postStatus: 403)
        let pool = BastionSessionPool(target: target, client: BastionSessionClient(transport: http)) { Secrets.armToken }
        _ = try? await pool.acquire()
        #expect(await pool.activeCount == 0)
        #expect(http.deleteRequests.isEmpty)
    }
}
