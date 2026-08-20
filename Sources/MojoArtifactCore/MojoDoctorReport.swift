package struct MojoDoctorReport: Codable, Equatable, Sendable {
    package struct Check: Codable, Equatable, Sendable {
        package enum Status: String, Codable, Equatable, Sendable {
            case passed
            case failed
        }

        package let name: String
        package let status: Status
        package let detail: String

        package init(name: String, status: Status, detail: String) {
            self.name = name
            self.status = status
            self.detail = detail
        }
    }

    package let checks: [Check]

    package init(checks: [Check]) {
        self.checks = checks
    }

    package var isHealthy: Bool {
        checks.allSatisfy { $0.status == .passed }
    }
}
