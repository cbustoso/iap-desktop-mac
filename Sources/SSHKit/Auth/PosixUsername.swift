/// Validación y derivación de usuario POSIX para autorización de llaves SSH vía
/// metadata (cuando OS Login no está habilitado).
///
/// Paridad con `LinuxUser` (C#, `Session/Protocol/Ssh/LinuxUser.cs`): patrón IEEE Std
/// 1003.1-2017 §3.437 "User Name" (conjunto de caracteres de nombre de archivo portable,
/// sin '-' como primer carácter), longitud máxima 32, y sugerencia derivada del email
/// (parte local antes de '@', minúsculas, no alfanumérico → '_', prefijo 'g' si no
/// empieza por letra).
public enum PosixUsername {
    static let maxLength = 32

    /// `true` si `username` cumple el patrón POSIX y la longitud máxima.
    public static func isValid(_ username: String) -> Bool {
        guard !username.isEmpty, username.count <= maxLength else { return false }
        guard let first = username.first, isValidFirstCharacter(first) else { return false }
        return username.dropFirst().allSatisfy(isValidTrailingCharacter)
    }

    /// Deriva un nombre de usuario POSIX a partir de un email (parte local).
    public static func suggest(fromEmail email: String) -> String {
        let localPart = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? email

        var characters = localPart.lowercased().map { character -> Character in
            isAsciiLetterOrDigit(character) ? character : "_"
        }
        if characters.isEmpty {
            characters = ["_"]
        }
        if !isAsciiLetter(characters[0]) {
            characters.insert("g", at: 0)
        }
        return String(characters.prefix(maxLength))
    }

    private static func isValidFirstCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == ".")
    }

    private static func isValidTrailingCharacter(_ character: Character) -> Bool {
        isValidFirstCharacter(character) || character == "-"
    }

    private static func isAsciiLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isAsciiLetterOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
