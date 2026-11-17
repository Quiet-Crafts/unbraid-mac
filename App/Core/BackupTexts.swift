import Foundation

/// The words and rules of the backup and restore sheets, so the views only draw them; and saving a backup file.
nonisolated enum BackupTexts {
    static let saved = "Backup saved."
    static let restored = "Settings restored."
    /// Notices that report something done rather than something wrong.
    static func isGood(_ notice: String) -> Bool { notice == saved || notice == restored || notice == restoredSignIn }
    static let restoredSignIn = "Settings restored. Sign in to your providers to use their routes."

    static let footer = "A backup is one file, locked with a passphrase you choose. Provider sign-ins, Tailscale and statistics are never in it."
    static let standIn = "Not available while your settings are held for the keychain or were saved by a newer unbraid"
    static let never = "Never in the file: provider sign-ins, Tailscale, statistics. You sign in again after a restore."
    static let unrecoverable = "unbraid can't recover a forgotten passphrase"
    static let keysTitle = "Include server keys and passwords"
    static let keysOff = "Off: your own servers are saved without their keys and wait for their config after a restore."
    static let keysOn = "On: anyone with the file and its passphrase can use your own servers."
    static let keepUnavailable = "No room to keep it: delete a profile first, or restore without keeping it"
    static let keepCaption = "You can switch back to it from Profiles."
    static let needsConfig = "Needs its config again"

    /// The save sheet's line under its title.
    static func saveFacts(_ s: Setup, keys: Bool) -> String {
        "One file, locked with a passphrase you choose. " + Backup.holds(Backup.Summary(Backup.contents(s, keys: keys)))
    }

    /// Why "Save Backup…" can't be clicked yet, and what to say about it.
    struct SaveCheck: Equatable {
        var ready: Bool
        /// Shown under the fields; nil while there is nothing to say yet.
        var problem: String?
    }

    /// Both fields filled and the same. A mismatch is said once the second is as long as the first, so typing it isn't
    /// interrupted. With keys in the file, a passphrase that is easy to guess is refused.
    static func saveCheck(_ passphrase: String, _ again: String, keys: Bool) -> SaveCheck {
        if keys, !passphrase.isEmpty, Backup.strength(passphrase) == .easy {
            return SaveCheck(ready: false, problem: "Choose a passphrase that is harder to guess to include keys")
        }
        guard !passphrase.isEmpty, !again.isEmpty else { return SaveCheck(ready: false) }
        if again != passphrase {
            return SaveCheck(ready: false, problem: again.count >= passphrase.count ? "The passphrases don't match" : nil)
        }
        return SaveCheck(ready: true)
    }

    /// How many of the strength meter's three segments are lit.
    static func segments(_ s: Backup.Strength) -> Int { switch s { case .easy: 1; case .fair: 2; case .hard: 3 } }

    /// "unbraid-backup-2026-11-17.unbraidbackup", by this Mac's calendar.
    static func fileName(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "unbraid-backup-%04d-%02d-%02d.", c.year ?? 0, c.month ?? 0, c.day ?? 0) + BackupFile.fileExtension
    }

    /// Why a file won't open, in a plain sentence.
    static func openFailure(_ f: BackupFile.Failure) -> String {
        switch f {
        case .tooLarge: "This file is too large to be an unbraid backup"
        case .notABackup: "That isn't an unbraid backup"
        case .newer: "This backup was made by a newer unbraid. Update unbraid to open it."
        case .damaged: "This backup is damaged and can't be opened"
        case .wrongPassphrase: "That passphrase doesn't open this backup"
        case .memory: "There isn't enough memory to open this backup. Quit some apps and try again."
        }
    }

    /// Why a backup couldn't be saved. Never the system's own message: it may name paths.
    static func saveFailure(_ error: Error) -> String {
        if let e = error as? BackupFile.Unrestorable { return "Nothing was saved: a backup of this setup couldn't be restored later. \(e.why)" }
        return switch error as? BackupFile.Failure {
        case .tooLarge: "This setup is too large for a backup file"
        case .memory: "There isn't enough memory to lock the backup. Quit some apps and try again."
        default: "The backup couldn't be saved there. Choose another folder and try again."
        }
    }

    /// The restore sheet's facts line: "<file> · saved 17 Nov 2026 with unbraid 1.2.0".
    static func restoreFacts(file: String, _ c: Backup.Content, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = timeZone
        return "\(file) · saved \(c.created.formatted(style)) with unbraid \(c.app)"
    }

    /// The keep switch's title, with the name the plan would give the kept profile.
    static func keepTitle(_ name: String?) -> String { "Keep my current setup as the profile \"\(name ?? Backup.previous)\"" }

    /// What else the restore does, each said only when it is true.
    static func restoreNotes(_ plan: Backup.Plan, accounts: [String: String], tunnelUp: Bool) -> [String] {
        var notes: [String] = []
        let names = plan.needConfig.map { "\"\($0)\"" }
        if !names.isEmpty {
            let list = names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
            notes.append(names.count == 1 ? "\(list) needs its config again before its apps can connect."
                                          : "\(list) need their config again before their apps can connect.")
        }
        if plan.setup.routes.contains(where: { !$0.imported && accounts[$0.loc.provider] == nil }) {
            notes.append("Routes on a provider you aren't signed in to stay blocked until you sign in.")
        }
        notes += plan.weakens
        if tunnelUp {
            notes.append(plan.protectionChanges ? "The kill switch or Connect on Demand setting changes, so the VPN restarts." : "The VPN reconnects for a moment.")
        }
        return notes
    }

    /// The notice once restored: on the sign-in page (nothing to connect through yet) it says what comes next.
    static func restoredNotice(signedIn: Bool) -> String { signedIn ? restored : restoredSignIn }

    /// A config of another kind than the server waits for.
    static func wrongKind(_ got: String, needs: String) -> String { "That is \(a(got)) config; this server needs \(a(needs)) one" }
    private static func a(_ kind: String) -> String { ("AEIOU".contains(kind.prefix(1)) ? "an " : "a ") + kind }

    /// Why a backup file the user opened isn't taken.
    static let refusedForTerms = "Accept the Terms of Use first, then open the backup again."
    static let refusedForStandIn = "A backup can't be restored while your settings are held for the keychain or were saved by a newer unbraid."
    static let refusedBusy = "Close the open sheet first, then try again."
    static let unreadable = "That file couldn't be read"
}

nonisolated extension Backup {
    /// Why a chosen file can't go on to the restore sheet, as the passphrase sheet says it.
    struct Refusal: Error, Equatable {
        var message: String
        /// The field is cleared for another try.
        var wrongPassphrase = false
    }

    /// Backup `file` opened with `passphrase` and read whole (`read`). The plaintext is cleared before this returns.
    /// Slow (the key derivation): never on the main actor.
    static func unlock(_ file: Data, passphrase: String) -> Result<Content, Refusal> {
        do {
            var plain = try BackupFile.open(file, passphrase: passphrase)
            defer { plain.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } } }
            return .success(try read(plain))
        } catch let f as BackupFile.Failure {
            return .failure(Refusal(message: BackupTexts.openFailure(f), wrongPassphrase: f == .wrongPassphrase))
        } catch let f as Failure {
            return .failure(Refusal(message: f.message))
        } catch {
            return .failure(Refusal(message: BackupTexts.openFailure(.damaged)))
        }
    }
}

nonisolated extension BackupFile {
    /// `setup` as a backup sealed under `passphrase`, written to `url`. The plaintext never touches the disk and is
    /// cleared once sealed. Slow (the key derivation): never on the main actor.
    static func save(_ setup: Setup, app: String, keys: Bool, passphrase: String, to url: URL, now: Date = .now) throws {
        var plain = Backup.export(setup, app: app, created: now, keys: keys)
        defer { plain.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } } }
        // Read back before anything is written: a backup that couldn't be restored is said now, while the setup is
        // still here to mend, not on the day it is needed.
        do { _ = try Backup.read(plain) } catch { throw Unrestorable(why: (error as? Backup.Failure)?.message ?? "") }
        try write(try seal(plain, passphrase: passphrase), to: url)
    }

    /// A setup whose backup could not be restored (see `save`), with what the restore would say.
    struct Unrestorable: Error, Equatable { var why: String }

    /// Writes `data` to `url` in one step: a file only the user can read, made beside it and moved into place, so a
    /// failure never leaves half a backup or replaces a good one with nothing.
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Reads a file the user chose as a backup: refused before reading it all when larger than a backup can be, or when
    /// it doesn't start like one.
    static func readChosen(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxSize { throw Failure.tooLarge }
        let data = try Data(contentsOf: url)
        if data.count > maxSize { throw Failure.tooLarge }
        if !looksLikeBackup(data) { throw Failure.notABackup }
        return data
    }

    /// Whether the file at `url` starts like a backup; reads its first bytes only.
    static func looksLikeBackup(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return looksLikeBackup((try? h.read(upToCount: 15)) ?? Data())
    }
}
