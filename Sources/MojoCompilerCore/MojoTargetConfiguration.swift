package struct MojoTargetConfiguration: Codable, Equatable, Sendable {
    package let triple: String
    package let cpu: String
    package let accelerator: String?

    package init(
        triple: String,
        cpu: String,
        accelerator: String? = nil
    ) throws {
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
        if let accelerator {
            try Self.validate(
                accelerator,
                option: "--target-accelerator",
                allowedPunctuation: [43, 45, 46, 58, 95]
            )
        }

        self.triple = triple
        self.cpu = cpu
        self.accelerator = accelerator
    }

    package var identity: String {
        [triple, cpu, accelerator ?? "none"].joined(separator: "|")
    }

    package var compilerArguments: [String] {
        var arguments = [
            "--target-triple", triple,
            "--target-cpu", cpu,
        ]
        if let accelerator {
            arguments.append(contentsOf: ["--target-accelerator", accelerator])
        }
        return arguments
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
