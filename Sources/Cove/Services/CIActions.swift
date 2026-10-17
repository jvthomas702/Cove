import Foundation

/// A workflow whose name or file says it deploys or releases. Offered as "Run <name>" on finished runs
/// when its file has a `workflow_dispatch` trigger, so it can be started by hand.
struct CIWorkflow: Equatable {
    let id: Int
    let name: String
    let path: String        // ".github/workflows/deploy.yml"

    var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }

    static func looksLikeDeploy(name: String, path: String) -> Bool {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        return [name, file].contains { text in
            let lower = text.lowercased()
            return lower.contains("deploy") || lower.contains("release")
        }
    }

    /// Active workflows from `GET /repos/{repo}/actions/workflows` that look like deploys,
    /// "deploy" ones before "release" ones.
    static func deployCandidates(_ data: Data) -> [CIWorkflow] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["workflows"] as? [[String: Any]] else { return [] }
        let found = list.compactMap { w -> CIWorkflow? in
            guard let id = w["id"] as? Int, let path = w["path"] as? String,
                  (w["state"] as? String ?? "active") == "active" else { return nil }
            let name = (w["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? path
            guard looksLikeDeploy(name: name, path: path) else { return nil }
            return CIWorkflow(id: id, name: name, path: path)
        }
        let deploys = found.filter { "\($0.name) \($0.fileName)".lowercased().contains("deploy") }
        return deploys + found.filter { !deploys.contains($0) }
    }

    /// Whether a workflow file can be started by hand: `on: workflow_dispatch`, `on: [push, workflow_dispatch]`
    /// or a `workflow_dispatch:` key. Comments don't count.
    static func hasDispatchTrigger(_ yaml: String) -> Bool {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return code.range(of: #"\bworkflow_dispatch\b"#, options: .regularExpression) != nil
        }
    }
}

/// The GitHub REST requests behind the Re-run and Deploy buttons.
enum CIRequest {
    static let api = "https://api.github.com"

    /// Re-runs only the jobs that failed (keeps the passing ones).
    static func rerunFailedJobs(repo: String, runID: Int, token: String) -> URLRequest {
        post("/repos/\(repo)/actions/runs/\(runID)/rerun-failed-jobs", token: token)
    }

    /// Re-runs the whole run, for runs with no failed job to retry (a startup failure, a cancelled job).
    static func rerun(repo: String, runID: Int, token: String) -> URLRequest {
        post("/repos/\(repo)/actions/runs/\(runID)/rerun", token: token)
    }

    static func workflows(repo: String, token: String) -> URLRequest {
        make(URL(string: api + "/repos/\(repo)/actions/workflows?per_page=100")!, token: token)
    }

    /// The workflow's YAML as it is on `ref`.
    static func workflowFile(repo: String, path: String, ref: String, token: String) -> URLRequest {
        var components = URLComponents(string: api)!
        components.path = "/repos/\(repo)/contents/\(path)"
        components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        var request = make(components.url!, token: token)
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        return request
    }

    /// Starts a `workflow_dispatch` workflow on a branch.
    static func dispatch(repo: String, workflowID: Int, ref: String, token: String) -> URLRequest {
        var request = post("/repos/\(repo)/actions/workflows/\(workflowID)/dispatches", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ref": ref])
        return request
    }

    /// What to tell the user when GitHub says no.
    static func message(status: Int, dispatch: Bool = false) -> String {
        switch status {
        case 401: return "GitHub sign-in expired. Run gh auth login in Terminal."
        case 403, 404:
            return "GitHub said no (\(status)). The gh token needs the repo and workflow scopes: run gh auth refresh -s repo,workflow"
        case 409: return "GitHub says this run is busy (409). Try again in a moment."
        case 422:
            return dispatch ? "GitHub couldn't start it (422). The workflow may need inputs, or isn't on this branch."
                : "GitHub couldn't re-run it (422). It may still be running or too old."
        default: return "GitHub answered \(status)."
        }
    }

    private static func post(_ path: String, token: String) -> URLRequest {
        var request = make(URL(string: api + path)!, token: token)
        request.httpMethod = "POST"
        return request
    }

    private static func make(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
}

/// Progress of a Re-run or Deploy click, shown inline in place of the buttons.
enum CIActionState: Equatable {
    case working(String)
    case done(String)
    case failed(String)

    var label: String {
        switch self {
        case .working(let text), .done(let text): return text
        case .failed: return "Didn't start"
        }
    }

    var isWorking: Bool { if case .working = self { return true } else { return false } }
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

struct CIActionError: LocalizedError, Equatable {
    var status: Int?
    var message: String
    var errorDescription: String? { message }
}

/// Re-runs and dispatches workflows, signed in with the GitHub CLI's token like the monitor.
@MainActor
final class CIActionClient {
    typealias Transport = (URLRequest) async throws -> (Data, Int)

    private let transport: Transport
    private let tokenProvider: () async -> String?
    private var token: String?
    private var deployCache: [String: (date: Date, workflows: [CIWorkflow])] = [:]

    init(transport: Transport? = nil, tokenProvider: (() async -> String?)? = nil) {
        if let transport {
            self.transport = transport
        } else {
            self.transport = { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
        if let tokenProvider {
            self.tokenProvider = tokenProvider
        } else {
            self.tokenProvider = { await GitHubActionsMonitor.cliToken() ?? nil }
        }
    }

    /// Re-runs the failed jobs, or the whole run when there are none to retry.
    func rerun(repo: String, runID: Int) async throws {
        let token = try await signIn()
        let (_, status) = try await transport(CIRequest.rerunFailedJobs(repo: repo, runID: runID, token: token))
        if (200..<300).contains(status) { return }
        if status == 401 { throw CIActionError(status: status, message: CIRequest.message(status: status)) }
        let (_, fallback) = try await transport(CIRequest.rerun(repo: repo, runID: runID, token: token))
        if (200..<300).contains(fallback) { return }
        throw CIActionError(status: fallback, message: CIRequest.message(status: fallback))
    }

    func dispatch(repo: String, workflow: CIWorkflow, branch: String) async throws {
        let token = try await signIn()
        let (_, status) = try await transport(CIRequest.dispatch(repo: repo, workflowID: workflow.id, ref: branch, token: token))
        guard (200..<300).contains(status) else {
            throw CIActionError(status: status, message: CIRequest.message(status: status, dispatch: true))
        }
    }

    /// Deploy or release workflows that can be started on `branch`. Cached for ten minutes per branch.
    func deployWorkflows(repo: String, branch: String) async throws -> [CIWorkflow] {
        let key = "\(repo)@\(branch)"
        if let cached = deployCache[key], Date().timeIntervalSince(cached.date) < 600 { return cached.workflows }
        let token = try await signIn()
        let (data, status) = try await transport(CIRequest.workflows(repo: repo, token: token))
        guard (200..<300).contains(status) else {
            throw CIActionError(status: status, message: CIRequest.message(status: status))
        }
        var found: [CIWorkflow] = []
        for workflow in CIWorkflow.deployCandidates(data).prefix(4) {
            let request = CIRequest.workflowFile(repo: repo, path: workflow.path, ref: branch, token: token)
            guard let file = try? await transport(request), (200..<300).contains(file.1),
                  CIWorkflow.hasDispatchTrigger(String(decoding: file.0, as: UTF8.self)) else { continue }
            found.append(workflow)
        }
        deployCache[key] = (Date(), found)
        return found
    }

    private func signIn() async throws -> String {
        if let token { return token }
        guard let value = await tokenProvider() else {
            throw CIActionError(message: "Sign in to the GitHub CLI first: gh auth login")
        }
        token = value
        return value
    }
}
