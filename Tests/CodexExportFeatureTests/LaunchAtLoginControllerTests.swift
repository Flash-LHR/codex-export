import XCTest
@testable import CodexExportFeature

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testRequiresApprovalIsRegisteredAndToggleUnregisters() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.isRegistered)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertNotNil(controller.errorMessage)

        controller.toggle()

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertFalse(controller.isRegistered)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisabledToggleRegistersAndRefreshesEnabledState() {
        let service = FakeLaunchAtLoginService(status: .disabled)
        let controller = LaunchAtLoginController(service: service)

        controller.toggle()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(controller.accessibilityValue, "已开启")
    }

    func testRegistrationFailureRemainsVisible() {
        let service = FakeLaunchAtLoginService(status: .disabled)
        service.registerError = TestFailure.expected
        let controller = LaunchAtLoginController(service: service)

        controller.toggle()

        XCTAssertFalse(controller.isRegistered)
        XCTAssertNotNil(controller.errorMessage)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .disabled
    }
}

private enum TestFailure: Error {
    case expected
}
