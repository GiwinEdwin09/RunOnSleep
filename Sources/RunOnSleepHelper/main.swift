import Foundation
import Darwin
import RunOnSleepCore

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}

guard geteuid() == 0 else { die("RunOnSleepHelper requires root; use the installer.") }
let state = URL(fileURLWithPath: BuildInfo.stateDirectory)
let configURL = state.appendingPathComponent("owner.json")
var stateStat = stat(), configStat = stat()
guard lstat(state.path, &stateStat) == 0, stateStat.st_uid == 0,
      stateStat.st_mode & S_IFMT == S_IFDIR, stateStat.st_mode & 0o022 == 0,
      lstat(configURL.path, &configStat) == 0, configStat.st_mode & S_IFMT == S_IFREG else {
    die("Unsafe helper state directory or owner configuration.")
}
struct Owner: Decodable { let uid: UInt32 }
let owner: Owner
do {
    let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
          ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
        die("Unsafe owner configuration.")
    }
    owner = try JSONDecoder().decode(Owner.self, from: Data(contentsOf: configURL))
    guard owner.uid >= 501 else { die("Invalid installing user.") }
} catch { die("Cannot read helper owner configuration.") }

// Lock before recovery: a second invocation must never clean up a live daemon's session.
let lock = open(state.appendingPathComponent("helper.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { die("Another helper is running.") }
let backend = MacPowerBackend(journalURL: state.appendingPathComponent("journal.json"))
let engine = SessionEngine(backend: backend, authorizedUID: owner.uid)
engine.recover()
if CommandLine.arguments.contains("--recover-only") {
    let result = engine.status()
    print(result.message)
    if result.environment.sleepDisabled == true { print("Global SleepDisabled is still enabled; normal sleep is not assured.") }
    exit(result.unresolved ? 2 : 0)
}
guard CommandLine.arguments.count == 1 else { die("Unknown helper arguments.") }

let directory = "/var/run/com.runonsleep.helper"
if mkdir(directory, 0o711) != 0 && errno != EEXIST { die("Cannot create socket directory.") }
var st = stat()
guard lstat(directory, &st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFDIR,
      st.st_mode & 0o022 == 0 else { die("Unsafe socket directory.") }
let server = socket(AF_UNIX, SOCK_STREAM, 0)
guard server >= 0 else { die("Cannot create listener.") }
unlink(BuildInfo.socketPath)
var address = try UnixTransport.address(BuildInfo.socketPath)
let oldMask = umask(0o077)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
umask(oldMask)
guard bound == 0, chown(BuildInfo.socketPath, owner.uid, 0) == 0,
      chmod(BuildInfo.socketPath, 0o600) == 0, listen(server, 8) == 0 else { die("Cannot bind secured listener.") }

let queue = DispatchQueue(label: "com.runonsleep.session")
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: 5)
timer.setEventHandler { engine.tick() }
timer.resume()
let thermalObserver = NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
) { _ in queue.async { engine.tick() } }

signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
    source.setEventHandler {
        engine.shutdown(); unlink(BuildInfo.socketPath); close(server); exit(0)
    }
    source.resume(); return source
}

DispatchQueue.global(qos: .utility).async {
    while true {
        let fd = accept(server, nil, nil)
        if fd < 0 { if errno == EINTR { continue }; usleep(100_000); continue }
        UnixTransport.configure(fd)
        do {
            let peer = try UnixTransport.peer(fd)
            guard peer.uid == owner.uid else { close(fd); continue }
            let request = try JSONDecoder().decode(Request.self, from: UnixTransport.readFrame(fd))
            let response = queue.sync { engine.handle(request, peer: peer) }
            try UnixTransport.writeFrame(response, to: fd)
        } catch { /* Invalid frames get no response; never log token-bearing payloads. */ }
        close(fd)
    }
}
dispatchMain()
