import Foundation

/// Rufus-style Windows Setup customisations, implemented through an autounattend.xml
/// placed at the root of the USB drive (Windows Setup picks it up automatically).
public struct UnattendOptions: Equatable {
    /// Windows 11 only: bypass TPM 2.0, Secure Boot and 4 GB+ RAM requirements.
    public var bypassHardwareChecks = false
    /// Windows 11 only: allow installing without a Microsoft account / internet connection.
    public var bypassOnlineAccount = false
    /// Create a local account with this name (empty = don't).
    public var localAccountName = ""
    /// Answer "no" to all privacy / data-collection questions.
    public var disableDataCollection = false

    public init() {}

    public var isEmpty: Bool {
        !bypassHardwareChecks && !bypassOnlineAccount && !disableDataCollection
            && localAccountName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public enum Unattend {
    /// Windows' encoding of an empty password: base64(UTF-16LE("" + "Password")). Same as Rufus.
    static let blankPassword = "UABhAHMAcwB3AG8AcgBkAA=="

    /// Names Windows won't accept for a new local account.
    static let reservedNames: Set<String> = [
        "administrator", "guest", "defaultaccount", "wdagutilityaccount", "system", "network service",
        "local service", "none", "everyone", "users", "administrators", "guests", "power users",
    ]

    /// Maps the ISO's EFI loaders ("x64", "arm64", "x86") to unattend architecture names.
    public static func unattendArch(_ isoArch: String) -> String? {
        switch isoArch.lowercased() {
        case "x64": return "amd64"
        case "arm64": return "arm64"
        case "x86": return "x86"
        default: return nil
        }
    }

    /// Removes characters Windows doesn't allow in user names: " / \ [ ] : ; | = , + * ? < > @
    public static func sanitizeUserName(_ s: String) -> String {
        let bad = Set("\"/\\[]:;|=,+*?<>@")
        let cleaned = String(s.trimmingCharacters(in: .whitespaces).filter { !bad.contains($0) }.prefix(20))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return reservedNames.contains(cleaned.lowercased()) ? "" : cleaned
    }

    static func component(_ name: String, arch: String, body: String) -> String {
        """
            <component name="\(name)" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        \(body)
            </component>

        """
    }

    static func commandList(_ list: String, _ item: String, pathTag: String, _ commands: [String]) -> String {
        var s = "      <\(list)>\n"
        for (i, c) in commands.enumerated() {
            s += """
                    <\(item) wcm:action="add">
                      <Order>\(i + 1)</Order>
                      <\(pathTag)>\(escape(c))</\(pathTag)>
                    </\(item)>

            """
        }
        return s + "      </\(list)>\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Builds the answer file. Windows 11-only tweaks are dropped for other versions,
    /// and components are written only for the ISO's own architecture(s).
    public static func xml(_ o: UnattendOptions, archs isoArchs: [String], isWindows11: Bool) -> String? {
        let archs = isoArchs.compactMap(unattendArch)
        guard !archs.isEmpty else { return nil }

        let user = sanitizeUserName(o.localAccountName)
        let bypassChecks = o.bypassHardwareChecks && isWindows11
        let bypassNRO = o.bypassOnlineAccount && isWindows11
        guard bypassChecks || bypassNRO || o.disableDataCollection || !user.isEmpty else { return nil }

        var passes = ""

        if bypassChecks {
            let cmds = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"]
                .map { "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \($0) /t REG_DWORD /d 1 /f" }
            let body = commandList("RunSynchronous", "RunSynchronousCommand", pathTag: "Path", cmds)
            passes += "  <settings pass=\"windowsPE\">\n"
                + archs.map { component("Microsoft-Windows-Setup", arch: $0, body: body) }.joined()
                + "  </settings>\n"
        }

        if bypassNRO {
            let cmds = ["reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f"]
            let body = commandList("RunSynchronous", "RunSynchronousCommand", pathTag: "Path", cmds)
            passes += "  <settings pass=\"specialize\">\n"
                + archs.map { component("Microsoft-Windows-Deployment", arch: $0, body: body) }.joined()
                + "  </settings>\n"
        }

        if o.disableDataCollection || !user.isEmpty {
            var inner = ""
            if o.disableDataCollection || !user.isEmpty {
                inner += "      <OOBE>\n"
                if o.disableDataCollection {
                    inner += "        <HideEULAPage>true</HideEULAPage>\n        <ProtectYourPC>3</ProtectYourPC>\n"
                }
                // Only hide the Microsoft-account screens when we actually provide an account,
                // otherwise OOBE has no way to create a user.
                if !user.isEmpty { inner += "        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>\n" }
                inner += "      </OOBE>\n"
            }
            if !user.isEmpty {
                let u = escape(user)
                inner += """
                      <UserAccounts>
                        <LocalAccounts>
                          <LocalAccount wcm:action="add">
                            <Name>\(u)</Name>
                            <DisplayName>\(u)</DisplayName>
                            <Group>Administrators;Power Users</Group>
                            <Password>
                              <Value>\(blankPassword)</Value>
                              <PlainText>false</PlainText>
                            </Password>
                          </LocalAccount>
                        </LocalAccounts>
                      </UserAccounts>

                """
                // Like Rufus: blank password at first, Windows asks for a new one at first logon.
                inner += commandList("FirstLogonCommands", "SynchronousCommand", pathTag: "CommandLine", [
                    "net user \"\(user)\" /logonpasswordchg:yes",
                    "net accounts /maxpwage:unlimited",
                ])
            }
            passes += "  <settings pass=\"oobeSystem\">\n"
                + archs.map { component("Microsoft-Windows-Shell-Setup", arch: $0, body: inner) }.joined()
                + "  </settings>\n"
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
        \(passes)</unattend>

        """
    }
}
