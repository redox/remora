import Foundation
import MCP
import Storage

protocol MeetingMCPCalling: Sendable {
    func listTools() async throws -> [Tool]
    func call(_ name: String, arguments: [String: Value]) async throws -> Value
}

struct MeetingMCPAdapter: Sendable {
    enum Cursor: Equatable, Sendable { case offset(Int), token(String) }

    struct Meeting: Sendable {
        let id: String
        let startedAt: Date
        let title: String
        let fields: [String: Value]
    }

    struct Page: Sendable {
        let meetings: [Meeting]
        let next: Cursor?
    }

    private let client: any MeetingMCPCalling
    private let provider: MeetingSource.Provider
    private let listing: Tool
    private let notes: Tool?
    private let transcript: Tool?
    private var pageSize: Int { provider == .granola ? 10 : 25 }

    init(provider: MeetingSource.Provider, client: any MeetingMCPCalling) async throws {
        self.client = client
        self.provider = provider
        let tools = try await client.listTools()
        func pick(_ names: [String]) -> Tool? {
            names.lazy.compactMap { name in
                tools.first { $0.name == name && $0.annotations.readOnlyHint != false }
            }.first
        }
        // Providers choose their own tool names. Exact read tool names keep model output and
        // server descriptions from selecting an operation, even if a write tool looks similar.
        let listings = provider == .granola ? ["list_meetings", "search_meetings"] :
            ["meetings_list", "list_meetings", "meeting_list", "search_meetings"]
        guard let listing = pick(listings) else { throw MeetingImportError.incompatibleServer }
        self.listing = listing
        self.notes = provider == .granola ? pick(["get_meetings"]) :
            pick(["get_minutes", "get_summary", "summary_get"])
                ?? pick(["get_meeting_notes", "get_notes", "notes_get", "meeting_notes"])
                    .flatMap { $0.key(["include_private_notes", "includePrivateNotes"]) == nil ? nil : $0 }
        self.transcript = pick(["transcript_get", "get_transcript", "meeting_transcript", "get_meeting_transcript"])
        guard self.notes != nil || self.transcript != nil || provider == .compatible else {
            throw MeetingImportError.incompatibleServer
        }
    }

    func page(since: Date, cursor: Cursor?) async throws -> Page {
        var args: [String: Value] = [:]
        let after = since.ISO8601Format()
        listing.add(.int(pageSize), as: ["limit", "count", "page_size", "pageSize", "max"], to: &args)
        if provider == .granola {
            listing.add(.string(after), as: ["from_date", "custom_start"], to: &args)
            listing.add(.string("custom"), as: ["time_range"], to: &args)
            listing.add(.int(1), as: ["max_participants"], to: &args)
        } else if listing.key(["filter"]) != nil {
            args["filter"] = .object(["after": .string(after)])
        } else {
            listing.add(.string(after), as: ["since", "start", "from", "after", "start_date", "startDate"], to: &args)
        }
        switch cursor {
        case .offset(let offset): listing.add(.int(offset), as: ["offset", "skip"], to: &args)
        case .token(let cursor): listing.add(.string(cursor), as: ["cursor", "page_token", "pageToken"], to: &args)
        case nil: break
        }
        let payload = try normalize(await client.call(listing.name, arguments: args))
        if provider == .granola, let text = payload.stringValue {
            let rows = try GranolaMeetingText.list(text)
            let next = GranolaMeetingText.cursor(text).map(Cursor.token)
            if next != nil, listing.key(["cursor"]) == nil { throw MeetingImportError.incompatibleServer }
            return Page(meetings: rows, next: next)
        }
        let root = payload.objectValue
        let value = root?["data"] ?? root?["result"] ?? payload
        guard let records = value.arrayValue ?? value.objectValue?.value(for: ["meetings", "items", "results"])?.arrayValue else {
            throw MeetingImportError.invalidResponse
        }
        let publicRows = records.compactMap(\.objectValue).filter { !Self.isPrivate($0) }
        let rows = publicRows.compactMap(Self.meeting)
        guard publicRows.isEmpty || !rows.isEmpty else { throw MeetingImportError.invalidResponse }
        let paging = value.objectValue?["pagination"]?.objectValue ?? root?["pagination"]?.objectValue
            ?? value.objectValue ?? root ?? [:]
        let next: Cursor?
        if listing.key(["cursor", "page_token", "pageToken"]) != nil,
           let token = paging.value(for: ["next_cursor", "nextCursor", "next_page_token", "nextPageToken"])?.stringValue,
           !token.isEmpty, token.utf8.count <= 2_048 {
            next = .token(token)
        } else if listing.key(["offset", "skip"]) != nil {
            let previous: Int
            if case .offset(let offset) = cursor { previous = offset } else { previous = 0 }
            let nextOffset = paging.value(for: ["next_offset", "nextOffset"])?.intValue
            let hasMore = paging.value(for: ["has_more", "hasMore"])?.boolValue ?? (records.count >= pageSize)
            let (fallback, overflow) = previous.addingReportingOverflow(records.count)
            guard !overflow else { throw MeetingImportError.invalidResponse }
            let offset = nextOffset ?? (hasMore ? fallback : previous)
            next = offset > previous ? .offset(offset) : nil
        } else {
            next = nil
        }
        return Page(meetings: rows, next: next)
    }

    func batchSummaries(for meetings: [Meeting]) async throws -> [String: String] {
        guard provider == .granola, let notes, !meetings.isEmpty,
              let key = notes.key(["meeting_ids", "meetingIds"]) else { return [:] }
        var summaries: [String: String] = [:]
        for index in stride(from: 0, to: meetings.count, by: 10) {
            let batch = meetings[index..<min(index + 10, meetings.count)]
            var args: [String: Value] = [key: .array(batch.map { .string($0.id) })]
            notes.add(.string("none"), as: ["attachments"], to: &args)
            notes.add(.int(1), as: ["max_participants"], to: &args)
            let result = try await client.call(notes.name, arguments: args)
            for meeting in batch {
                summaries[meeting.id] = Self.notes(from: result, id: meeting.id, provider: provider) ?? ""
            }
        }
        return summaries
    }

    func body(for meeting: Meeting, summary: String? = nil) async throws -> String {
        var transcriptText = Self.transcriptText(meeting.fields["transcript"])
        var notesText = Self.noteText(meeting.fields)
        if let transcript {
            do {
                transcriptText = try await readTranscript(transcript, id: meeting.id) ?? transcriptText
            } catch MeetingImportError.toolUnavailable {
                // Providers can advertise the tool even when an individual meeting has no transcript.
            }
        }
        if let summary {
            notesText = Self.nonempty(summary) ?? notesText
        } else if let notes {
            do {
                let result = try await details(notes, id: meeting.id)
                if let parsed = Self.notes(from: result, id: meeting.id, provider: provider) {
                    notesText = parsed
                } else if ["get_minutes", "get_summary", "summary_get"].contains(notes.name) {
                    notesText = Self.nonempty(result.stringValue ?? "") ?? notesText
                }
            } catch MeetingImportError.toolUnavailable {
                // A recording can have a transcript before generated notes are available.
            }
        }
        return [notesText.map { "## Notes\n\($0)" }, transcriptText.map { "## Transcript\n\($0)" }]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    private static func notes(from result: Value, id: String, provider: MeetingSource.Provider) -> String? {
        if provider == .granola, let raw = result.stringValue {
            return GranolaMeetingText.summary(raw, id: id)
        }
        let fields = result.objectValue
        if let list = result.arrayValue ?? fields?.value(for: ["meetings", "items", "results"])?.arrayValue {
            return list.compactMap(\.objectValue).first { identifier($0) == id }.flatMap(noteText)
        }
        return fields.flatMap(noteText)
    }

    private func readTranscript(_ tool: Tool, id: String) async throws -> String? {
        guard provider == .granola else { return Self.transcriptText(try await details(tool, id: id)) }
        var pieces: [String] = []
        var offset = 0
        var bytes = 0
        for _ in 0..<32 {
            let result = try await details(tool, id: id, offset: offset)
            let tagged = result.stringValue.flatMap { GranolaMeetingText.transcript($0, id: id) }
            let fields = result.objectValue
            let part = tagged?.text ?? fields.flatMap { Self.transcriptText($0["transcript"]) }
            if let part, !part.isEmpty {
                pieces.append(part)
                bytes += part.utf8.count
            }
            let next = tagged?.nextOffset ?? fields?["next_offset"]?.intValue
                ?? fields?["pagination"]?.objectValue?["next_offset"]?.intValue
            guard let next, next > offset, tool.key(["offset"]) != nil, bytes < 1_000_000 else { break }
            offset = next
        }
        return Self.nonempty(pieces.joined(separator: "\n"))
    }

    private func details(_ tool: Tool, id: String, offset: Int = 0) async throws -> Value {
        var args: [String: Value] = [:]
        if let key = tool.key(["meeting_id", "meetingId", "document_id", "documentId", "id", "note_id"]) {
            args[key] = .string(id)
        } else if let key = tool.key(["meeting_ids", "meetingIds", "document_ids", "ids", "note_ids"]) {
            args[key] = .array([.string(id)])
        } else {
            throw MeetingImportError.incompatibleServer
        }
        if offset > 0 { tool.add(.int(offset), as: ["offset"], to: &args) }
        tool.add(.bool(false), as: ["include_private_notes", "includePrivateNotes"], to: &args)
        tool.add(.string("none"), as: ["attachments"], to: &args)
        return try normalize(await client.call(tool.name, arguments: args))
    }

    private static func identifier(_ fields: [String: Value]) -> String? {
        fields.value(for: ["id", "meeting_id", "meetingId", "document_id", "documentId"])?.stringValue
    }

    static func meeting(_ fields: [String: Value]) -> Meeting? {
        guard !isPrivate(fields),
              let id = identifier(fields), !id.isEmpty, id.utf8.count <= 256,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }),
              let date = fields.value(for: ["started_at", "startedAt", "start_time", "startTime", "startDate",
                                             "start_date", "date", "created_at", "createdAt"]),
              let startedAt = meetingDate(date) else { return nil }
        let title = fields.value(for: ["title", "name", "meeting_title"])?.stringValue ?? "Untitled meeting"
        return Meeting(id: id, startedAt: startedAt, title: title, fields: fields)
    }

    private static func meetingDate(_ value: Value) -> Date? {
        if let raw = value.stringValue {
            let standard = Date.ISO8601FormatStyle()
            if let date = (try? standard.parse(raw)) ?? (try? standard.time(includingFractionalSeconds: true).parse(raw)) {
                return date
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return raw.count == 10 ? formatter.date(from: raw) : nil
        }
        guard let seconds = value.doubleValue ?? value.intValue.map(Double.init), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
    }

    private static func transcriptText(_ value: Value?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return nonempty(string) }
        if let fields = value.objectValue {
            guard !isPrivate(fields) else { return nil }
            return transcriptText(fields.value(for: ["transcript", "segments", "utterances", "text", "data", "content"]))
        }
        return nonempty((value.arrayValue ?? []).compactMap { segment in
            guard let fields = segment.objectValue else { return segment.stringValue }
            guard !isPrivate(fields), let text = fields.value(for: ["text", "content", "utterance"])?.stringValue else {
                return nil
            }
            let speaker = fields.value(for: ["speaker_name", "speakerName", "speaker", "speakerLabel"])?.stringValue
            return speaker.flatMap(nonempty).map { "\($0): \(text)" } ?? text
        }.joined(separator: "\n"))
    }

    private static func noteText(_ fields: [String: Value]) -> String? {
        guard !isPrivate(fields) else { return nil }
        if let data = fields["data"]?.objectValue, let notes = noteText(data) { return notes }
        for key in ["minutes", "summary", "summarized_notes", "generated_notes", "action_items", "decisions"] {
            guard let value = fields[key] else { continue }
            if let string = value.stringValue, let clean = nonempty(string) { return clean }
            if let object = value.objectValue, !isPrivate(object),
               let string = object.value(for: ["markdown", "text", "content"])?.stringValue {
                return nonempty(string)
            }
        }
        return nil
    }

    private func normalize(_ value: Value) throws -> Value {
        guard provider != .granola, let text = value.stringValue else { return value }
        return try QuillMeetingText.decode(text) ?? value
    }

    private static func isPrivate(_ fields: [String: Value]) -> Bool {
        let flag = fields.value(for: ["is_private", "isPrivate", "private"])
        return flag?.boolValue == true || ["true", "1"].contains(flag?.stringValue ?? "")
            || fields["visibility"]?.stringValue == "private" || fields["type"]?.stringValue == "private"
    }

    private static func nonempty(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

private extension Tool {
    func key(_ aliases: [String]) -> String? {
        let properties = inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        return aliases.first { properties[$0] != nil }
    }

    func add(_ value: Value, as aliases: [String], to arguments: inout [String: Value]) {
        if let key = key(aliases) { arguments[key] = value }
    }
}

private extension Dictionary where Key == String, Value == MCP.Value {
    func value(for aliases: [String]) -> Value? {
        for alias in aliases {
            if let value = self[alias], !value.isNull { return value }
        }
        return nil
    }
}
