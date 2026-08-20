import Mojo

@mojo
func add(_ a: Int32, _ b: Int32) -> Int32 {
    return a + b
}

@main
enum ExampleApplication {
    static func main() {
        print(add(20, 22))
    }
}
