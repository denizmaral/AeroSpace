import Common

struct PerMonitorValue<Value: Equatable>: Equatable {
    let description: MonitorDescription
    let value: Value
}
extension PerMonitorValue: Sendable where Value: Sendable {}

enum DynamicConfigValue<Value: Equatable>: Equatable {
    case constant(Value)
    case perMonitor([PerMonitorValue<Value>], default: Value)
}
extension DynamicConfigValue: Sendable where Value: Sendable {}

extension DynamicConfigValue {
    @MainActor func getValue(for monitor: any MonitorInfo) -> Value {
        switch self {
            case .constant(let value): return value
            case .perMonitor(let array, let defaultValue):
                let sortedMonitors = globalSortedMonitorInfos
                return array
                    .lazy
                    .compactMap {
                        $0.description.resolveMonitorInfo(sortedMonitors: sortedMonitors)?.rect.topLeftCorner == monitor.rect.topLeftCorner
                            ? $0.value
                            : nil
                    }
                    .first ?? defaultValue
        }
    }
}
