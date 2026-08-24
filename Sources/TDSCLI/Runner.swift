import Foundation
import NIOCore
import NIOPosix
import TDSKit

// A tiny harness used to exercise TDSKit against a real SQL Server.
let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

func env(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? fallback
}

let host = env("SQL_HOST", "127.0.0.1")
let port = Int(env("SQL_PORT", "11433")) ?? 11433
let user = env("SQL_USER", "sa")
let password = env("SQL_PASSWORD", "Str0ngP@ssw0rd!")
let database = env("SQL_DB", "master")

let sqlArgument = CommandLine.arguments.dropFirst().joined(separator: " ")

func printResult(_ result: TDSQueryResult) {
    for (index, set) in result.resultSets.enumerated() {
        print("── result set \(index + 1): \(set.columns.count) columns, \(set.rows.count) rows")
        print("   " + set.columns.map { "\($0.name) [\($0.sqlTypeName)]" }.joined(separator: " | "))
        for row in set.rows.prefix(25) {
            print("   " + row.map { $0.displayString() }.joined(separator: " | "))
        }
        if set.rows.count > 25 { print("   … \(set.rows.count - 25) more rows") }
    }
    for message in result.messages { print("ℹ️  \(message.text)") }
    for error in result.errors { print("❌ \(error.formatted)") }
    if !result.rowsAffected.isEmpty {
        print("rows affected: \(result.rowsAffected.map(String.init).joined(separator: ", "))")
    }
}

let smokeSQL = """
SELECT @@VERSION AS version;
SELECT
    CAST(1 AS bit) AS b, CAST(42 AS tinyint) AS ti, CAST(-1234 AS smallint) AS si,
    CAST(2147483647 AS int) AS i, CAST(-9223372036854775808 AS bigint) AS bi,
    CAST(3.14159 AS real) AS r, CAST(2.718281828459045 AS float) AS f,
    CAST(1234.5678 AS money) AS m, CAST(-12.3456 AS smallmoney) AS sm,
    CAST(12345678901234567890123456.789 AS decimal(38,10)) AS dec38,
    CAST(NULL AS int) AS nullint,
    N'سلام دنیا — Unicode ✓' AS unicode_text,
    CAST('plain ascii' AS varchar(50)) AS ascii_text,
    CAST(0x0123456789ABCDEF AS varbinary(50)) AS bin,
    NEWID() AS guid,
    CAST('2024-02-29' AS date) AS d,
    CAST('13:45:56.1234567' AS time(7)) AS t,
    CAST('1999-12-31 23:59:59.997' AS datetime) AS dt,
    CAST('2024-06-15 08:30:00' AS smalldatetime) AS sdt,
    CAST('2024-06-15 08:30:15.1234567' AS datetime2(7)) AS dt2,
    CAST('2024-06-15 08:30:15.1234567 +03:30' AS datetimeoffset(7)) AS dto,
    REPLICATE(CAST('x' AS varchar(max)), 10000) AS big_varchar,
    CAST('<root><a id="1"/></root>' AS xml) AS x;
SELECT TOP 5 name, database_id, create_date FROM sys.databases ORDER BY database_id;
PRINT 'hello from PRINT';
"""

@main
struct Runner {
    static func main() async {
        let config = TDSConfiguration(
            host: host,
            port: port,
            database: database,
            authentication: .sqlLogin(username: user, password: password),
            encryption: .required,
            trustServerCertificate: true,
            applicationName: "TDSKit smoke test"
        )

        do {
            let started = Date()
            let connection = try await TDSConnection.connect(configuration: config, on: group)
            print("✅ connected in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            print("   server: \(connection.loginAcknowledgement?.programName ?? "?") "
                  + "\(connection.loginAcknowledgement?.versionString ?? "")")
            print("   encryption negotiated: \(connection.negotiatedEncryption)")
            print("   database: \(connection.database)")

            let sql = sqlArgument.isEmpty ? smokeSQL : sqlArgument
            let result = try await connection.query(sql)
            printResult(result)

            try await connection.close()
            print("✅ closed")
            try? await group.shutdownGracefully()
            exit(0)
        } catch {
            print("💥 \(error)")
            try? await group.shutdownGracefully()
            exit(1)
        }
    }
}
