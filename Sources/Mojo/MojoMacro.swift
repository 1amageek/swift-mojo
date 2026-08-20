@attached(body)
public macro mojo() = #externalMacro(
    module: "MojoMacros",
    type: "MojoBodyMacro"
)
