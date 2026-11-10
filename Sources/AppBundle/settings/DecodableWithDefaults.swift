/// The settings of an older MarSpace are read as they are: a field that was added since gets its default value, an
/// optional field is nil, and only a field without a default value is required (what identifies an item, e.g. the key of a
/// shortcut). Put on every struct of the settings: a new field can't make the saved settings unreadable.
///
/// A default value is evaluated in an extension of the struct: a sibling type is named in full (`Settings.WindowCondition()`)
@attached(extension, names: named(init(from:)))
macro DecodableWithDefaults() = #externalMacro(module: "Macros", type: "DecodableWithDefaultsMacro")

/// What ``DecodableWithDefaults()`` generates: the type of each field is inferred from the field
extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, or defaultValue: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue()
    }

    func decode<T: Decodable>(_ key: Key) throws -> T {
        try decode(T.self, forKey: key)
    }

    func decodeIfPresent<T: Decodable>(_ key: Key) throws -> T? {
        try decodeIfPresent(T.self, forKey: key)
    }
}
