import Foundation
import SQLServerKit

/// Offline suites for the two command-line tools, which run as subprocesses from the build
/// folder next to this executable: argument parsing (switches, unknown options, --help),
/// the exit codes that need no server, scripts-folder comparisons and project defaults.
func runCLITests(_ t: TestRunner) {
    let directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath().deletingLastPathComponent()
    let compare = directory.appendingPathComponent("ssms-compare")
    let backup = directory.appendingPathComponent("ssms-backup")
    guard FileManager.default.isExecutableFile(atPath: compare.path),
          FileManager.default.isExecutableFile(atPath: backup.path) else {
        print("\n▸ command-line tools: skipped — build ssms-compare and ssms-backup first (swift build)")
        return
    }

    // MARK: - Running the tools

    struct Outcome {
        var status: Int32
        var output: String
        var errors: String
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ssms-cli-tests-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var runs = 0

    /// Runs a tool with stdout and stderr captured in files, so neither can block the other.
    func run(_ tool: URL, _ arguments: [String]) -> Outcome {
        runs += 1
        let outputURL = root.appendingPathComponent("run-\(runs).out")
        let errorsURL = root.appendingPathComponent("run-\(runs).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL),
              let errors = try? FileHandle(forWritingTo: errorsURL) else {
            return Outcome(status: -1, output: "", errors: "could not create capture files")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = root
        // Nothing here may reach a server, and no password should leak in from the shell.
        var environment = ProcessInfo.processInfo.environment
        for key in ["SQL_PASSWORD", "SQL_USER", "SSMS_SOURCE_PASSWORD", "SSMS_TARGET_PASSWORD", "SSMS_PASSWORD"] {
            environment[key] = nil
        }
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Outcome(status: -1, output: "", errors: "could not start \(tool.lastPathComponent): \(error)")
        }
        process.waitUntilExit()
        try? output.close()
        try? errors.close()
        return Outcome(status: process.terminationStatus,
                       output: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
                       errors: (try? String(contentsOf: errorsURL, encoding: .utf8)) ?? "")
    }

    func compareRun(_ arguments: String...) -> Outcome { run(compare, arguments) }
    func backupRun(_ arguments: String...) -> Outcome { run(backup, arguments) }

    /// One suite's worth of checks on an outcome: the exit code and a phrase on each stream.
    func check(_ outcome: Outcome, status: Int32, output: String? = nil, errors: String? = nil, _ label: String) {
        t.equal(outcome.status, status, "\(label): exit code")
        if let output {
            t.expect(outcome.output.contains(output), "\(label): stdout mentions \(output)", outcome.output)
        }
        if let errors {
            t.expect(outcome.errors.contains(errors), "\(label): stderr mentions \(errors)", outcome.errors)
        }
    }

    // MARK: - Fixtures

    /// A scripts folder with one file per table under Tables/.
    func folder(_ name: String, tables: [String: String]) -> String {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("Tables"), withIntermediateDirectories: true)
        for (table, script) in tables {
            try? script.write(to: url.appendingPathComponent("Tables/dbo.\(table).sql"), atomically: true, encoding: .utf8)
        }
        return url.path
    }

    let wide = folder("wide", tables: [
        "Customer": "CREATE TABLE [dbo].[Customer] ([Id] int NOT NULL, [Name] nvarchar(100) NOT NULL, "
            + "CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([Id]))",
        "Extra": "CREATE TABLE [dbo].[Extra] ([Id] int NOT NULL CONSTRAINT [PK_Extra] PRIMARY KEY CLUSTERED)"
    ])
    let narrow = folder("narrow", tables: [
        "Customer": "CREATE TABLE [dbo].[Customer] ([Id] int NOT NULL, [Name] nvarchar(50) NOT NULL, "
            + "CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([Id]))",
        "Legacy": "CREATE TABLE [dbo].[Legacy] ([Id] int NOT NULL CONSTRAINT [PK_Legacy] PRIMARY KEY CLUSTERED)"
    ])
    let empty = folder("empty", tables: [:])
    let missing = root.appendingPathComponent("no-such-folder").path

    // MARK: - Help and unknown options

    t.suite("cli help") {
        check(compareRun(), status: 64, output: "USAGE", "ssms-compare with nothing")
        check(compareRun("--help"), status: 0, output: "USAGE", "ssms-compare --help")
        check(compareRun("-h"), status: 0, output: "USAGE", "ssms-compare -h")
        check(compareRun("help"), status: 0, output: "USAGE", "ssms-compare help")
        check(compareRun("schema", "--help"), status: 0, output: "allow-empty-source", "ssms-compare schema --help")
        check(compareRun("nonsense"), status: 64, errors: "Unknown command", "ssms-compare unknown command")
        check(backupRun(), status: 64, output: "USAGE", "ssms-backup with nothing")
        check(backupRun("--help"), status: 0, output: "USAGE", "ssms-backup --help")
        check(backupRun("-h"), status: 0, output: "USAGE", "ssms-backup -h")
        check(backupRun("help"), status: 0, output: "USAGE", "ssms-backup help")
        check(backupRun("restore", "-h"), status: 0, output: "undo-file", "ssms-backup restore -h")
        check(backupRun("nonsense"), status: 64, errors: "Unknown command", "ssms-backup unknown command")
    }

    t.suite("cli unknown options") {
        check(compareRun("schema", "--sourc-scripts", wide, "--target-scripts", narrow), status: 64,
              errors: "Unknown option --sourc-scripts", "misspelled schema option")
        check(compareRun("data", "--include-tabel", "dbo.x"), status: 64,
              errors: "Unknown option --include-tabel", "misspelled data option")
        check(compareRun("schema", "--include-table", "dbo.x", "--source-scripts", wide, "--target-scripts", narrow),
              status: 64, errors: "Unknown option --include-table", "data option on the schema command")
        check(compareRun("schema", "--quiet", "stray", "--source-scripts", wide, "--target-scripts", narrow),
              status: 64, errors: "Unexpected argument 'stray'", "a switch does not swallow the next word")
        check(compareRun("data", "--verbose", "stray"), status: 64, errors: "Unexpected argument 'stray'",
              "stray word on the data command")
        check(backupRun("backup", "--bogus", "--server", "nowhere"), status: 64, errors: "Unknown option --bogus",
              "misspelled backup option")
        check(backupRun("backup", "--replace", "x.bak", "--server", "nowhere"), status: 64,
              errors: "Unknown option --replace", "restore option on the backup command")
        check(backupRun("verify", "--norecovery", "/x.bak"), status: 64, errors: "Unknown option --norecovery",
              "restore option on verify")
        check(backupRun("status", "stray", "--server", "nowhere"), status: 64, errors: "Unexpected argument 'stray'",
              "stray word where no files are taken")
        check(backupRun("log-shipping", "--standby", "undo.ldf", "--server", "nowhere"), status: 64,
              errors: "Unexpected argument 'undo.ldf'", "--standby is a switch in log shipping")
    }

    // MARK: - Switches and files

    t.suite("cli switches keep file names") {
        // Without files, verify refuses before it needs a server; with the file kept after the
        // switch it goes on to ask for the server. Before the fix --quiet ate the file name.
        check(backupRun("verify", "--quiet"), status: 64, errors: "Give the backup files", "verify with no files")
        check(backupRun("verify", "--quiet", "/var/opt/mssql/data/x.bak"), status: 64, errors: "--server is required",
              "file after --quiet is a file")
        check(backupRun("verify", "--verbose", "/var/opt/mssql/data/x.bak"), status: 64, errors: "--server is required",
              "file after --verbose is a file")
        check(backupRun("verify", "--quiet", "no", "/var/opt/mssql/data/x.bak"), status: 64,
              errors: "--server is required", "an explicit no is the switch's value")
        check(backupRun("verify", "--quiet=yes"), status: 64, errors: "Give the backup files", "--quiet=yes form")
        check(backupRun("restore", "--replace", "/var/opt/mssql/data/x.bak"), status: 64,
              errors: "--database", "restore still asks for its target after --replace FILE")
        check(backupRun("restore", "--database", "T", "--replace", "/var/opt/mssql/data/x.bak"), status: 64,
              errors: "--server is required", "restore reaches the connection with the file kept")
    }

    t.suite("cli backup option values") {
        check(backupRun("backup", "--type", "bogus", "--server", "nowhere"), status: 64, errors: "--type is full",
              "bad backup type")
        check(backupRun("backup", "--erase-files", "soon", "--server", "nowhere"), status: 64, errors: "Retention",
              "bad retention")
        check(backupRun("backup", "--split", "2", "--mirror", "/m", "--server", "nowhere"), status: 64,
              errors: "cannot be combined", "split and mirror together")
        check(backupRun("backup", "--split", "two", "--server", "nowhere"), status: 64, errors: "expects a number",
              "non-numeric split")
        check(backupRun("backup", "--compression", "9", "--server", "nowhere"), status: 64, errors: "0 to 4",
              "compression out of range")
    }

    // MARK: - Schema comparisons of scripts folders

    t.suite("cli schema compare") {
        let same = compareRun("schema", "--source-scripts", wide, "--target-scripts", wide, "--quiet")
        check(same, status: 63, "a folder against itself is identical")
        t.expect(same.errors.isEmpty, "--quiet silences stderr", same.errors)
        let loud = compareRun("schema", "--source-scripts", wide, "--target-scripts", wide, "--quiet=false")
        check(loud, status: 63, errors: "Reading source scripts", "--quiet=false keeps the progress")
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", wide, "--quiet", "yes"), status: 63,
              "an explicit yes after a switch")
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", wide, "--assert-identical", "--quiet"),
              status: 0, "--assert-identical turns identical into success")

        let different = compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow)
        check(different, status: 79, output: "≠ Table: dbo.Customer", errors: "Different: 1", "differences are found")
        t.expect(different.output.contains("→ Table: dbo.Extra") && different.output.contains("← Table: dbo.Legacy"),
                 "the summary lists both one-sided tables", different.output)
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--assert-identical", "--quiet"),
              status: 79, "--assert-identical keeps 79 for differences")

        check(compareRun("schema", "--source-scripts", wide), status: 64, errors: "A target is required", "no target")
        check(compareRun("schema", "--source-scripts", missing, "--target-scripts", narrow), status: 64,
              errors: "does not exist", "a mistyped source path is refused, not read as empty")
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", missing), status: 64,
              errors: "does not exist", "a mistyped target path is refused")
        check(compareRun("schema", "--source-snapshot", missing + ".ssnap", "--target-scripts", narrow), status: 64,
              errors: "does not exist", "a mistyped snapshot path is refused")
        check(compareRun("schema", "--project", missing + ".scmp"), status: 64, errors: "does not exist",
              "a mistyped project path is refused")
    }

    t.suite("cli schema script output") {
        let toStdout = compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--script", "-")
        check(toStdout, status: 79, output: "CREATE TABLE [dbo].[Extra]", errors: "≠ Table: dbo.Customer",
              "--script - prints the script and moves the summary to stderr")
        t.expect(toStdout.output.contains("DROP TABLE [dbo].[Legacy]"), "the script drops the extra target table")
        t.expect(!toStdout.output.contains("≠") && !toStdout.output.contains("→ Table"),
                 "stdout holds nothing but the script", toStdout.output)
        let quietStdout = compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--script", "-",
                                     "--quiet")
        check(quietStdout, status: 79, output: "CREATE TABLE [dbo].[Extra]", "--script - with --quiet")
        t.expect(quietStdout.errors.isEmpty, "--quiet leaves stderr empty with the script on stdout", quietStdout.errors)
        let bare = compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--quiet", "--script")
        check(bare, status: 79, output: "CREATE TABLE [dbo].[Extra]", "--script with no value goes to stdout")

        let file = root.appendingPathComponent("deploy.sql").path
        let toFile = compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--script", file)
        check(toFile, status: 79, output: "≠ Table: dbo.Customer", errors: "Deployment script written",
              "--script FILE keeps the summary on stdout")
        let written = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        t.expect(written.contains("CREATE TABLE [dbo].[Extra]"), "the script file holds the script")

        let report = root.appendingPathComponent("diff.csv").path
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--report", report, "--quiet"),
              status: 79, "a report is written")
        t.expect(FileManager.default.fileExists(atPath: report), "the report file exists")
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--report", report,
                         "--report-type", "bogus"), status: 64, errors: "--report-type", "bad report type")
    }

    t.suite("cli schema safety nets") {
        check(compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--abort-on-warnings", "bogus"),
              status: 64, errors: "--abort-on-warnings", "a bad severity is an error, not ignored")
        let stopped = compareRun("schema", "--source-scripts", wide, "--target-scripts", narrow, "--script", "-",
                                 "--abort-on-warnings", "high")
        check(stopped, status: 79, errors: "Stopping", "high-severity warnings stop the script")
        t.expect(!stopped.output.contains("DROP TABLE"), "nothing is scripted once stopped", stopped.output)

        let refused = compareRun("schema", "--source-scripts", empty, "--target-scripts", narrow, "--script", "-")
        check(refused, status: 64, errors: "has no objects", "an empty source is refused for scripting")
        t.expect(!refused.output.contains("DROP TABLE"), "nothing is scripted from an empty source", refused.output)
        check(compareRun("schema", "--source-scripts", empty, "--target-scripts", narrow, "--deploy"), status: 64,
              errors: "has no objects", "an empty source is refused for deployment")
        check(compareRun("schema", "--source-scripts", empty, "--target-scripts", narrow, "--quiet"), status: 79,
              "an empty source can still be compared")
        let allowed = compareRun("schema", "--source-scripts", empty, "--target-scripts", narrow, "--script", "-",
                                 "--allow-empty-source")
        check(allowed, status: 79, output: "DROP TABLE [dbo].[Legacy]", "--allow-empty-source scripts the drops")
        check(compareRun("schema", "--source-scripts", empty, "--target-scripts", empty, "--script", "-", "--quiet"),
              status: 63, "two empty folders have nothing to drop")
    }

    t.suite("cli snapshots") {
        let snapshot = root.appendingPathComponent("wide.ssnap").path
        check(compareRun("schema", "--source-scripts", wide, "--make-snapshot", snapshot, "--quiet"), status: 0,
              "--make-snapshot needs no target")
        t.expect(FileManager.default.fileExists(atPath: snapshot), "the snapshot file exists")
        check(compareRun("schema", "--source-snapshot", snapshot, "--target-scripts", wide, "--quiet"), status: 63,
              "the snapshot matches the folder it came from")
        check(compareRun("schema", "/snapshot1:\(snapshot)", "/scripts2:\(narrow)", "--quiet"), status: 79,
              "Redgate-style switches are accepted")
    }

    // MARK: - Projects

    t.suite("cli project defaults") {
        let projectURL = root.appendingPathComponent("nightly.scmp")
        let project = CompareProject(kind: .schema, name: "Nightly",
                                     source: CompareEndpoint(kind: .scriptsFolder, path: wide),
                                     target: CompareEndpoint(kind: .scriptsFolder, path: narrow),
                                     schema: SchemaProjectSettings(deselected: ["T:table|dbo|legacy"]))
        do {
            try project.write(to: projectURL)
        } catch {
            t.expect(false, "project is written", "\(error)")
        }
        let fromProject = compareRun("schema", "--project", projectURL.path, "--script", "-", "--quiet")
        check(fromProject, status: 79, output: "CREATE TABLE [dbo].[Extra]", "the project supplies both sides")
        t.expect(!fromProject.output.contains("DROP TABLE [dbo].[Legacy]"),
                 "an object unticked in the project is not deployed", fromProject.output)
        check(compareRun("schema", "--project", projectURL.path, "--target-scripts", wide, "--quiet"), status: 63,
              "a side on the command line replaces the project's")
        check(compareRun("schema", "--project", projectURL.path, "--source-scripts", missing), status: 64,
              errors: "does not exist", "a command-line side is checked like any other")
        check(compareRun("data", "--project", projectURL.path), status: 64, errors: "not a data compare project",
              "a schema project cannot drive the data command")
        check(compareRun("data"), status: 64, errors: "Data compare needs", "data compare without sides")
    }
}
