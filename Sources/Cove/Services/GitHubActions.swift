import Foundation
import os

/// One GitHub Actions workflow run, reduced to what the island shows.
struct CIRun: Equatable {
    enum State: Equatable { case running, passed, failed, cancelled }

    let id: Int
    let repo: String        // "owner/name"
    let workflow: String
    let branch: String
    let commit: String      // first line of the head commit message
    let actor: String
    let state: State
    let url: URL
    let createdAt: Date

    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    /// Runs from `GET /repos/{repo}/actions/runs`.
    static func parse(_ data: Data, repo: String) -> [CIRun] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runs = json["workflow_runs"] as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        return runs.compactMap { r in
            guard let id = r["id"] as? Int,
                  let url = (r["html_url"] as? String).flatMap(URL.init(string:)),
                  let created = (r["created_at"] as? String).flatMap(dates.date(from:)) else { return nil }
            let status = r["status"] as? String ?? ""
            let conclusion = r["conclusion"] as? String
            let state: State
            if status != "completed" {
                state = .running
            } else {
                switch conclusion {
                case "success": state = .passed
                case "cancelled", "skipped", "neutral", "stale": state = .cancelled
                default: state = .failed // failure, timed_out, action_required, startup_failure
                }
            }
            let commit = ((r["head_commit"] as? [String: Any])?["message"] as? String ?? "")
                .split(separator: "\n").first.map(String.init) ?? ""
            return CIRun(
                id: id, repo: repo,
                workflow: r["name"] as? String ?? "Workflow",
                branch: r["head_branch"] as? String ?? "",
                commit: commit,
                actor: (r["actor"] as? [String: Any])?["login"] as? String ?? "",
                state: state, url: url, createdAt: created
            )
        }
    }
}

/// Watches GitHub Actions on your repos and reports runs as they start and finish.
///
/// Signs in with the GitHub CLI's token (`gh auth token`), so there's nothing to paste and no token
/// stored by Cove. Watches the repos in `ciRepos`, or else the ones you pushed to in the last two days.
@MainActor
final class GitHubActionsMonitor {
    enum Status: Equatable {
        case starting
        case noCLI          // gh isn't installed
        case signedOut      // gh is installed but not logged in
        case watching(login: String, repos: [String])
        case error(String)
    }

    var onRun: ((CIRun) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var explicitRepos: [String]
    private var token: String?
    private var login = ""
    private var repos: [String] = []
    private var reposFetchedAt: Date?
    private var states: [Int: CIRun.State] = [:]
    private var timer: Timer?
    private let startedAt = Date()
    private var polling = false

    init(repos: [String]) {
        explicitRepos = repos.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("/") }
    }

    func start() {
        guard timer == nil else { return }
        onStatus?(.starting)
        Task { [weak self] in
            let token = await Self.cliToken()
            guard let self else { return }
            guard let installed = token else { self.onStatus?(.noCLI); return }
            guard let value = installed else { self.onStatus?(.signedOut); return }
            self.token = value
            await self.poll()
            self.schedule()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        token = nil
    }

    func update(repos: [String]) {
        explicitRepos = repos.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("/") }
        reposFetchedAt = nil
    }

    /// Polls right away (after a re-run or deploy), then carries on at the usual pace.
    func refreshNow() {
        guard token != nil else { return }
        Task { [weak self] in
            // GitHub takes a moment to queue the new attempt.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.token != nil else { return }
            await self.poll()
            self.schedule()
        }
    }

    /// Faster while something is running, so finishes show up promptly.
    private func schedule() {
        timer?.invalidate()
        let busy = states.values.contains(.running)
        timer = Timer.scheduledTimer(withTimeInterval: busy ? 20 : 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.token != nil else { return }
                Task {
                    await self.poll()
                    self.schedule()
                }
            }
        }
    }

    private func poll() async {
        guard let token, !polling else { return }
        polling = true
        defer { polling = false }
        do {
            if login.isEmpty, let me = try await get("/user", token: token) as? [String: Any] {
                login = me["login"] as? String ?? ""
            }
            if reposFetchedAt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
                repos = explicitRepos.isEmpty ? try await recentRepos(token: token) : explicitRepos
                reposFetchedAt = Date()
            }
            onStatus?(.watching(login: login, repos: repos))
            for repo in repos {
                let data = try await getData("/repos/\(repo)/actions/runs?per_page=10", token: token)
                for run in CIRun.parse(data, repo: repo) { consider(run) }
            }
        } catch {
            coveLog.error("GitHub Actions: \(error.localizedDescription, privacy: .public)")
            onStatus?(.error(error.localizedDescription))
        }
    }

    /// Reports a run when it starts or changes state. Runs that finished before Cove started stay quiet.
    private func consider(_ run: CIRun) {
        // Only your own runs on auto-discovered repos; every run on repos you listed.
        if explicitRepos.isEmpty, !login.isEmpty, run.actor.caseInsensitiveCompare(login) != .orderedSame { return }
        guard Date().timeIntervalSince(run.createdAt) < 6 * 3600 else { return }
        let old = states[run.id]
        states[run.id] = run.state
        guard old != run.state else { return }
        if old == nil, run.state != .running, run.createdAt < startedAt { return }
        onRun?(run)
    }

    private func recentRepos(token: String) async throws -> [String] {
        let list = try await get("/user/repos?sort=pushed&per_page=15&affiliation=owner,collaborator", token: token)
        let dates = ISO8601DateFormatter()
        return ((list as? [[String: Any]]) ?? []).compactMap { r in
            guard let name = r["full_name"] as? String,
                  let pushed = (r["pushed_at"] as? String).flatMap(dates.date(from:)),
                  Date().timeIntervalSince(pushed) < 2 * 86400 else { return nil }
            return name
        }
    }

    private func get(_ path: String, token: String) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await getData(path, token: token))
    }

    private func getData(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(http.statusCode) for \(path)"])
        }
        return data
    }

    /// nil when gh isn't installed; .some(nil) when it is but isn't signed in.
    nonisolated static func cliToken() async -> String?? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await Task.detached { () -> String?? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do { try process.run() } catch { return .some(nil) }
            process.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return process.terminationStatus == 0 && !text.isEmpty ? .some(text) : .some(nil)
        }.value
    }
}
