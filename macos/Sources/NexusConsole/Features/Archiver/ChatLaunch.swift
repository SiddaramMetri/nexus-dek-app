import AppKit
import NexusCore

/// A chat opened in the conversation pane — live or archived — plus the
/// project folder it belongs to (decoded by the Archiver core; nil = gone).
struct ChatRef: Equatable, Identifiable {
    let location: ChatLocation
    let chat: ArchivedChat
    let folder: String?
    let projectName: String

    var file: String { chat.file }
    var id: String { Self.id(location, file: chat.file) }

    static func id(_ location: ChatLocation, file: String) -> String {
        switch location {
        case let .live(dirName): "live/\(dirName)/\(file)"
        case let .archived(folder): "archived/\(folder)/\(file)"
        }
    }
}

/// Continuing chats in the terminal drawer. Every check lives in NexusCore
/// (`sessionID` is a strict UUID, the folder must exist inside $HOME); this
/// only turns a refusal into a toast.
@MainActor
enum ChatLaunch {
    /// Why "Continue in Claude Code" is unavailable (nil = it's available).
    static func resumeProblem(_ ref: ChatRef) -> String? {
        ClaudeChats.resumeProblem(ref.location, file: ref.file) ?? ClaudeChats.launchProblem(folder: ref.folder)
    }

    static func resume(_ ref: ChatRef, model: AppModel) {
        if let problem = resumeProblem(ref) { return model.toast(problem, isError: true) }
        guard let folder = ref.folder else { return }
        do {
            open(model, dir: folder, title: "Claude · " + ArchiverTitle.short(ref.chat.title),
                 command: try ClaudeChats.resumeCommand(file: ref.file))
        } catch { model.report(error) }
    }

    static func newChat(folder: String?, projectName: String, model: AppModel) {
        if let problem = ClaudeChats.launchProblem(folder: folder) { return model.toast(problem, isError: true) }
        guard let folder else { return }
        open(model, dir: folder, title: "Claude · " + projectName, command: ClaudeChats.newChatCommand)
    }

    static func copyResumeCommand(_ ref: ChatRef, model: AppModel) {
        do {
            let command: String
            if let folder = ref.folder {
                command = try ClaudeChats.copyableResumeCommand(file: ref.file, folder: folder)
            } else {
                command = try ClaudeChats.resumeCommand(file: ref.file)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            model.toast(ClaudeChats.resumeProblem(ref.location, file: ref.file) == nil
                ? "Resume command copied" : "Resume command copied — restore the chat before running it")
        } catch { model.report(error) }
    }

    private static func open(_ model: AppModel, dir: String, title: String, command: String) {
        let terminals = model.terminals
        terminals.runInProject(dir: dir, title: title, command: command)
        // runInProject refuses silently (tab limit); say so instead.
        if terminals.sessions.first(where: { $0.id == terminals.activeID })?.title != title {
            model.toast("Couldn't open a terminal tab — close one and try again.", isError: true)
        }
    }
}

enum ArchiverTitle {
    /// Tab-sized title: first 32 characters.
    static func short(_ title: String) -> String {
        title.count > 32 ? String(title.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}
