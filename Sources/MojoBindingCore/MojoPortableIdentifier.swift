package enum MojoPortableIdentifier {
    private static let reservedWords: Set<String> = [
        "False", "None", "Self", "True", "and", "as", "assert", "break",
        "comptime", "continue", "def", "elif", "else", "except", "finally",
        "for", "from", "if", "import", "in", "is", "not", "or", "pass",
        "raise", "ref", "return", "struct", "trait", "try", "var", "while",
        "with",
    ]

    package static func isValid(_ value: String) -> Bool {
        guard !reservedWords.contains(value),
              let first = value.utf8.first,
              first == 95
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { codeUnit in
            codeUnit == 95
                || (codeUnit >= 48 && codeUnit <= 57)
                || (codeUnit >= 65 && codeUnit <= 90)
                || (codeUnit >= 97 && codeUnit <= 122)
        }
    }
}
