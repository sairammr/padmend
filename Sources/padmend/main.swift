import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
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
case "help", "--help", "-h", nil:
    print(usage)
default:
    fail("unknown command '\(arguments[0])'\n\n\(usage)")
}
