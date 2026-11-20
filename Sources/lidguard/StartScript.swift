import Darwin
import Foundation

// Pure helpers shared by the GUI and the watchdog, kept free of AppKit so
// tests/test_script.sh can compile them on their own.

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// The admin start script, passed to `do shell script` as an argument.
/// Nothing is written to a shared temp file, so there is no file to swap
/// between writing and running it. The generation number is bumped here,
/// as root, in the root-owned state dir.
func buildStartScript(exe: String, closedUntil: Int, guiPid: Int32, acOnly: Bool,
                      unlimited: Bool, armNow: Bool, requestDir: String, requestUid: UInt32,
                      stateDir: String = "/var/run/lidguard") -> String {
    func q(_ v: String) -> String { "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let d = q(stateDir)
    return """
    D=\(d)
    if [ -L "$D" ]; then echo "상태 폴더가 링크입니다"; exit 1; fi
    /bin/mkdir -p "$D" && /usr/sbin/chown root:wheel "$D" && /bin/chmod 755 "$D" || exit 1
    G=$(/bin/cat "$D/lidguard_gen" 2>/dev/null | /usr/bin/tr -cd '0-9')
    G=$(( ${G:-0} + 1 ))
    /bin/rm -f "$D/lidguard_gen" "$D/lidguard_watchdog.pid"
    echo "$G" > "$D/lidguard_gen" && /bin/chmod 644 "$D/lidguard_gen" || exit 1
    \(armNow ? "/usr/bin/pmset -a disablesleep 1 || exit 1" : ": paused on battery")
    \(q(exe)) --watchdog --daemonize --gen "$G" --closed-until \(closedUntil) --sleepnow-if-closed \\
      --gui-pid \(guiPid) --pidfile "$D/lidguard_watchdog.pid" \\
      --request-dir \(q(requestDir)) --request-uid \(requestUid)\(acOnly ? " --ac-only" : "")\(unlimited ? " --closed-unlimited" : "") \\
      >>"$D/lidguard_watchdog.log" 2>&1
    for i in $(/usr/bin/seq 1 30); do
      PID=$(/usr/bin/tr -d '[:space:]' < "$D/lidguard_watchdog.pid" 2>/dev/null)
      if [ -n "$PID" ] && /bin/kill -0 "$PID" 2>/dev/null; then
        exit 0
      fi
      /bin/sleep 0.1
    done
    /usr/bin/pmset -a disablesleep 0
    echo "워치독이 시작되지 않았습니다"
    exit 1
    """
}

/// File names inside the user's request dir (~/Library/Application Support/lidguard).
enum RequestFiles {
    static let stop = "lidguard_stop"
    static let closedUntil = "lidguard_request_until"
    static let openUntil = "lidguard_request_open_until"
    static let openState = "lidguard_open_state"
}

/// Reads a small request file the user wrote, safely from root:
/// the dir must be a real directory owned by `uid`, the file a regular file
/// owned by `uid`, opened without following symlinks, at most 64 bytes.
/// Returns the trimmed text, or nil when absent or rejected.
func readUserRequest(_ path: String, uid: uid_t, dir: String) -> String? {
    var ds = stat()
    guard lstat(dir, &ds) == 0, (ds.st_mode & S_IFMT) == S_IFDIR, ds.st_uid == uid else { return nil }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var fs = stat()
    guard fstat(fd, &fs) == 0, (fs.st_mode & S_IFMT) == S_IFREG, fs.st_uid == uid, fs.st_size <= 64 else { return nil }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, 64)
    guard n >= 0 else { return nil }
    return String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
