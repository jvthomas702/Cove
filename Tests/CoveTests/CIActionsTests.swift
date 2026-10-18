import XCTest
@testable import Cove

final class CIActionsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    // MARK: Requests

    func testRerunRequests() {
        let failed = CIRequest.rerunFailedJobs(repo: "me/app", runID: 42, token: "t0k")
        XCTAssertEqual(failed.httpMethod, "POST")
        XCTAssertEqual(failed.url?.absoluteString, "https://api.github.com/repos/me/app/actions/runs/42/rerun-failed-jobs")
        XCTAssertEqual(failed.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertEqual(failed.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")

        let whole = CIRequest.rerun(repo: "me/app", runID: 42, token: "t0k")
        XCTAssertEqual(whole.httpMethod, "POST")
        XCTAssertEqual(whole.url?.absoluteString, "https://api.github.com/repos/me/app/actions/runs/42/rerun")
    }

    func testDispatchRequestSendsTheBranch() throws {
        let request = CIRequest.dispatch(repo: "me/app", workflowID: 103, ref: "feature/login", token: "t0k")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/me/app/actions/workflows/103/dispatches")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["ref": "feature/login"])
    }

    func testWorkflowFileRequestAsksForRawYAMLOnTheBranch() {
        let request = CIRequest.workflowFile(repo: "me/app", path: ".github/workflows/deploy-prod.yml", ref: "feature/a b", token: "t0k")
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertEqual(request.url?.path, "/repos/me/app/contents/.github/workflows/deploy-prod.yml")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "feature/a b")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw")
    }

    func testPermissionErrorsExplainTheScopes() {
        XCTAssertTrue(CIRequest.message(status: 403).contains("gh auth refresh -s repo,workflow"))
        XCTAssertTrue(CIRequest.message(status: 404).contains("repo and workflow scopes"))
        XCTAssertTrue(CIRequest.message(status: 422, dispatch: true).contains("inputs"))
        XCTAssertTrue(CIRequest.message(status: 401).contains("gh auth login"))
    }

    // MARK: Deploy workflow detection

    func testFindsActiveDeployAndReleaseWorkflowsDeployFirst() throws {
        let found = CIWorkflow.deployCandidates(try fixture("github-workflows"))
        // "Production" matches by file name (deploy-prod.yml); "Publish release" by name.
        // build, the disabled "Old deploy" and Dependabot are left out.
        XCTAssertEqual(found.map(\.id), [103, 102])
        XCTAssertEqual(found[0].name, "Production")
        XCTAssertEqual(found[0].fileName, "deploy-prod.yml")
    }

    func testLooksLikeDeploy() {
        XCTAssertTrue(CIWorkflow.looksLikeDeploy(name: "Deploy to Fly", path: ".github/workflows/ci.yml"))
        XCTAssertTrue(CIWorkflow.looksLikeDeploy(name: "Ship", path: ".github/workflows/RELEASE.yaml"))
        XCTAssertFalse(CIWorkflow.looksLikeDeploy(name: "build", path: ".github/workflows/build.yml"))
    }

    func testDispatchTriggerDetection() {
        XCTAssertTrue(CIWorkflow.hasDispatchTrigger("""
        name: Deploy
        on:
          push:
            branches: [main]
          workflow_dispatch:
            inputs:
              env: {default: prod}
        """))
        XCTAssertTrue(CIWorkflow.hasDispatchTrigger("on: [push, workflow_dispatch]\njobs: {}"))
        XCTAssertTrue(CIWorkflow.hasDispatchTrigger("on: workflow_dispatch"))
        XCTAssertFalse(CIWorkflow.hasDispatchTrigger("""
        on:
          push:
          # workflow_dispatch: turned off for now
        """))
        XCTAssertFalse(CIWorkflow.hasDispatchTrigger("on:\n  workflow_dispatch_extra:\n"))
        XCTAssertFalse(CIWorkflow.hasDispatchTrigger("on: [push]"))
    }

    // MARK: Client

    @MainActor
    func testDeployWorkflowsKeepsOnlyHandStartableOnes() async throws {
        let workflows = try fixture("github-workflows")
        var asked: [String] = []
        let client = CIActionClient(transport: { request in
            asked.append(request.url!.absoluteString)
            switch request.url!.path {
            case "/repos/me/app/actions/workflows": return (workflows, 200)
            case "/repos/me/app/contents/.github/workflows/deploy-prod.yml":
                return (Data("on:\n  workflow_dispatch:\n".utf8), 200)
            case "/repos/me/app/contents/.github/workflows/publish.yml":
                return (Data("on:\n  push:\n    tags: ['v*']\n".utf8), 200)
            default: return (Data(), 404)
            }
        }, tokenProvider: { "t0k" })
        let found = try await client.deployWorkflows(repo: "me/app", branch: "main")
        XCTAssertEqual(found.map(\.name), ["Production"])
        XCTAssertEqual(asked.count, 3)
        // Cached for the branch: no more requests.
        _ = try await client.deployWorkflows(repo: "me/app", branch: "main")
        XCTAssertEqual(asked.count, 3)
    }

    @MainActor
    func testRerunFallsBackToTheWholeRun() async throws {
        var asked: [String] = []
        let client = CIActionClient(transport: { request in
            asked.append(request.url!.lastPathComponent)
            return (Data(), request.url!.lastPathComponent == "rerun-failed-jobs" ? 403 : 201)
        }, tokenProvider: { "t0k" })
        try await client.rerun(repo: "me/app", runID: 7)
        XCTAssertEqual(asked, ["rerun-failed-jobs", "rerun"])
    }

    @MainActor
    func testRerunReportsScopeProblem() async {
        let client = CIActionClient(transport: { _ in (Data(), 403) }, tokenProvider: { "t0k" })
        do {
            try await client.rerun(repo: "me/app", runID: 7)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? CIActionError)?.status, 403)
            XCTAssertTrue(error.localizedDescription.contains("workflow scopes"))
        }
    }

    @MainActor
    func testSignedOutIsExplained() async {
        let client = CIActionClient(transport: { _ in (Data(), 200) }, tokenProvider: { nil })
        do {
            try await client.dispatch(repo: "me/app", workflow: CIWorkflow(id: 1, name: "Deploy", path: "deploy.yml"), branch: "main")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("gh auth login"))
        }
    }

    // MARK: Model

    @MainActor
    func testFailedRunOffersRerunAndShowsProgress() async throws {
        var asked: [String] = []
        let client = CIActionClient(transport: { request in
            asked.append(request.url!.path)
            return (Data(), 201)
        }, tokenProvider: { "t0k" })
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.ciMonitor = true
        let model = IslandModel(config: config, ciClient: client)
        let run = CIRun(id: 9, repo: "me/app", workflow: "build", branch: "main", commit: "Fix", actor: "me",
                        state: .failed, url: URL(string: "https://github.com/me/app/actions/runs/9")!, createdAt: Date())
        model.ciRun(run)
        XCTAssertTrue(model.ciActionsAvailable("ci:9"))
        model.ciRerun("ci:9")
        XCTAssertEqual(model.ciActionStates["ci:9"], .working("Re-running…"))
        for _ in 0..<100 where model.ciActionStates["ci:9"]?.isWorking == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.ciActionStates["ci:9"], .done("Re-run started"))
        XCTAssertEqual(asked, ["/repos/me/app/actions/runs/9/rerun-failed-jobs"])
        // The re-run shows up as running again and the status clears.
        model.ciRun(CIRun(id: 9, repo: "me/app", workflow: "build", branch: "main", commit: "Fix", actor: "me",
                          state: .running, url: run.url, createdAt: run.createdAt))
        XCTAssertNil(model.ciActionStates["ci:9"])

        var off = config
        off.ciActions = false
        model.config = off
        XCTAssertFalse(model.ciActionsAvailable("ci:9"))
    }
    @MainActor
    func testPassedRunOffersDeployOnItsBranch() async throws {
        let workflows = try fixture("github-workflows")
        var dispatched: [String: String] = [:]
        let client = CIActionClient(transport: { request in
            let path = request.url!.path
            if path.hasSuffix("/dispatches") {
                dispatched[path] = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])?["ref"]
                return (Data(), 204)
            }
            if path == "/repos/me/app/actions/workflows" { return (workflows, 200) }
            if path.hasSuffix("deploy-prod.yml") { return (Data("on: [workflow_dispatch]".utf8), 200) }
            return (Data(), 404)
        }, tokenProvider: { "t0k" })
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.ciMonitor = true
        let model = IslandModel(config: config, ciClient: client)
        model.ciRun(CIRun(id: 5, repo: "me/app", workflow: "build", branch: "release/2.0", commit: "", actor: "me",
                          state: .passed, url: URL(string: "https://github.com/me/app/actions/runs/5")!, createdAt: Date()))
        for _ in 0..<100 where model.ciDeploys["ci:5"]?.isEmpty != false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let deploy = try XCTUnwrap(model.ciDeploys["ci:5"]?.first)
        XCTAssertEqual(deploy.name, "Production")
        model.ciDeploy("ci:5", workflow: deploy)
        for _ in 0..<100 where model.ciActionStates["ci:5"]?.isWorking == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.ciActionStates["ci:5"], .done("Production started"))
        XCTAssertEqual(dispatched, ["/repos/me/app/actions/workflows/103/dispatches": "release/2.0"])
    }
}
