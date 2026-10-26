// 终端链接点击口径单测：scheme 白名单、file: host 限制、路径绝对化与行号后缀
import Foundation
import PicotermCore

enum LinkOpenPolicyChecks {
    static func run() -> Int {
        print("LinkOpenPolicy:")
        var n = 0
        func classify(_ link: String, remote: Bool = true, cwd: String? = "/srv/app", home: String? = "/home/u") -> LinkTarget {
            LinkOpenPolicy.classify(link, isRemote: remote, currentDirectory: cwd, home: home)
        }

        n += check(classify("https://example.com/a?b=1") == .web(URL(string: "https://example.com/a?b=1")!), "httpsIsWeb")
        n += check(classify("mailto:a@b.c") == .web(URL(string: "mailto:a@b.c")!), "mailtoIsWeb")
        n += check(classify("smb://nas/share") == .rejected, "smbRejected")
        n += check(classify("ssh://root@10.0.0.1") == .rejected, "sshRejected")
        n += check(classify("git://github.com/x/y.git") == .rejected, "gitRejected")
        n += check(classify("host:/tmp/x") == .rejected, "scpStyleRejected")

        n += check(classify("file:///etc/hosts", remote: false) == .localFile(URL(fileURLWithPath: "/etc/hosts")), "fileURLLocal")
        n += check(classify("file:///etc/hosts") == .remotePath("/etc/hosts"), "fileURLRemote")
        n += check(classify("file://evil/share/x", remote: false) == .rejected, "fileURLWithHostRejected")

        n += check(classify("/var/log/syslog") == .remotePath("/var/log/syslog"), "absoluteRemote")
        n += check(classify("/usr/local/bin", remote: false) == .localFile(URL(fileURLWithPath: "/usr/local/bin")), "absoluteLocal")
        n += check(classify("/src/main.c:12:5") == .remotePath("/src/main.c"), "lineSuffixStripped")
        n += check(classify("/etc/hosts,") == .remotePath("/etc/hosts"), "trailingPunctuationStripped")
        n += check(classify("~/.ssh/config") == .remotePath("/home/u/.ssh/config"), "tildeExpanded")
        n += check(classify("~") == .remotePath("/home/u"), "bareTilde")
        n += check(classify("~/x", home: nil) == .rejected, "tildeWithoutHomeRejected")
        n += check(classify("~bob/x") == .rejected, "tildeUserRejected")
        n += check(classify("./a/../b/./c") == .remotePath("/srv/app/b/c"), "relativeNormalized")
        n += check(classify("../lib/x.so") == .remotePath("/srv/lib/x.so"), "parentRelative")
        n += check(classify("src/main.go", cwd: nil) == .rejected, "relativeWithoutCwdRejected")
        n += check(classify("$HOME/x") == .rejected, "variableRejected")
        n += check(LinkOpenPolicy.normalize("//a///b/../c/") == "/a/c", "normalizeSlashes")
        n += check(LinkOpenPolicy.normalize("/../..") == "/", "normalizeAboveRoot")
        return n
    }
}
