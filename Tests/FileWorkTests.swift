import Synchronization
import XCTest

final class FileWorkTests: XCTestCase {
    func testReadsAndShutdownWaitForOrderedBackgroundWrites() async {
        let work = FileWork(), values = Mutex<[Int]>([]), onMain = Mutex(false)
        for i in 0..<100 {
            work.submit {
                if Thread.isMainThread { onMain.withLock { $0 = true } }
                values.withLock { $0.append(i) }
            }
        }
        let read = await work.read { values.withLock { $0 } }
        XCTAssertEqual(read, Array(0..<100))
        work.submit { values.withLock { $0.append(100) } }
        await work.drain()
        XCTAssertEqual(values.withLock { $0 }, Array(0...100))
        XCTAssertFalse(onMain.withLock { $0 })
    }
}
