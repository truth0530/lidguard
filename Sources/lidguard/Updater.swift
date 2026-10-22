import CryptoKit
import Foundation

/// GitHub Releases based self-update.
/// The release must carry `<name>.zip` and `<name>.zip.sha256`. The update is
/// refused when the checksum file is missing or does not match, when the bundle
/// id differs, or when `codesign --verify` fails.
struct ReleaseInfo {
    let version: String
    let zipURL: URL
    let shaURL: URL?
    let pageURL: URL
}

let releasesPageURL = URL(string: "https://github.com/truth0530/lidguard/releases/latest")!
private let latestReleaseAPI = URL(string: "https://api.github.com/repos/truth0530/lidguard/releases/latest")!

func currentAppVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

func versionParts(_ raw: String) -> [Int] {
    let trimmed = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
    return trimmed.split(separator: ".").map { part in
        Int(part.prefix { $0.isNumber }) ?? 0
    }
}

func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    let a = versionParts(candidate)
    let b = versionParts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

private func fetchData(_ url: URL, timeout: TimeInterval) -> Result<Data, Error> {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.setValue("lidguard/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let done = DispatchSemaphore(value: 0)
    var result: Result<Data, Error> = .failure(UpdateFailure("응답이 없습니다"))
    // Ephemeral and invalidated after use: no cache or connection pool stays resident.
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    session.dataTask(with: request) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(UpdateFailure("서버 응답 \(http.statusCode)"))
        } else if let data {
            result = .success(data)
        }
        done.signal()
    }.resume()
    done.wait()
    return result
}

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func fetchLatestRelease() -> Result<ReleaseInfo, Error> {
    switch fetchData(latestReleaseAPI, timeout: 15) {
    case .failure(let error):
        return .failure(error)
    case .success(let data):
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            return .failure(UpdateFailure("릴리스 정보를 읽지 못했습니다"))
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPageURL
        func assetURL(_ match: (String) -> Bool) -> (String, URL)? {
            for asset in assets {
                guard let name = asset["name"] as? String, match(name),
                      let raw = asset["browser_download_url"] as? String,
                      let url = URL(string: raw) else { continue }
                return (name, url)
            }
            return nil
        }
        guard let (zipName, zipURL) = assetURL({ $0.hasSuffix(".zip") }) else {
            return .failure(UpdateFailure("릴리스에 앱 압축 파일이 없습니다"))
        }
        let sha = assetURL({ $0 == zipName + ".sha256" })?.1
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return .success(ReleaseInfo(version: version, zipURL: zipURL, shaURL: sha, pageURL: page))
    }
}

private func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
    } catch {
        return (1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Downloads, checks and unpacks the release. Returns the new `.app` URL.
func prepareUpdate(_ release: ReleaseInfo) -> Result<URL, Error> {
    guard let shaURL = release.shaURL else {
        return .failure(UpdateFailure("체크섬 파일이 없어 업데이트를 멈췄습니다"))
    }
    let expected: String
    switch fetchData(shaURL, timeout: 15) {
    case .failure(let error): return .failure(error)
    case .success(let data):
        let text = String(data: data, encoding: .utf8) ?? ""
        expected = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first.map { String($0).lowercased() } ?? ""
    }
    guard expected.count == 64 else {
        return .failure(UpdateFailure("체크섬 파일 형식이 올바르지 않습니다"))
    }

    let zipData: Data
    switch fetchData(release.zipURL, timeout: 120) {
    case .failure(let error): return .failure(error)
    case .success(let data): zipData = data
    }
    let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else {
        return .failure(UpdateFailure("내려받은 파일의 체크섬이 맞지 않습니다"))
    }

    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("lidguard-update-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try zipData.write(to: work.appendingPathComponent("update.zip"))
    } catch {
        return .failure(error)
    }
    let unpack = work.appendingPathComponent("unpacked")
    let (unzipStatus, unzipOut) = run("/usr/bin/ditto", ["-x", "-k", work.appendingPathComponent("update.zip").path, unpack.path])
    guard unzipStatus == 0 else {
        return .failure(UpdateFailure("압축을 풀지 못했습니다 · \(unzipOut)"))
    }
    guard let appName = (try? fm.contentsOfDirectory(atPath: unpack.path))?.first(where: { $0.hasSuffix(".app") }) else {
        return .failure(UpdateFailure("압축 파일 안에 앱이 없습니다"))
    }
    let newApp = unpack.appendingPathComponent(appName)
    guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
          let bundleID = info["CFBundleIdentifier"] as? String,
          let newVersion = info["CFBundleShortVersionString"] as? String else {
        return .failure(UpdateFailure("새 앱 정보를 읽지 못했습니다"))
    }
    guard bundleID == Bundle.main.bundleIdentifier else {
        return .failure(UpdateFailure("다른 앱이 들어 있어 업데이트를 멈췄습니다"))
    }
    guard newVersion == release.version else {
        return .failure(UpdateFailure("릴리스 버전(\(release.version))과 앱 버전(\(newVersion))이 다릅니다"))
    }
    let (signStatus, signOut) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
    guard signStatus == 0 else {
        return .failure(UpdateFailure("새 앱 서명 확인 실패 · \(signOut)"))
    }
    return .success(newApp)
}

/// Starts a detached script that swaps the bundle after this process exits and
/// reopens the app. Restores the old bundle when the copy fails.
func launchInstaller(newApp: URL) -> Error? {
    let target = Bundle.main.bundleURL
    if target.path.contains("/AppTranslocation/") {
        return UpdateFailure("앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도하세요")
    }
    let parent = target.deletingLastPathComponent().path
    guard FileManager.default.isWritableFile(atPath: parent) else {
        return UpdateFailure("\(parent) 폴더에 쓸 권한이 없습니다")
    }
    let script = """
    #!/bin/bash
    PID="$1"; OLD="$2"; NEW="$3"
    for i in $(seq 1 150); do /bin/kill -0 "$PID" 2>/dev/null || break; /bin/sleep 0.1; done
    BACKUP="$(/usr/bin/mktemp -d /tmp/lidguard-old.XXXXXX)"
    if ! /bin/mv "$OLD" "$BACKUP/"; then /usr/bin/open "$OLD"; exit 1; fi
    if /usr/bin/ditto "$NEW" "$OLD"; then
      /usr/bin/xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
      /usr/bin/open "$OLD"
      /bin/rm -rf "$BACKUP"
      echo "updated $OLD"
    else
      /bin/rm -rf "$OLD"
      /bin/mv "$BACKUP/$(/usr/bin/basename "$OLD")" "$OLD"
      /usr/bin/open "$OLD"
      echo "update copy failed, restored $OLD"
      exit 1
    fi
    """
    let scriptPath = "/tmp/lidguard_update.sh"
    do {
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    } catch {
        return error
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [scriptPath, String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path]
    let log = FileHandle(forWritingAtPath: "/tmp/lidguard_update.log") ?? {
        FileManager.default.createFile(atPath: "/tmp/lidguard_update.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/lidguard_update.log")
    }()
    log?.seekToEndOfFile()
    proc.standardOutput = log
    proc.standardError = log
    do {
        try proc.run()
    } catch {
        return error
    }
    return nil
}
