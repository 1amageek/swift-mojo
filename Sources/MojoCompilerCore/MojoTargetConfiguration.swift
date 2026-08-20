package struct MojoTargetConfiguration: Codable, Equatable, Sendable {
    package let triple: String
    package let cpu: String

    package init(triple: String, cpu: String) throws {
        try Self.validate(
            triple,
            option: "--target-triple",
            allowedPunctuation: [45, 46, 95]
        )
        try Self.validate(
            cpu,
            option: "--target-cpu",
            allowedPunctuation: [43, 45, 46, 95]
        )

        self.triple = triple
        self.cpu = cpu
    }

    package var compilerArguments: [String] {
        [
            "--target-triple", triple,
            "--target-cpu", cpu,
        ]
    }

    private static func validate(
        _ value: String,
        option: String,
        allowedPunctuation: Set<UInt8>
    ) throws {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ codeUnit in
                  isASCIIAlphaNumeric(codeUnit)
                      || allowedPunctuation.contains(codeUnit)
              }) else {
            throw MojoCompilerToolError.invalidTargetValue(
                option: option,
                value: value
            )
        }
    }

    private static func isASCIIAlphaNumeric(_ codeUnit: UInt8) -> Bool {
        (codeUnit >= 48 && codeUnit <= 57)
            || (codeUnit >= 65 && codeUnit <= 90)
            || (codeUnit >= 97 && codeUnit <= 122)
    }
}
