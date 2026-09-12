import Foundation

/// Binding-owned types, independent of values, resource sizes and application meaning.
package struct MojoRuntimeResourceSignature: Equatable, Sendable {
    package struct Input: Equatable, Sendable {
        package let element: MojoRuntimeElementType
        package let rank: UInt16

        package init(element: MojoRuntimeElementType, rank: UInt16) {
            self.element = element
            self.rank = rank
        }
    }

    package let arguments: [MojoRuntimeElementType]
    package let inputs: [Input]
    package let results: [MojoRuntimeElementType]
    package let outputs: [MojoRuntimeElementType]
    package let argumentSchema: [UInt8]
    package let resultSchema: [UInt8]
    package let argumentByteCount: Int
    package let resultByteCount: Int

    package init(
        arguments: [MojoRuntimeElementType], inputs: [Input],
        results: [MojoRuntimeElementType], outputs: [MojoRuntimeElementType]
    ) throws {
        guard arguments.count <= Int(UInt16.max), inputs.count <= Int(UInt16.max),
              results.count <= Int(UInt16.max), outputs.count <= Int(UInt16.max) else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        self.arguments = arguments
        self.inputs = inputs
        self.results = results
        self.outputs = outputs
        self.argumentSchema = try MojoRuntimeValueSchema.digest(arguments)
        self.resultSchema = try MojoRuntimeValueSchema.digest(results)
        self.argumentByteCount = arguments.reduce(0) { $0 + Int($1.byteWidth) }
        self.resultByteCount = results.reduce(0) { $0 + Int($1.byteWidth) }
    }

    package var encoded: Data {
        var writer = MojoRuntimeByteWriter()
        for count in [arguments.count, inputs.count, results.count, outputs.count] {
            writer.appendUInt16(UInt16(count))
        }
        for argument in arguments { writer.appendUInt16(argument.rawValue) }
        for input in inputs {
            writer.appendUInt16(input.element.rawValue)
            writer.appendUInt16(input.rank)
        }
        for result in results { writer.appendUInt16(result.rawValue) }
        for output in outputs { writer.appendUInt16(output.rawValue) }
        return writer.data()
    }

    package func validate(_ invocation: MojoRuntimeResourceInvocation) throws {
        guard invocation.argumentSchema == argumentSchema,
              invocation.arguments.count == argumentByteCount,
              invocation.inputs.count == inputs.count,
              invocation.outputs.count == outputs.count else {
            throw MojoRuntimeBufferError.invalidBinding
        }
        for index in inputs.indices {
            guard invocation.inputs[index].element == inputs[index].element,
                  invocation.inputs[index].dimensions.count == Int(inputs[index].rank) else {
                throw MojoRuntimeBufferError.invalidBinding
            }
        }
        for index in outputs.indices {
            guard invocation.outputs[index].element == outputs[index] else {
                throw MojoRuntimeBufferError.invalidBinding
            }
        }
    }
}
