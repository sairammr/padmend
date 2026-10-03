import PadmendKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "menubar":
    runMenuBarApp()
case "selftest":
    commandSelfTest()
case "doctor":
    commandDoctor()
case "devices":
    commandDevices()
case "probe":
    commandProbe()
case "calibrate":
    commandCalibrate()
case "map":
    commandMap()
case "run":
    commandRun()
case "reset":
    commandReset()
case "help", "--help", "-h":
    print(usage)
case nil:
    // Launched from Finder inside the app bundle there are no arguments, so
    // that is the menu bar app. Run bare from a shell it is a CLI, and the
    // useful thing to print is how to use it.
    if Bundle.main.bundleIdentifier != nil {
        runMenuBarApp()
    } else {
        print(usage)
    }
default:
    fail("unknown command '\(arguments[0])'\n\n\(usage)")
}
