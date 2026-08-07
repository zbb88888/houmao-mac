import Foundation
import Observation

/// Tracks §7 background jobs so "是否结束" has a single source. On completion it
/// posts `.houmaoAgentJobFinished` (userInfo `jobID`) so the agent can resume and
/// read the result document. Owned by the agent window's view model.
@MainActor
@Observable
final class JobStore {
    private var jobs: [String: AgentJob] = [:]

    func job(_ id: String) -> AgentJob? { jobs[id] }

    func start(_ job: AgentJob) { jobs[job.id] = job }

    func finish(_ id: String, status: AgentJob.Status, error: String? = nil) {
        guard var job = jobs[id] else { return }
        job.status = status
        job.error = error
        jobs[id] = job
        NotificationCenter.default.post(name: .houmaoAgentJobFinished, object: nil, userInfo: ["jobID": id])
    }
}
