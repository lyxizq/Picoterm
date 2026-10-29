// 轻量自跑单测：CLT 工具链的 swift-testing 宏插件（TestingMacros）加载不稳定、
// XCTest 在 CommandLineTools 下不存在，故不依赖任何测试框架——
// swift run PicotermCoreTests，失败计数非零即退出码非零
import Darwin
import PicotermCore

@main
struct Main {
    static func main() {
        var failures = 0
        failures += RemoteCharsetChecks.run()
        failures += WakeOnLANChecks.run()
        failures += LinkOpenPolicyChecks.run()
        failures += TextPreviewAssemblerChecks.run()
        failures += L10nChecks.run()
        if failures == 0 {
            print("ALL TESTS PASSED")
        } else {
            print("\(failures) CHECK(S) FAILED")
            exit(1)
        }
    }
}

/// 断言助手：失败打印并计数
func check(_ condition: Bool, _ name: String, _ detail: String = "") -> Int {
    if condition {
        print("  ✓ \(name)")
        return 0
    }
    print("  ✗ \(name) \(detail)")
    return 1
}

func bytesEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool { a == b }
