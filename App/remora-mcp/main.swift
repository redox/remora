// MCP stdio entry point. stdout carries JSON-RPC only; never print anything else here.
import Foundation
import MCPServer
import Storage

let databaseURL = ProcessInfo.processInfo.environment["REMORA_DB_PATH"].map { URL(filePath: $0) }
    ?? AppDatabase.defaultURL
try await RemoraMCPServer.run(databaseURL: databaseURL)
