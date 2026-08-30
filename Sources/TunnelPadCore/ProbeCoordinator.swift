import Foundation

/// 串行执行探针并丢弃已过期的一批结果。
///
/// 每次新一轮刷新都会提升 generation。旧任务即使底层 URLSession/注入的
/// performer 没有及时响应取消，也不能把旧配置的结果写回 UI。
actor ProbeCoordinator {
    private let service: ProbeService
    private var generation: UInt = 0

    init(service: ProbeService = ProbeService()) {
        self.service = service
    }

    func cancel() {
        generation &+= 1
    }

    func run(_ probes: [(id: String, probe: ProbeConfig)]) async -> [String: ProbeResult]? {
        generation &+= 1
        let currentGeneration = generation
        var results: [String: ProbeResult] = [:]

        for item in probes {
            guard !Task.isCancelled, currentGeneration == generation else { return nil }
            results[item.id] = await service.check(item.probe)
        }

        guard !Task.isCancelled, currentGeneration == generation else { return nil }
        return results
    }
}
