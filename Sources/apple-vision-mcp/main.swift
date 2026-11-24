import Foundation
import VisionMCPCore

// Launcher only. Everything testable lives in VisionMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// Settings come from the Claude extension manifest, which substitutes the person's
// user_config into this process's arguments. The allow-list arrives this way, so a
// parse that quietly went wrong is a scope that quietly went wrong — which is why
// vision_status prints the configuration it actually ended up with.
await VisionMCPServer.run(
    configuration: Configuration.parse(Array(CommandLine.arguments.dropFirst())))
