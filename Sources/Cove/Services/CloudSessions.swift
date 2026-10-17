import Foundation
import os

/// A pull request that a Claude cloud session (claude.ai/code, a Claude project thread, a routine) opened.
///
/// Cloud sessions run on Anthropic's machines, so Cove's local hooks never hear from them. What does
/// reach your Mac is GitHub: those sessions push branches and open PRs whose description links back to
/// the session ("https://claude.ai/code/session_…" or a project thread). Cove spots them by that link.
struct CloudPR: Equatable {
    enum State: Equatable { case open, merged, closed }

    /// What the island says about the PR.
    enum Phase: Equatable {
        case draft          // opened as a draft, no CI yet
        case ciRunning
        case ciFailed
        case draftPassed    // CI green but Claude hasn't marked it ready
        case ready          // ready for review, CI green or no CI
        case merged
        case closed

        var label: String {
            switch self {
            case .draft: return "Draft PR"
            case .ciRunning: return "CI running"
            case .ciFailed: return "CI failed"
            case .draftPassed: return "CI passed, still a draft"
            case .ready: return "Ready for review"
            case .merged: return "Merged"
            case .closed: return "Closed"
            }
        }

        var isLive: Bool { self == .draft || self == .ciRunning }
    }

    let repo: String        // "owner/name"
    let number: Int
    let title: String
    let url: URL            // the PR on GitHub
    /// Where clicking goes: the project thread or cloud session that made it, else the PR.
    let link: URL
    let headSHA: String
    let draft: Bool
    let state: State
    let createdAt: Date
    let updatedAt: Date

    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var id: String { "cloud:\(repo)#\(number)" }

    func phase(checks: CheckSummary) -> Phase {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: break
        }
        switch checks {
        case .failed: return .ciFailed
        case .running: return .ciRunning
        case .passed: return draft ? .draftPassed : .ready
        case .none: return draft ? .draft : .ready
        }
    }

    /// Claude-made PRs from `GET /repos/{repo}/pulls`.
    static func parse(_ data: Data, repo: String) -> [CloudPR] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        return list.compactMap { p in
            let body = p["body"] as? String ?? ""
            guard isFromClaude(body: body),
                  let number = p["number"] as? Int,
                  let url = (p["html_url"] as? String).flatMap(URL.init(string:)),
                  let sha = (p["head"] as? [String: Any])?["sha"] as? String,
                  let created = (p["created_at"] as? String).flatMap(dates.date(from:)) else { return nil }
            let updated = (p["updated_at"] as? String).flatMap(dates.date(from:)) ?? created
            let state: State = p["merged_at"] is String ? .merged : (p["state"] as? String == "closed" ? .closed : .open)
            return CloudPR(
                repo: repo, number: number, title: p["title"] as? String ?? "Pull request",
                url: url, link: sessionLink(in: body) ?? url, headSHA: sha,
                draft: p["draft"] as? Bool ?? false, state: state, createdAt: created, updatedAt: updated
            )
        }
    }

    /// PRs from Claude Code carry a session or project-thread link, or the "Generated with Claude Code" line.
    static func isFromClaude(body: String) -> Bool {
        sessionLink(in: body) != nil || body.contains("Generated with [Claude Code]")
    }

    /// The project thread link if there is one (that's the conversation you'd want), else the session link.
    static func sessionLink(in body: String) -> URL? {
        func first(_ pattern: String) -> URL? {
            guard let range = body.range(of: pattern, options: .regularExpression) else { return nil }
            return URL(string: String(body[range]))
        }
        return first(#"https://claude\.ai/code/project/[A-Za-z0-9_]+(\?thread=[A-Za-z0-9_]+)?"#)
            ?? first(#"https://claude\.ai/code/session_[A-Za-z0-9]+"#)
    }
}

/// The combined state of a commit's check runs.
enum CheckSummary: Equatable {
    case none, running, passed, failed

    /// Settled results don't change unless someone re-runs CI, so they can be cached per commit.
    var isFinal: Bool { self == .passed || self == .failed }

    /// From `GET /repos/{repo}/commits/{sha}/check-runs`. A failure wins over runs still going,
    /// so you hear about it as soon as one job breaks.
    static func parse(_ data: Data) -> CheckSummary {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runs = json["check_runs"] as? [[String: Any]], !runs.isEmpty else { return .none }
        var running = false
        for run in runs {
            if run["status"] as? String != "completed" { running = true; continue }
            switch run["conclusion"] as? String {
            case "failure", "timed_out", "action_required", "startup_failure": return .failed
            default: break // success, neutral, skipped, cancelled, stale
            }
        }
        return running ? .running : .passed
    }
}

/// Watches your GitHub repos for pull requests from Claude cloud sessions and reports them as they
/// open, run CI, fail, turn ready and merge.
///
/// Signs in with the GitHub CLI's token (`gh auth token`), so there's nothing to paste and no token
/// stored by Cove. Watches the repos in `cloudRepos`, or else the ones you pushed to in the last two days.
@MainActor
final class CloudSessionsMonitor {
    enum Status: Equatable {
        case starting
        case noCLI          // gh isn't installed
        case signedOut      // gh is installed but not logged in
        case watching(repos: [String])
        case error(String)
    }

    /// A PR changed phase. `announce` is false for PRs that were already open when Cove started.
    var onChange: ((CloudPR, CloudPR.Phase, _ announce: Bool) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var explicitRepos: [String]
    private var token: String?
    private var repos: [String] = []
    private var reposFetchedAt: Date?
    private var phases: [String: CloudPR.Phase] = [:]
    private var settledChecks: [String: CheckSummary] = [:]   // by head SHA
    private var timer: Timer?
    private let startedAt = Date()
    private var polling = false

    init(repos: [String]) {
        explicitRepos = Self.clean(repos)
    }

    func start() {
        guard timer == nil, token == nil else { return }
        onStatus?(.starting)
        Task { [weak self] in
            let token = await GitHubActionsMonitor.cliToken()
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
        explicitRepos = Self.clean(repos)
        reposFetchedAt = nil
    }

    private static func clean(_ repos: [String]) -> [String] {
        repos.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("/") }
    }

    /// Faster while Claude's work is still going, so CI results show up promptly.
    private func schedule() {
        timer?.invalidate()
        let busy = phases.values.contains { $0.isLive }
        timer = Timer.scheduledTimer(withTimeInterval: busy ? 30 : 90, repeats: false) { [weak self] _ in
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
            if reposFetchedAt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
                repos = explicitRepos.isEmpty ? try await GitHubAPI.recentRepos(token: token) : explicitRepos
                reposFetchedAt = Date()
            }
            onStatus?(.watching(repos: repos))
            for repo in repos {
                let data = try await GitHubAPI.get("/repos/\(repo)/pulls?state=all&sort=updated&direction=desc&per_page=15", token: token)
                for pr in CloudPR.parse(data, repo: repo) where Date().timeIntervalSince(pr.updatedAt) < 24 * 3600 {
                    var summary = CheckSummary.none
                    if pr.state == .open { summary = try await checks(for: pr, token: token) }
                    consider(pr, phase: pr.phase(checks: summary))
                }
            }
        } catch {
            coveLog.error("Cloud sessions: \(error.localizedDescription, privacy: .public)")
            onStatus?(.error(error.localizedDescription))
        }
    }

    private func checks(for pr: CloudPR, token: String) async throws -> CheckSummary {
        if let settled = settledChecks[pr.headSHA] { return settled }
        let data = try await GitHubAPI.get("/repos/\(pr.repo)/commits/\(pr.headSHA)/check-runs?per_page=50", token: token)
        let summary = CheckSummary.parse(data)
        if summary.isFinal {
            if settledChecks.count > 200 { settledChecks.removeAll() }
            settledChecks[pr.headSHA] = summary
        }
        return summary
    }

    private func consider(_ pr: CloudPR, phase: CloudPR.Phase) {
        let old = phases[pr.id]
        phases[pr.id] = phase
        guard old != phase else { return }
        if old == nil {
            // First sighting. Show PRs that are still open; a finished one from before Cove started stays quiet.
            let isNew = pr.createdAt > startedAt
            guard isNew || pr.state == .open else { return }
            onChange?(pr, phase, isNew)
        } else {
            onChange?(pr, phase, true)
        }
    }
}

/// GitHub's REST API, signed in with the GitHub CLI's token (see `GitHubActionsMonitor.cliToken`).
enum GitHubAPI {
    static func get(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(http.statusCode) for \(path)"])
        }
        return data
    }

    /// Repos you own or collaborate on that saw a push in the last two days.
    static func recentRepos(token: String) async throws -> [String] {
        let data = try await get("/user/repos?sort=pushed&per_page=15&affiliation=owner,collaborator", token: token)
        let dates = ISO8601DateFormatter()
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.compactMap { r in
            guard let name = r["full_name"] as? String,
                  let pushed = (r["pushed_at"] as? String).flatMap(dates.date(from:)),
                  Date().timeIntervalSince(pushed) < 2 * 86400 else { return nil }
            return name
        }
    }
}
