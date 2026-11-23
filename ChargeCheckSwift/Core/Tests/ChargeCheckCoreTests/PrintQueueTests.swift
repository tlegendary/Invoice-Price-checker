import XCTest
@testable import ChargeCheckCore

final class PrintQueueTests: XCTestCase {
    private func receipt(_ sale: String) -> PrintJob { PrintJob(kind: .receipt, source: sale, text: "Receipt \(sale)", at: "2026-11-23T10:00:00Z") }

    func testAPrinterThatsOffNeverLosesTheReceipt() {
        var q = PrintQueue()
        q.add(receipt("s1"))
        let job = q.next!
        q.failed(job.id, error: "printer off")
        XCTAssertEqual(q.next?.id, job.id, "still waiting after one failure")
        q.failed(job.id, error: "printer off")
        q.failed(job.id, error: "printer off")
        XCTAssertNil(q.next, "after 3 failures it waits for a person")
        XCTAssertEqual(q.failedJobs.count, 1)
        _ = q.reprint(job.id, at: "2026-11-23T10:05:00Z")
        XCTAssertEqual(q.next?.id, job.id, "tapping Print again puts the same job back, not a copy")
        q.printed(job.id)
        XCTAssertEqual(q.waiting, 0)
    }

    func testTheSameReceiptIsNeverQueuedTwiceByAccident() {
        var q = PrintQueue()
        XCTAssertTrue(q.add(receipt("s1")))
        XCTAssertFalse(q.add(receipt("s1")))
        XCTAssertEqual(q.waiting, 1)
    }

    func testAReprintOnPurposeIsMarkedCopy() {
        var q = PrintQueue()
        q.add(receipt("s1"))
        q.printed(q.next!.id)
        let copy = q.reprint(q.jobs[0].id, at: "2026-11-23T11:00:00Z")
        XCTAssertTrue(copy?.text.hasPrefix("*** COPY ***") ?? false)
        XCTAssertEqual(q.next?.id, copy?.id)
        q.trim(before: "2026-11-23T10:30:00Z")
        XCTAssertEqual(q.jobs.count, 1, "the old printed job is dropped, the waiting copy kept")
    }
}
