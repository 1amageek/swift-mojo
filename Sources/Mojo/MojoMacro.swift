@attached(body)
public macro mojo(
    package: String? = nil,
    function: String? = nil
) = #externalMacro(
    module: "MojoMacros",
    type: "MojoBodyMacro"
)
