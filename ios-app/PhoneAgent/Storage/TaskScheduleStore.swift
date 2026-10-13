import Foundation

enum TaskScheduleRepeat: String, CaseIterable, Codable, Sendable {
    case once, daily, weekdays, weekly

    var title: String {
        switch self {
        case .once: return "仅一次"
        case .daily: return "每天"
        case .weekdays: return "周一至周五"
        case .weekly: return "每周"
        }
    }
}

enum ScheduledRunState: String, Codable, Sendable {
    case preparing, running, awaitingApproval, finished, interrupted, blocked, stopped

    var title: String {
        switch self {
        case .preparing: return "准备执行"
        case .running: return "执行中"
        case .awaitingApproval: return "等待确认"
        case .finished: return "本轮已结束"
        case .interrupted: return "已中断"
        case .blocked: return "未开始"
        case .stopped: return "已停止"
        }
    }

    var isActive: Bool {
        self == .preparing || self == .running || self == .awaitingApproval
    }
}

struct ScheduledTaskRun: Identifiable, Codable, Equatable, Sendable {
    // The same identity is passed to SessionCommandService; a saved occurrence
    // must never acquire a new command identity after an uncertain dispatch.
    var id = UUID()
    var plannedAt: Date
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var conversationID: UUID? = nil
    var runID: UUID? = nil
    var dispatchAttempted = false
    var state: ScheduledRunState = .preparing
    var detail = ""
}

struct ScheduledPhoneTask: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var goal: String
    var requirements: String
    var firstRunAt: Date
    var timeZoneIdentifier: String
    var repetition: TaskScheduleRepeat
    var providerID: UUID
    var modelID: String
    // Public endpoint identity only. API keys remain in the provider Keychain.
    var providerEndpoint: String
    var isEnabled = true
    var needsReview = false
    var nextRunAt: Date?
    var runs: [ScheduledTaskRun] = []

    init(name: String, goal: String, requirements: String, firstRunAt: Date,
         timeZoneIdentifier: String, repetition: TaskScheduleRepeat,
         providerID: UUID, modelID: String, providerEndpoint: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requirements = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeZoneIdentifier = timeZoneIdentifier
        self.repetition = repetition
        self.providerID = providerID
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerEndpoint = providerEndpoint
        self.firstRunAt = firstRunAt
        self.nextRunAt = nil
        if let calendar = scheduleCalendar, Self.validDate(firstRunAt),
           let minute = calendar.dateInterval(of: .minute, for: firstRunAt) {
            self.firstRunAt = minute.start
        }
        self.nextRunAt = occurrence(after: self.firstRunAt.addingTimeInterval(-1))
    }

    var taskText: String {
        let target = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let constraints = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        return constraints.isEmpty ? target : target + "\n\n要求与结果：\n" + constraints
    }

    /// The calendar belongs to the plan, rather than the phone's current zone.
    /// A missing clock time advances to the next valid time; a repeated clock
    /// time uses its first occurrence so a daylight-saving change cannot double
    /// dispatch a daily plan.
    func occurrence(after date: Date) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              Self.validDate(firstRunAt), let calendar = scheduleCalendar else { return nil }
        if repetition == .once { return firstRunAt > date ? firstRunAt : nil }
        guard date.timeIntervalSince1970 < Self.latestTimestamp else { return nil }
        let lowerBound = max(date, firstRunAt.addingTimeInterval(-1))
        let clock = calendar.dateComponents([.hour, .minute, .weekday], from: firstRunAt)
        var matches = DateComponents(hour: clock.hour, minute: clock.minute, second: 0)
        let weekdays: [Int?]
        switch repetition {
        case .once: return nil
        case .daily: weekdays = [nil]
        case .weekdays: weekdays = [2, 3, 4, 5, 6]
        case .weekly: weekdays = [clock.weekday]
        }
        return weekdays.compactMap { weekday -> Date? in
            matches.weekday = weekday
            guard let candidate = calendar.nextDate(after: lowerBound, matching: matches,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                  Self.validDate(candidate), candidate >= firstRunAt, candidate > date else { return nil }
            return candidate
        }.min()
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 48 else {
            throw AppError.invalid("任务名称不能为空，且不能超过 48 字")
        }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, taskText.count <= 2_000 else {
            throw AppError.invalid("请填写任务目标；目标与要求合计不能超过 2000 字")
        }
        guard scheduleCalendar != nil else { throw AppError.invalid("任务时区不可用，请重新选择执行时间") }
        guard Self.validDate(firstRunAt), nextRunAt.map(Self.validDate) ?? true,
              nextRunAt.map({ $0 >= firstRunAt }) ?? true else {
            throw AppError.invalid("任务执行时间不可用，请重新选择")
        }
        guard !modelID.isEmpty, modelID.count <= 512,
              !providerEndpoint.isEmpty, providerEndpoint.count <= 2_048 else {
            throw AppError.invalid("任务的模型配置不可用，请重新选择供应商与模型")
        }
        guard runs.count <= TaskScheduleStore.maximumRunsPerTask,
              Set(runs.map(\.id)).count == runs.count else {
            throw AppError.invalid("任务运行记录超过上限或存在重复记录")
        }
        for run in runs {
            guard Self.validDate(run.plannedAt), run.startedAt.map(Self.validDate) ?? true,
                  run.completedAt.map(Self.validDate) ?? true, run.detail.count <= 2_000 else {
                throw AppError.invalid("任务运行记录不可用")
            }
        }
    }

    private var scheduleCalendar: Calendar? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // Bound calendar searches and reject non-finite dates before Foundation's
    // calendar matching. The range covers Gregorian years 1 through 9999.
    private static let latestTimestamp: TimeInterval = 253_402_300_799
    private static func validDate(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite && timestamp >= -62_135_596_800 && timestamp <= latestTimestamp
    }
}

@MainActor final class TaskScheduleStore {
    nonisolated static let maximumTasks = 100
    nonisolated static let maximumRunsPerTask = 20
    nonisolated static let maximumFileBytes = 4 * 1_024 * 1_024

    private struct Archive: Codable {
        var version = 1
        var tasks: [ScheduledPhoneTask]
    }
    private let file: URL
    private var hasLoaded = false
    private var canWrite = true

    init(directory: URL? = nil) throws {
        do {
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("PhoneAgent", isDirectory: true)
            guard folder.isFileURL else { throw AppError.invalid("任务存储目录不可用") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var folderURL = folder
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try folderURL.setResourceValues(resource)
            file = folder.appendingPathComponent("scheduled-tasks-v1.json")
        } catch {
            throw AppError.unavailable("定时任务存储目录不可用，请解锁手机后重试")
        }
    }

    func load() throws -> [ScheduledPhoneTask] {
        guard canWrite else { throw AppError.unavailable("定时任务原文件已保留，暂不能读写") }
        guard FileManager.default.fileExists(atPath: file.path) else {
            hasLoaded = true
            return []
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value <= Int64(Self.maximumFileBytes) else {
                throw AppError.invalid("定时任务文件超过上限")
            }
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumFileBytes else { throw AppError.invalid("定时任务文件超过上限") }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw AppError.invalid("定时任务文件版本不兼容") }
            try validate(archive.tasks)
            var tasks = archive.tasks
            for taskIndex in tasks.indices {
                for runIndex in tasks[taskIndex].runs.indices where tasks[taskIndex].runs[runIndex].state.isActive {
                    if tasks[taskIndex].runs[runIndex].dispatchAttempted {
                        tasks[taskIndex].runs[runIndex].state = .interrupted
                        tasks[taskIndex].runs[runIndex].detail = "上次运行已中断，执行结果需要核对；不会自动重放操作"
                        tasks[taskIndex].needsReview = true
                    } else {
                        tasks[taskIndex].runs[runIndex].state = .blocked
                        tasks[taskIndex].runs[runIndex].detail = "上次准备过程已中断，任务尚未开始；请检查后手动执行"
                    }
                }
            }
            hasLoaded = true
            return tasks
        } catch {
            canWrite = false
            throw AppError.unavailable("定时任务未能读取；原文件已保留，暂不能修改")
        }
    }

    func save(_ tasks: [ScheduledPhoneTask]) throws {
        guard canWrite else { throw AppError.unavailable("定时任务原文件已保留，暂不能修改") }
        // Even a caller that saves before loading cannot replace a corrupt
        // existing archive with an empty or newly-created list.
        if !hasLoaded { _ = try load() }
        try validate(tasks)
        do {
            let data = try JSONEncoder().encode(Archive(tasks: tasks))
            guard data.count <= Self.maximumFileBytes else { throw AppError.invalid("定时任务文件超过上限") }
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            throw AppError.unavailable("定时任务未能保存，请解锁手机并检查可用空间后重试")
        }
    }

    private func validate(_ tasks: [ScheduledPhoneTask]) throws {
        guard tasks.count <= Self.maximumTasks, Set(tasks.map(\.id)).count == tasks.count else {
            throw AppError.invalid("最多保存 100 个定时任务，且任务记录不能重复")
        }
        let commandIDs = tasks.flatMap { $0.runs.map(\.id) }
        guard Set(commandIDs).count == commandIDs.count else {
            throw AppError.invalid("任务运行记录存在重复，暂不能修改")
        }
        for task in tasks { try task.validate() }
    }
}
