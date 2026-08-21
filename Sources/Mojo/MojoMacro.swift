@attached(body)
public macro mojo(
    package: String? = nil,
    function: String? = nil,
    shutdown: String? = nil,
    copyFromHost: String? = nil,
    copyToHost: String? = nil,
    synchronize: String? = nil,
    sessionFactory: String? = nil
) = #externalMacro(
    module: "MojoMacros",
    type: "MojoBodyMacro"
)
