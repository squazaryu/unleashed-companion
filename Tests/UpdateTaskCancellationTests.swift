import XCTest
@testable import UnleashedCompanion

final class UpdateTaskCancellationTests: XCTestCase {
    func testSwiftCancellationIsNotAUserFacingFailure() {
        XCTAssertTrue(UpdateTaskCancellation.isCancellation(CancellationError()))
    }

    func testURLSessionCancellationIsNotAUserFacingFailure() {
        XCTAssertTrue(UpdateTaskCancellation.isCancellation(URLError(.cancelled)))
    }

    func testTransportFailureStillSurfaces() {
        XCTAssertFalse(UpdateTaskCancellation.isCancellation(URLError(.notConnectedToInternet)))
    }
}
