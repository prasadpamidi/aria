import Aria
import Foundation

// MARK: - TaskFixtures

/// Turns that actually failed, with the answer that was wanted.
///
/// Every case is drawn from a field trace on a shipping app, which
/// matters more than the count: an eval written from imagination
/// measures imagination. These are the turns that produced a wrong
/// answer, an invented value, or a crash.
///
/// The tool surface deliberately includes distractors. A task
/// evaluated against only the tool it needs measures nothing about
/// selection, and selection is where several of these went wrong.
public enum TaskFixtures {
    // MARK: Public

    /// Plausible tools from adjacent app surfaces, none of which
    /// answers any case here.
    ///
    /// Twelve tools is not the condition selection exists for — they
    /// fit the window with room to spare, so "send everything" works
    /// and a selector can only lose. The field looks nothing like
    /// that: a connected MCP server brings sixty tools at once, and
    /// the whole surface no longer fits in a 4,096-token window.
    /// Measuring the harness at twelve measures it where it has no
    /// job to do.
    public static let distractors: [(String, String)] = [
        ("calendar_list_events", "List calendar events in a date range."),
        ("calendar_create_event", "Create a calendar event."),
        ("calendar_delete_event", "Delete a calendar event by id."),
        ("mail_search", "Search the mailbox for messages."),
        ("mail_send", "Send an email message."),
        ("mail_draft", "Save an email draft."),
        ("contacts_lookup", "Look up a contact by name or email."),
        ("contacts_create", "Create a new contact record."),
        ("notes_create", "Create a note."),
        ("notes_search", "Search notes by text."),
        ("reminders_create", "Create a reminder with a due date."),
        ("reminders_complete", "Mark a reminder complete."),
        ("files_search", "Search files by name or content."),
        ("files_read", "Read the contents of a file."),
        ("files_write", "Write contents to a file."),
        ("photos_search", "Search the photo library."),
        ("photos_album_create", "Create a photo album."),
        ("music_play", "Play a song, album, or playlist."),
        ("music_search", "Search the music catalogue."),
        ("podcast_subscribe", "Subscribe to a podcast feed."),
        ("weather_forecast", "Get a multi-day weather forecast."),
        ("weather_alerts", "Get active severe weather alerts."),
        ("maps_directions", "Get directions between two places."),
        ("maps_search_places", "Search for places near a location."),
        ("translate_text", "Translate text between languages."),
        ("dictionary_define", "Define a word."),
        ("currency_convert", "Convert an amount between currencies."),
        ("stock_quote", "Get a stock quote by ticker."),
        ("news_headlines", "Get current news headlines."),
        ("timer_start", "Start a countdown timer."),
        ("alarm_create", "Create an alarm for a given time."),
        ("clipboard_read", "Read the system clipboard."),
        ("clipboard_write", "Write text to the system clipboard."),
        ("browser_open_url", "Open a URL in the browser."),
        ("browser_bookmark", "Bookmark the current page."),
        ("device_battery", "Report the device battery level."),
        ("device_storage", "Report available device storage."),
        ("screen_brightness", "Set the screen brightness."),
        ("volume_set", "Set the system output volume."),
        ("shortcut_run", "Run a named shortcut."),
    ]

    /// A realistic surface: a health server, a second server, built-ins.
    public static func tools() -> [AnyTool] {
        [
            self.tool(
                "niora__get_fasting_status",
                "Whether the user is fasting now, and progress toward their target.",
                #"{"is_fasting": true, "target_hours": 16, "time_remaining": "00:00:00", "progress": 1.0}"#
            ),
            self.tool(
                "niora__get_hydration_today",
                "How much water the user has drunk today against their target.",
                #"{"date": "2026-08-08", "total_ml": 0, "goal_ml": 3500}"#
            ),
            self.tool(
                "niora__log_water",
                "Log a water intake entry in millilitres.",
                #"{"logged": true}"#
            ),
            self.tool(
                "niora__get_profile",
                "The user's profile: display name, goals, dietary preferences.",
                #"{"display_name": "Prasad", "fitness_level": "INTERMEDIATE"}"#
            ),
            self.tool(
                "current_time",
                "Get the current date and time in the user's timezone.",
                #"{"iso8601": "2026-08-08T09:51:56-07:00", "timezone": "America/Los_Angeles"}"#
            ),
            self.tool(
                "http_request",
                "Perform an HTTP request to a URL and return the response body.",
                #"{"status": 401, "body": "Invalid API key."}"#
            ),
            self.tool("base64_codec", "Encode or decode base64 text.", #"{"result": ""}"#),
            self.tool("unit_converter", "Convert between units of measure.", #"{"result": 0}"#),
            self.tool("calculator", "Evaluate an arithmetic expression.", #"{"result": 0}"#),
            self.tool("json_path", "Extract values from JSON with a path expression.", #"{"result": ""}"#),
            self.tool("regex", "Match or replace text with a regular expression.", #"{"result": ""}"#),
            self.tool("date_math", "Add or subtract intervals from a date.", #"{"result": ""}"#),
        ]
    }

    /// - Parameter surfaceSize: Pad the surface with `distractors` up
    ///   to this many tools. `nil` keeps the twelve-tool surface.
    public static func cases(surfaceSize: Int? = nil) -> [TaskCase] {
        var surface = Self.tools()
        if let surfaceSize {
            for (name, description) in Self.distractors
                where surface.count < surfaceSize {
                surface.append(Self.tool(name, description, #"{"result": ""}"#))
            }
        }
        return [
            // FIELD: the tool was called correctly and the answer
            // contradicted it — `time_remaining: "00:00:00"` became
            // "you have 16 hours left". Ranking metrics score this
            // turn as a success.
            TaskCase(
                query: "How am I doing with fasting today?",
                tools: surface,
                expectedTool: "niora__get_fasting_status",
                // No `mustContain`: "your progress is 100%" and "you've
                // completed your 16-hour target" are both correct
                // readings of the same payload, and demanding one
                // phrasing measures the assertion rather than the
                // model. The failure being caught is the *contradiction*
                // — a completed fast reported as hours remaining.
                mustNotContain: ["16 hours left", "16 hours remaining", "hours left"],
                note: "FIELD: answer contradicted the tool result"
            ),
            // FIELD: answered "You have not drank any water today"
            // correctly from `total_ml: 0`.
            TaskCase(
                query: "How much water did I drink today?",
                tools: surface,
                expectedTool: "niora__get_hydration_today",
                mustNotContain: ["2000", "1500"],
                note: "FIELD: read vs write — log_water outranked the reader"
            ),
            // FIELD: a statement of fact sent six unrelated tools, and
            // the model invented a weather API call with a placeholder
            // key, then apologised for the weather for two more turns.
            TaskCase(
                query: "I live in Dublin, CA",
                tools: surface,
                expectedTool: nil,
                mustNotContain: ["YOUR_API_KEY", "api key", "weather"],
                note: "FIELD: nothing to call — inventing a call is the failure"
            ),
            TaskCase(
                query: "What time is it right now?",
                tools: surface,
                expectedTool: "current_time",
                // "9:51" not "09:51" — the model renders the hour
                // without a leading zero, which is not an error. An
                // over-precise needle turns a correct answer into a
                // failure and flatters nothing.
                mustContain: ["9:51"],
                mustNotContain: ["2024", "2023"],
                note: "FIELD: invented timestamps from 2024 when the tool was ignored"
            ),
            TaskCase(
                query: "What's my name?",
                tools: surface,
                expectedTool: "niora__get_profile",
                mustContain: ["Prasad"],
                note: "Straightforward lookup — a floor case"
            ),
            // FIELD: the hydration lookup failed and the model called a
            // calculator with the literal expression 2000, then
            // answered "You drank 2000ml of water today."
            TaskCase(
                query: "Log 500 ml of water",
                tools: surface,
                expectedTool: "niora__log_water",
                mustNotContain: ["couldn't", "unable"],
                note: "Write path — must call the writer, not the reader"
            ),
        ]
    }

    // MARK: Private

    /// A tool that returns a fixed payload, so grounding is checkable:
    /// the answer either carries what the tool said or it does not.
    private static func tool(
        _ name: String,
        _ description: String,
        _ payload: String
    ) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: [:], required: [])
            ),
            invoke: { _, _ in .object(["text": .string(payload)]) }
        )
    }
}
