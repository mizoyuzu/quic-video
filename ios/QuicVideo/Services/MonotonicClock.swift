import Foundation
import Darwin

enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nowMicroseconds() -> UInt64 {
        let ticks = mach_continuous_time()
        let nanos = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue
            / UInt64(timebase.denom)
        return nanos / 1_000
    }
}
