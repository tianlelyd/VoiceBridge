import AppKit

// 端到端测试用的注入目标：一个输入框，每 50ms 把内容写到 argv[1]（辅助功能写入不会触发 controlTextDidChange）。
// 启动后把 "ready" 写到 stdout；收到 SIGUSR1 就把焦点从输入框移走（测 noFocus），SIGUSR2 再放回来。

final class Controller: NSObject, NSApplicationDelegate {

    let outputPath: String
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 380, height: 28))
    var signalSources: [DispatchSourceSignal] = []

    init(outputPath: String) {
        self.outputPath = outputPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "VoiceBridge E2E"
        window.contentView?.addSubview(field)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusField()

        for (sig, handler) in [(SIGUSR1, { [weak self] in self?.window.makeFirstResponder(nil) }),
                               (SIGUSR2, { [weak self] in self?.focusField() })] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.activate(ignoringOtherApps: true)
                handler()
                print("ack", terminator: "\n")
                fflush(stdout)
            }
            source.resume()
            signalSources.append(source)
        }

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.write() }
        print("ready")
        fflush(stdout)
    }

    func focusField() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    var written: String?

    func write() {
        let text = field.currentEditor()?.string ?? field.stringValue
        guard text != written else { return }
        written = text
        try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller(outputPath: CommandLine.arguments[1])
app.delegate = controller
app.run()
