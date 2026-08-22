import Foundation

// Entry point. The same binary doubles as a one-shot battery reader
// (`IOBluetoothReader.helperFlag`) so the running bridge can fetch a fresh
// IOBluetooth snapshot without restarting — see `readConnectedFresh()`.
if CommandLine.arguments.dropFirst().contains(IOBluetoothReader.helperFlag) {
    let readings = IOBluetoothReader.readConnected()
    let data = (try? JSONEncoder().encode(readings)) ?? Data("[]".utf8)
    FileHandle.standardOutput.write(data)
    exit(0)
}

HeadsetCompanionApp.main()
