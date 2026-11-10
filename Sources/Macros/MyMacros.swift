import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct FileIdMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) -> ExprSyntax {
        "MyFileId.init(file: #fileID, line: #line, column: #column, function: #function)"
    }
}

public struct FilePathMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) -> ExprSyntax {
        "MyFileId.init(file: #filePath, line: #line, column: #column, function: #function)"
    }
}

/// `init(from:)` for a struct whose stored fields may be missing: e.g. the settings of an older MarSpace, saved before a
/// field existed. A field with a default value gets it, an optional field is nil (an encoder leaves nil out), a field
/// without a default value is required. Only the fields in the struct body count, like the synthesized `Decodable`
public struct DecodableWithDefaultsMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        var assignments: [String] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            else { continue }
            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
            for binding in variable.bindings {
                // Computed properties aren't stored; a `let` with a value can't be decoded
                guard binding.accessorBlock == nil, !(isLet && binding.initializer != nil),
                      let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.trimmedDescription
                else { continue }
                let type = binding.typeAnnotation?.type
                let isOptional = type?.is(OptionalTypeSyntax.self) == true || type?.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                if isOptional {
                    assignments.append("self.\(name) = try container.decodeIfPresent(.\(name))")
                } else if let value = binding.initializer?.value {
                    assignments.append("self.\(name) = try container.decode(.\(name), or: \(value.trimmedDescription))")
                } else {
                    assignments.append("self.\(name) = try container.decode(.\(name))")
                }
            }
        }
        let source: DeclSyntax = """
            extension \(type.trimmed) {
                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    \(raw: assignments.joined(separator: "\n"))
                }
            }
            """
        return [source.cast(ExtensionDeclSyntax.self)]
    }
}

@main
struct AeroSpaceMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [FileIdMacro.self, FilePathMacro.self, DecodableWithDefaultsMacro.self]
}
